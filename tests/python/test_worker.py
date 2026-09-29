"""Integration tests for prodash.worker against a THROWAWAY database.

Runs only when PRODASH_TEST_DB_URL is set (see test_landing.py). Never point it at Supabase.
"""

import os
import uuid

import pytest

TEST_URL = os.getenv("PRODASH_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not TEST_URL, reason="PRODASH_TEST_DB_URL not set")

CSV = """receipt_no,receipt_datetime,branch,customer_name,customer_cell,product,quantity,unit_price,line_total
R-{tag},2026-09-20 10:00,Highfield,Test Trader,0772000001,LIFE 250ml,1,0.45,0.45
"""


@pytest.fixture()
def env(monkeypatch):
    from prodash import config, db
    monkeypatch.setenv("PRODASH_DB_URL", TEST_URL)
    config.settings.cache_clear()
    db.engine.cache_clear()
    # park anything other tests left in the queue so each test sees only its own loads
    with db.transaction() as conn:
        conn.execute("""update ops.load_log set status = 'failed', claimed_at = null,
                               finished_at = coalesce(finished_at, now())
                         where status in ('loaded', 'processing')""")
    yield
    config.settings.cache_clear()
    db.engine.cache_clear()


def land(tmp_path):
    from prodash.landing import land_file
    f = tmp_path / f"{uuid.uuid4().hex}.csv"
    f.write_text(CSV.format(tag=uuid.uuid4().hex[:8]))
    r = land_file(f, branch_id="HF", store=False)
    assert r.status == "loaded"
    return r.load_id


def load_row(load_id):
    from prodash.db import read_sql
    return read_sql("""select status, attempts, claimed_at, next_attempt_at, published_at,
                              reconciliation_status, error_message, last_error
                       from ops.load_log where load_id = %(id)s""", {"id": load_id}).iloc[0]


def last_run():
    from prodash.db import read_sql
    return read_sql("select * from ops.etl_runs order by run_id desc limit 1").iloc[0]


def test_steps_not_written_yet_leave_load_queued(env, tmp_path):
    from prodash import worker
    load_id = land(tmp_path)
    assert worker.main(["--once", "--worker", "pytest", "--lock-file", str(tmp_path / "lock")]) == 0
    row = load_row(load_id)
    assert row.status == "loaded" and row.attempts == 0 and row.claimed_at is None
    run = last_run()
    assert run.status == "waiting" and "cleanse is not implemented" in run.message


def test_published_and_scored(env, tmp_path, monkeypatch):
    from prodash import cleanse, publish, scoring, worker
    calls = []
    monkeypatch.setattr(cleanse, "run", lambda conn, load: {"rows_clean": 1, "rows_rejected": 0})
    monkeypatch.setattr(publish, "run", lambda conn, load: "published")
    monkeypatch.setattr(scoring, "run", lambda conn, c, b, run_type: calls.append((c, b, run_type)) or {})
    load_id = land(tmp_path)
    worker.main(["--once", "--worker", "pytest", "--lock-file", str(tmp_path / "lock")])
    row = load_row(load_id)
    assert row.status == "published" and row.published_at is not None
    assert row.reconciliation_status == "passed" and row.claimed_at is None
    assert calls == [("PRODAIRY", "HF", "upload")]
    run = last_run()
    assert run.status == "succeeded" and run.loads_published == 1


def test_held_when_reconciliation_fails(env, tmp_path, monkeypatch):
    from prodash import cleanse, publish, scoring, worker
    monkeypatch.setattr(cleanse, "run", lambda conn, load: {})
    monkeypatch.setattr(publish, "run", lambda conn, load: "held")
    monkeypatch.setattr(scoring, "run", lambda *a, **k: pytest.fail("held loads must not be scored"))
    load_id = land(tmp_path)
    worker.main(["--once", "--worker", "pytest", "--lock-file", str(tmp_path / "lock")])
    row = load_row(load_id)
    assert row.status == "held" and row.published_at is None and row.reconciliation_status == "failed"


def test_failure_retries_then_fails(env, tmp_path, monkeypatch):
    from prodash import cleanse, worker
    from prodash.db import transaction

    def boom(conn, load):
        conn.execute("insert into ops.etl_runs (worker, mode) values ('must-roll-back', 'once')")
        raise RuntimeError("bad data")

    monkeypatch.setattr(cleanse, "run", boom)
    load_id = land(tmp_path)
    args = ["--once", "--worker", "pytest", "--max-attempts", "2", "--lock-file", str(tmp_path / "lock")]

    worker.main(args)
    row = load_row(load_id)
    assert row.status == "loaded" and row.attempts == 1 and row.next_attempt_at is not None
    assert "bad data" in row.last_error and row.error_message is None
    assert last_run().status == "partial"

    worker.main(args)                       # back-off: not due yet, nothing claimed
    assert load_row(load_id).attempts == 1

    with transaction() as conn:
        conn.execute("update ops.load_log set next_attempt_at = now() - interval '1 minute' where load_id = %s",
                     (load_id,))
    worker.main(args)
    row = load_row(load_id)
    assert row.status == "failed" and row.attempts == 2 and "bad data" in row.error_message

    from prodash.db import read_sql
    assert read_sql("select count(*) as n from ops.etl_runs where worker = 'must-roll-back'").n[0] == 0


def test_two_workers_never_claim_the_same_load(env, tmp_path):
    import psycopg
    ids = {land(tmp_path), land(tmp_path)}
    a = psycopg.connect(TEST_URL)
    b = psycopg.connect(TEST_URL)
    try:
        with a.transaction(), b.transaction():
            ra = a.execute("select load_id from ops.claim_next_load('a')").fetchone()
            rb = b.execute("select load_id from ops.claim_next_load('b')").fetchone()
            assert ra and rb and ra[0] != rb[0] and {ra[0], rb[0]} == ids
    finally:
        a.close()
        b.close()
