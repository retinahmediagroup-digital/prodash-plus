"""The ETL worker: turns landed files into published gold data.

    python -m prodash.worker --once       # process every waiting load, then exit
    python -m prodash.worker --nightly    # re-score all branches, then exit

Runs from a scheduler, never as a daemon: GitHub Actions now, cPanel cron
later, the same command in both. Safe to run from two places at once: loads
are claimed with FOR UPDATE SKIP LOCKED.

Per load (one transaction): cleanse (bronze -> silver), publish
(silver -> gold), status 'published' or 'held'. Then scoring for that
branch in its own transaction. Failures are retried with back-off up to
--max-attempts, then the load is marked 'failed'. Logs carry counts and ids
only, never trader names or phone numbers.
"""

import argparse
import logging
import os
import socket
import sys
from contextlib import contextmanager

from prodash import cleanse, publish, scoring
from prodash.db import transaction
from prodash.pipeline import Load, StepNotReady

log = logging.getLogger("prodash.worker")

RETRY_MINUTES = 10      # back-off: attempt n waits n x RETRY_MINUTES


@contextmanager
def single_instance(lock_path: str):
    """Stop two scheduled runs on the same machine overlapping (Linux/macOS)."""
    try:
        import fcntl
    except ImportError:          # Windows: rely on SKIP LOCKED only
        yield True
        return
    with open(lock_path, "w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True


def _start_run(worker: str, mode: str) -> int:
    with transaction() as conn:
        return conn.execute(
            "insert into ops.etl_runs (worker, mode) values (%s, %s) returning run_id", (worker, mode)
        ).fetchone()[0]


def _finish_run(run_id: int, status: str, counts: dict, message: str | None) -> None:
    with transaction() as conn:
        conn.execute(
            """update ops.etl_runs
                  set status = %s, loads_claimed = %s, loads_published = %s, loads_held = %s,
                      loads_retrying = %s, loads_failed = %s, message = %s, finished_at = now()
                where run_id = %s""",
            (status, counts["claimed"], counts["published"], counts["held"],
             counts["retrying"], counts["failed"], message, run_id),
        )


def _claim(worker: str, max_attempts: int, stale_minutes: int) -> Load | None:
    with transaction() as conn:
        row = conn.execute(
            """select load_id, client_id, branch_id, source_file, rows_loaded,
                      min_receipt_date, max_receipt_date, attempts
               from ops.claim_next_load(%s, %s, %s)""",
            (worker, max_attempts, stale_minutes),
        ).fetchone()
    return Load(*row) if row else None


def _release(load: Load) -> None:
    """Step not written yet: back in the queue, attempt not counted."""
    with transaction() as conn:
        conn.execute(
            """update ops.load_log
                  set status = 'loaded', claimed_at = null, attempts = greatest(attempts - 1, 0)
                where load_id = %s""",
            (load.load_id,),
        )


def _record_failure(load: Load, error: Exception, max_attempts: int) -> str:
    message = f"{type(error).__name__}: {error}"[:2000]
    final = load.attempts >= max_attempts
    with transaction() as conn:
        conn.execute(
            """update ops.load_log
                  set status = %s, claimed_at = null, last_error = %s,
                      error_message = case when %s then %s else error_message end,
                      next_attempt_at = case when %s then null
                                             else now() + make_interval(mins => %s) end
                where load_id = %s""",
            ("failed" if final else "loaded", message, final, message, final,
             RETRY_MINUTES * load.attempts, load.load_id),
        )
    return "failed" if final else "retrying"


def process_load(load: Load) -> str:
    """Cleanse + publish one load atomically. Returns 'published' or 'held'."""
    with transaction() as conn:
        counts = cleanse.run(conn, load)
        outcome = publish.run(conn, load)
        if outcome not in ("published", "held"):
            raise ValueError(f"publish.run returned {outcome!r}; expected 'published' or 'held'")
        conn.execute(
            """update ops.load_log
                  set status = %s, claimed_at = null, last_error = null, next_attempt_at = null,
                      rows_rejected = coalesce(%s, rows_rejected),
                      rows_published = coalesce(%s, rows_published),
                      reconciliation_status = case when %s = 'published' then 'passed' else 'failed' end,
                      published_at = case when %s = 'published' then now() else null end
                where load_id = %s""",
            (outcome, counts.get("rows_rejected"), counts.get("rows_clean"),
             outcome, outcome, load.load_id),
        )
    return outcome


def run_once(worker: str, max_loads: int, max_attempts: int, stale_minutes: int) -> int:
    run_id = _start_run(worker, "once")
    counts = dict(claimed=0, published=0, held=0, retrying=0, failed=0)
    waiting_msg = None
    scored_branches: set[tuple[str, str | None]] = set()

    while counts["claimed"] < max_loads:
        load = _claim(worker, max_attempts, stale_minutes)
        if load is None:
            break
        counts["claimed"] += 1
        log.info("load %s claimed (branch %s, %s rows, attempt %s)",
                 load.load_id, load.branch_id or "ALL", load.rows_loaded, load.attempts)
        try:
            outcome = process_load(load)
        except StepNotReady as e:
            _release(load)
            waiting_msg = str(e)
            log.info("load %s left in the queue: %s", load.load_id, e)
            break                      # every other load would stop at the same step
        except Exception as e:         # noqa: BLE001 - recorded on the load, run continues
            result = _record_failure(load, e, max_attempts)
            counts[result] += 1
            log.error("load %s %s: %s", load.load_id, result, type(e).__name__)
            continue
        counts[outcome] += 1
        log.info("load %s %s", load.load_id, outcome)
        if outcome == "published":
            scored_branches.add((load.client_id, load.branch_id))

    score_errors, notes = [], [waiting_msg] if waiting_msg else []
    for client_id, branch_id in sorted(scored_branches, key=str):
        try:
            with transaction() as conn:
                scoring.run(conn, client_id, branch_id, run_type="upload")
        except StepNotReady as e:      # loads are published; scores follow once scoring exists
            notes.append(str(e))
            break
        except Exception as e:         # noqa: BLE001
            score_errors.append(f"scoring {client_id}/{branch_id or 'ALL'} failed: {type(e).__name__}: {e}")
            log.error("scoring %s/%s failed: %s", client_id, branch_id, type(e).__name__)

    done = sum(counts[k] for k in ("published", "held", "failed", "retrying"))
    if waiting_msg and done == 0:
        status = "waiting"
    elif counts["failed"] or counts["retrying"] or score_errors:
        status = "partial"
    else:
        status = "succeeded"
    message = "; ".join(notes + score_errors)[:2000] or None
    _finish_run(run_id, status, counts, message)
    log.info("run %s %s: %s", run_id, status, counts)
    return 0


def run_nightly(worker: str) -> int:
    run_id = _start_run(worker, "nightly")
    zero = dict(claimed=0, published=0, held=0, retrying=0, failed=0)
    with transaction() as conn:
        clients = [r[0] for r in conn.execute(
            "select client_id from gold.dim_client where status = 'active' order by client_id")]
    try:
        for client_id in clients:
            with transaction() as conn:
                scoring.run(conn, client_id, None, run_type="nightly")
    except StepNotReady as e:
        _finish_run(run_id, "waiting", zero, str(e))
        log.info("nightly scoring waiting: %s", e)
        return 0
    except Exception as e:             # noqa: BLE001
        _finish_run(run_id, "failed", zero, f"{type(e).__name__}: {e}"[:2000])
        log.error("nightly scoring failed: %s", type(e).__name__)
        return 1
    _finish_run(run_id, "succeeded", zero, f"scored {len(clients)} client(s)")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="ProDash+ ETL worker")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--once", action="store_true", help="process waiting loads, then exit")
    mode.add_argument("--nightly", action="store_true", help="re-score every branch, then exit")
    p.add_argument("--worker", default=os.getenv("PRODASH_WORKER_NAME", socket.gethostname()),
                   help="name recorded in ops.etl_runs (e.g. github-actions, cpanel)")
    p.add_argument("--max-loads", type=int, default=20)
    p.add_argument("--max-attempts", type=int, default=3)
    p.add_argument("--stale-minutes", type=int, default=30)
    p.add_argument("--lock-file", default=os.path.join(os.path.expanduser("~"), ".prodash-worker.lock"))
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    with single_instance(args.lock_file) as got_lock:
        if not got_lock:
            log.info("another worker run is still going on this machine; exiting")
            return 0
        if args.once:
            return run_once(args.worker, args.max_loads, args.max_attempts, args.stale_minutes)
        return run_nightly(args.worker)


if __name__ == "__main__":
    sys.exit(main())
