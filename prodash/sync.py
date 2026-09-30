"""Pull API feeds into bronze:  python -m prodash.sync --once

Each active row of ops.source_sync is a feed: one source system (e.g. pos_api)
and one of our branches, with the shop's id in that system and a cursor. For
each feed, fetch what changed since the cursor (minus OVERLAP, to catch late
edits), then land each page with land_batch() and move the cursor forward in
the same transaction. A crash repeats the page: landing ignores a batch it has
already seen, and silver keeps the latest copy of a re-sent receipt. A rejected
page stops that feed without moving its cursor, so nothing is skipped.

Run it just before the worker, from the same cron entry:
    python -m prodash.sync --once; python -m prodash.worker --once
Logs carry counts and ids only, never trader names or phone numbers.
"""

import argparse
import logging
import os
import socket
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta

from prodash.db import transaction
from prodash.landing import land_batch
from prodash.sources import SOURCES, SourceNotReady
from prodash.worker import single_instance

log = logging.getLogger("prodash.sync")

OVERLAP = timedelta(minutes=10)      # re-read this much before the cursor on every run


@dataclass(frozen=True)
class Feed:
    client_id: str
    source_name: str
    branch_id: str
    external_id: str
    cursor: str | None


def fetch_since(cursor: str | None) -> str | None:
    """The cursor minus OVERLAP when it is a timestamp; other markers pass through unchanged."""
    if not cursor:
        return None
    try:
        return (datetime.fromisoformat(cursor) - OVERLAP).isoformat()
    except ValueError:
        return cursor


def active_feeds(source_name: str | None = None) -> list[Feed]:
    with transaction() as conn:
        if conn.execute("select to_regclass('ops.source_sync')").fetchone()[0] is None:
            log.info("ops.source_sync does not exist yet; apply sql/15_api_source.sql first")
            return []
        rows = conn.execute(
            """select client_id, source_name, branch_id, external_id, cursor_value
               from ops.source_sync
               where is_active and (%(s)s::text is null or source_name = %(s)s)
               order by client_id, source_name, branch_id""",
            {"s": source_name},
        ).fetchall()
    return [Feed(*row) for row in rows]


_FEED = "where client_id = %s and source_name = %s and branch_id = %s"


def _key(feed: Feed) -> tuple:
    return feed.client_id, feed.source_name, feed.branch_id


def sync_feed(feed: Feed, *, store: bool = True) -> dict:
    """Land everything new for one feed. Returns counts; raises when the source fails."""
    source = SOURCES.get(feed.source_name)
    if source is None:
        raise KeyError(f"no source named {feed.source_name!r} in prodash.sources")
    counts = dict(pages=0, landed=0, rows=0, duplicate=0, empty=0, rejected=0)
    since = fetch_since(feed.cursor)
    for page in source.fetch(feed.external_id, since):
        counts["pages"] += 1
        label = f"{feed.source_name} {feed.branch_id} since {since or 'start'}, page {counts['pages']}"
        with transaction() as conn:
            result = land_batch(conn, source.to_contract(page.receipts), branch_id=feed.branch_id,
                                batch_label=label, client_id=feed.client_id, store=store)
            if result.status == "rejected":
                conn.execute(f"update ops.source_sync set last_error = %s, updated_at = now() {_FEED}",
                             (f"load {result.load_id} rejected: {result.message}"[:2000], *_key(feed)))
            else:
                conn.execute(
                    f"""update ops.source_sync
                           set cursor_value = coalesce(%s, cursor_value), last_synced_at = now(),
                               last_load_id = coalesce(%s, last_load_id), last_error = null, updated_at = now()
                        {_FEED}""",
                    (page.cursor, result.load_id if result.status == "loaded" else None, *_key(feed)),
                )
        if result.status == "loaded":
            counts["landed"] += 1
            counts["rows"] += result.rows_in_file
        else:
            counts[result.status] += 1
        if result.status == "rejected":
            log.error("feed %s/%s: load %s rejected; cursor kept", feed.source_name, feed.branch_id, result.load_id)
            break
    return counts


def _start_run(worker: str) -> int:
    with transaction() as conn:
        return conn.execute(
            "insert into ops.etl_runs (worker, mode) values (%s, 'sync') returning run_id", (worker,)
        ).fetchone()[0]


def _finish_run(run_id: int, status: str, landed: int, message: str | None) -> None:
    with transaction() as conn:
        conn.execute(
            """update ops.etl_runs set status = %s, loads_landed = %s, message = %s, finished_at = now()
                where run_id = %s""",
            (status, landed, message, run_id),
        )


def run_once(worker: str, source_name: str | None = None, store: bool = True) -> int:
    feeds = active_feeds(source_name)
    if not feeds:
        log.info("no active feeds; nothing to sync")
        return 0
    run_id = _start_run(worker)
    landed = failed = waiting = 0
    notes: list[str] = []
    for feed in feeds:
        name = f"{feed.source_name}/{feed.branch_id}"
        try:
            counts = sync_feed(feed, store=store)
        except SourceNotReady as e:
            waiting += 1
            notes.append(str(e))
            log.info("feed %s waiting: %s", name, e)
            continue
        except Exception as e:           # noqa: BLE001 - recorded on the feed; other feeds continue
            failed += 1
            message = f"{type(e).__name__}: {e}"[:2000]
            with transaction() as conn:
                conn.execute(f"update ops.source_sync set last_error = %s, updated_at = now() {_FEED}",
                             (message, *_key(feed)))
            notes.append(f"{name}: {message}")
            log.error("feed %s failed: %s", name, type(e).__name__)
            continue
        landed += counts["landed"]
        if counts["rejected"]:
            failed += 1
            notes.append(f"{name}: a page was rejected; see ops.source_sync.last_error")
        log.info("feed %s: %s", name, counts)

    if waiting == len(feeds):
        status = "waiting"
    elif failed == len(feeds):
        status = "failed"
    elif failed or waiting:
        status = "partial"
    else:
        status = "succeeded"
    _finish_run(run_id, status, landed, "; ".join(dict.fromkeys(notes))[:2000] or None)
    log.info("run %s %s: %s batches landed from %s feeds", run_id, status, landed, len(feeds))
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="ProDash+ API feed sync")
    p.add_argument("--once", action="store_true", required=True, help="sync every active feed, then exit")
    p.add_argument("--source", help="only this source, e.g. pos_api")
    p.add_argument("--worker", default=os.getenv("PRODASH_WORKER_NAME", socket.gethostname()),
                   help="name recorded in ops.etl_runs (e.g. cpanel)")
    p.add_argument("--lock-file", default=os.path.join(os.path.expanduser("~"), ".prodash-sync.lock"))
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    with single_instance(args.lock_file) as got_lock:
        if not got_lock:
            log.info("another sync run is still going on this machine; exiting")
            return 0
        return run_once(args.worker, args.source)


if __name__ == "__main__":
    sys.exit(main())
