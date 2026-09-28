"""Integration test for prodash.landing against a THROWAWAY database.

Runs only when PRODASH_TEST_DB_URL is set (e.g. the local database built by
tests/sql/run_local.sh, connecting as etl_worker). Never point it at Supabase.
"""

import os
import uuid

import pandas as pd
import pytest

TEST_URL = os.getenv("PRODASH_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not TEST_URL, reason="PRODASH_TEST_DB_URL not set")

CSV = """Receipt No,Date,Branch,Customer,Cell Number,Product,Qty,Unit Price,Total,Till Operator
HFD-000001,17/04/2026 10:42,Highfield,Tendai Moyo,0772 123 456,LIFE 250ml,12,0.45,5.40,Rudo
HFD-000001,17/04/2026 10:42,Highfield,Tendai Moyo,0772 123 456,Yoghurt 500ml,1,1.20,1.20,Rudo
HFD-000002,02/05/2026 09:05,Highfield,,,LIFE 250ml,2,0.45,0.90,{run_id}
"""


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


def test_land_reject_retry_and_duplicate(env, tmp_path):
    from prodash import contract
    from prodash.db import read_sql
    from prodash.landing import land_file

    f = tmp_path / "hf_sample.csv"
    f.write_text(CSV.format(run_id=uuid.uuid4().hex))   # unique file per run: no false "duplicate"

    # "Customer" and "Total" are aliases, "Date" too; drop an alias to force a rejection first
    saved = contract.HEADER_ALIASES.pop("total")
    try:
        r = land_file(f, branch_id="HF", store=False)
        assert r.status == "rejected" and "line_total" in r.message
    finally:
        contract.HEADER_ALIASES["total"] = saved

    r2 = land_file(f, branch_id="HF", store=False)
    assert r2.status == "loaded" and r2.load_id == r.load_id          # retry reuses the load
    assert r2.shape == "line_item" and r2.rows_in_file == 3
    assert str(r2.min_receipt_date) == "2026-04-17" and str(r2.max_receipt_date) == "2026-05-02"

    raw = read_sql("select * from bronze.receipts_raw where load_id = %(id)s order by row_num", {"id": r2.load_id})
    assert list(raw.row_num) == [1, 2, 3]
    assert raw.customer_cell[0] == "0772 123 456"                      # untouched text
    assert pd.isna(raw.customer_cell[2])                               # empty -> null
    assert raw.extra[0] == {"Till Operator": "Rudo"}                   # unknown column kept
    log = read_sql("select status, rows_in_file, rows_loaded from ops.load_log where load_id = %(id)s",
                   {"id": r2.load_id}).iloc[0]
    assert (log.status, log.rows_in_file, log.rows_loaded) == ("loaded", 3, 3)

    r3 = land_file(f, branch_id="HF", store=False)
    assert r3.status == "duplicate" and r3.load_id == r2.load_id
