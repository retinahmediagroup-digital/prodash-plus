"""Integration tests for prodash.landing.land_batch against a THROWAWAY database.

Runs only when PRODASH_TEST_DB_URL is set (see test_landing.py). Never point it at Supabase.
"""

import os
import uuid

import pandas as pd
import pytest

TEST_URL = os.getenv("PRODASH_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not TEST_URL, reason="PRODASH_TEST_DB_URL not set")


@pytest.fixture()
def env(monkeypatch):
    from prodash import config, db
    monkeypatch.setenv("PRODASH_DB_URL", TEST_URL)
    monkeypatch.setenv("PRODASH_CLIENT_ID", "PRODAIRY")
    config.settings.cache_clear()
    db.engine.cache_clear()
    yield
    config.settings.cache_clear()
    db.engine.cache_clear()


def records(tag):
    """Two receipts as a source's to_contract() returns them."""
    return [
        {"receipt_no": f"API-{tag}-1", "receipt_datetime": "2026-10-05T10:42:00+02:00",
         "customer_name": "Tendai Moyo", "customer_cell": "0772 123 456", "product": "LIFE 250ml",
         "product_code": "SKU-250", "quantity": 12, "unit_price": 0.45, "line_total": 5.4, "currency": "USD"},
        {"receipt_no": f"API-{tag}-2", "receipt_datetime": "2026-10-05T23:30:00Z",
         "customer_name": "", "customer_cell": None, "product": "LIFE 250ml",
         "product_code": None, "quantity": 2, "unit_price": 0.45, "line_total": 0.9, "currency": "USD"},
    ]


def test_land_batch_lands_records_as_an_api_load(env):
    from prodash.db import read_sql, transaction
    from prodash.landing import land_batch
    tag = uuid.uuid4().hex[:8]
    with transaction() as conn:
        r = land_batch(conn, records(tag), branch_id="HF", batch_label=f"test {tag}", store=False)
    assert r.status == "loaded" and r.shape == "line_item" and r.rows_in_file == 2
    assert r.unknown_columns == ["product_code"]
    assert str(r.min_receipt_date) == "2026-10-05"
    assert str(r.max_receipt_date) == "2026-10-06"          # 23:30 UTC is 01:30 the next day in Harare

    raw = read_sql("select * from bronze.receipts_raw where load_id = %(id)s order by row_num", {"id": r.load_id})
    assert list(raw.receipt_no) == [f"API-{tag}-1", f"API-{tag}-2"]
    assert list(raw.branch) == ["HF", "HF"]                  # filled from branch_id
    assert raw.quantity[0] == "12" and raw.line_total[0] == "5.4"
    assert pd.isna(raw.customer_cell[1])                     # empty -> null, as for a CSV
    assert raw.extra[0] == {"product_code": "SKU-250"} and pd.isna(raw.extra[1])

    log = read_sql("select source, file_shape, storage_path, status from ops.load_log where load_id = %(id)s",
                   {"id": r.load_id}).iloc[0]
    assert (log.source, log.file_shape, log.status) == ("api", "line_item", "loaded")
    assert log.storage_path.startswith("PRODAIRY/HF/") and log.storage_path.endswith(".json")


def test_same_batch_twice_is_a_duplicate(env):
    from prodash.db import transaction
    from prodash.landing import land_batch
    recs = records(uuid.uuid4().hex[:8])
    with transaction() as conn:
        first = land_batch(conn, recs, branch_id="HF", batch_label="first", store=False)
    reordered = [dict(reversed(list(r.items()))) for r in recs]
    with transaction() as conn:
        again = land_batch(conn, reordered, branch_id="HF", batch_label="again", store=False)
    assert first.status == "loaded"
    assert again.status == "duplicate" and again.load_id == first.load_id


def test_empty_batch_lands_nothing(env):
    from prodash.db import transaction
    from prodash.landing import land_batch
    with transaction() as conn:
        r = land_batch(conn, [], branch_id="HF", batch_label="nothing new", store=False)
    assert r.status == "empty" and r.load_id is None


def test_land_batch_rolls_back_with_the_callers_transaction(env):
    from prodash.db import read_sql, transaction
    from prodash.landing import land_batch
    label = f"rolled back {uuid.uuid4().hex[:8]}"
    with pytest.raises(RuntimeError):
        with transaction() as conn:
            land_batch(conn, records(uuid.uuid4().hex[:8]), branch_id="HF", batch_label=label, store=False)
            raise RuntimeError("cursor update failed")
    assert read_sql("select count(*) as n from ops.load_log where source_file = %(l)s", {"l": label}).n[0] == 0


def test_missing_contract_field_rejects_the_batch(env):
    from prodash.db import transaction
    from prodash.landing import land_batch
    recs = [{k: v for k, v in r.items() if k != "receipt_datetime"} for r in records(uuid.uuid4().hex[:8])]
    with transaction() as conn:
        r = land_batch(conn, recs, branch_id="HF", batch_label="no times", store=False)
    assert r.status == "rejected" and "receipt_datetime" in r.message


@pytest.fixture()
def branch_on(env):
    """Set HF's expected source for one test; back to csv afterwards."""
    from prodash.db import transaction

    def set_source(value):
        with transaction() as conn:
            conn.execute("update gold.dim_branch set ingest_source = %s where client_id = 'PRODAIRY' and branch_id = 'HF'",
                         (value,))
    yield set_source
    set_source("csv")


def test_worker_waits_for_the_switch_then_processes_an_api_load(branch_on, tmp_path, monkeypatch):
    from prodash import cleanse, publish, scoring, worker
    from prodash.db import read_sql, transaction
    from prodash.landing import land_batch
    with transaction() as conn:   # park other queued loads so this test sees only its own
        conn.execute("""update ops.load_log set status = 'failed', claimed_at = null,
                               finished_at = coalesce(finished_at, now())
                         where status in ('loaded', 'processing')""")
        r = land_batch(conn, records(uuid.uuid4().hex[:8]), branch_id="HF", batch_label="to publish", store=False)
    monkeypatch.setattr(cleanse, "run", lambda conn, load: {"rows_clean": 2, "rows_rejected": 0})
    monkeypatch.setattr(publish, "run", lambda conn, load: "published")
    monkeypatch.setattr(scoring, "run", lambda *a, **k: {})
    args = ["--once", "--worker", "pytest", "--lock-file", str(tmp_path / "lock")]

    def status():
        return read_sql("select status from ops.load_log where load_id = %(id)s", {"id": r.load_id}).status[0]

    branch_on("csv")              # shadow week: the batch waits in bronze
    worker.main(args)
    assert status() == "loaded"
    branch_on("api")              # switched: processed like a file
    worker.main(args)
    assert status() == "published"
