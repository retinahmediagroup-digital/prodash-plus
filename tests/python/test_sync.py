"""Integration tests for prodash.sync against a THROWAWAY database.

Runs only when PRODASH_TEST_DB_URL is set (see test_landing.py). Never point it at Supabase.
"""

import os
import uuid

import pytest

from prodash.sources.base import Page, Source, SourceNotReady

TEST_URL = os.getenv("PRODASH_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not TEST_URL, reason="PRODASH_TEST_DB_URL not set")


class FakePos(Source):
    name = "fake_pos"
    header_map = {"receipt_no": "number", "receipt_datetime": "at", "customer_name": "customer.name",
                  "customer_cell": "customer.phone", "currency": "currency"}
    line_map = {"product": "item", "quantity": "qty", "unit_price": "price", "line_total": "total"}

    def __init__(self, pages=(), error=None):
        self.pages, self.error, self.calls = list(pages), error, []

    def fetch(self, external_id, since):
        self.calls.append((external_id, since))
        if self.error:
            raise self.error
        yield from self.pages


def receipt(number, at, qty=12):
    return {"number": number, "at": at, "currency": "USD",
            "customer": {"name": "Tendai Moyo", "phone": "0772 123 456"},
            "lines": [{"item": "LIFE 250ml", "qty": qty, "price": 0.45, "total": round(qty * 0.45, 2)}]}


def pages(tag):
    return [
        Page([receipt(f"{tag}-1", "2026-10-05T10:00:00+02:00")], cursor="2026-10-05T10:00:00+02:00"),
        Page([receipt(f"{tag}-2", "2026-10-05T10:30:00+02:00"),
              receipt(f"{tag}-3", "2026-10-05T10:45:00+02:00", qty=24)], cursor="2026-10-05T10:45:00+02:00"),
    ]


@pytest.fixture()
def env(monkeypatch):
    from prodash import config, db
    monkeypatch.setenv("PRODASH_DB_URL", TEST_URL)
    monkeypatch.setenv("PRODASH_CLIENT_ID", "PRODAIRY")
    config.settings.cache_clear()
    db.engine.cache_clear()
    with db.transaction() as conn:   # only this test's feed is active
        conn.execute("update ops.source_sync set is_active = false")
        conn.execute("""insert into ops.source_sync (client_id, source_name, branch_id, external_id, is_active)
                        values ('PRODAIRY', 'fake_pos', 'HF', 'SHOP-HF', true)
                        on conflict (client_id, source_name, branch_id) do update
                          set is_active = true, cursor_value = null, last_error = null,
                              last_load_id = null, last_synced_at = null""")
    yield
    config.settings.cache_clear()
    db.engine.cache_clear()


def feed():
    from prodash.db import read_sql
    return read_sql("""select cursor_value, last_load_id, last_error, last_synced_at from ops.source_sync
                       where source_name = 'fake_pos' and branch_id = 'HF'""").iloc[0]


def last_run():
    from prodash.db import read_sql
    return read_sql("select * from ops.etl_runs order by run_id desc limit 1").iloc[0]


def test_sync_lands_each_page_and_moves_the_cursor(env, monkeypatch):
    from prodash import sync
    from prodash.db import read_sql
    tag = uuid.uuid4().hex[:8]
    fake = FakePos(pages(tag))
    monkeypatch.setattr(sync, "SOURCES", {"fake_pos": fake})
    assert sync.run_once("pytest", store=False) == 0

    assert fake.calls == [("SHOP-HF", None)]                       # first sync: everything
    row = feed()
    assert row.cursor_value == "2026-10-05T10:45:00+02:00" and row.last_error is None
    lines = read_sql("select receipt_no, quantity, branch from bronze.receipts_raw where load_id = %(id)s order by row_num",
                     {"id": int(row.last_load_id)})
    assert list(lines.receipt_no) == [f"{tag}-2", f"{tag}-3"] and list(lines.quantity) == ["12", "24"]
    assert set(lines.branch) == {"HF"}
    run = last_run()
    assert (run["mode"], run["status"], run["loads_landed"]) == ("sync", "succeeded", 2)


def test_next_sync_rereads_the_overlap_and_skips_what_it_has(env, monkeypatch):
    from prodash import sync
    fake = FakePos(pages(uuid.uuid4().hex[:8]))
    monkeypatch.setattr(sync, "SOURCES", {"fake_pos": fake})
    sync.run_once("pytest", store=False)
    sync.run_once("pytest", store=False)
    assert fake.calls[1] == ("SHOP-HF", "2026-10-05T10:35:00+02:00")    # cursor minus 10 minutes
    run = last_run()
    assert (run["status"], run["loads_landed"]) == ("succeeded", 0)      # both pages already landed
    assert feed().cursor_value == "2026-10-05T10:45:00+02:00"


def test_rejected_page_keeps_the_cursor_and_stops_the_feed(env, monkeypatch):
    from prodash import sync

    class NoTimes(FakePos):
        header_map = {k: v for k, v in FakePos.header_map.items() if k != "receipt_datetime"}

    monkeypatch.setattr(sync, "SOURCES", {"fake_pos": NoTimes(pages(uuid.uuid4().hex[:8]))})
    sync.run_once("pytest", store=False)
    row = feed()
    assert row.cursor_value is None and row.last_load_id is None
    assert "rejected" in row.last_error and "receipt_datetime" in row.last_error
    run = last_run()
    assert (run["status"], run["loads_landed"]) == ("failed", 0)


def test_source_without_a_client_leaves_the_run_waiting(env, monkeypatch):
    from prodash import sync
    fake = FakePos(error=SourceNotReady("fake_pos: no API client yet"))
    monkeypatch.setattr(sync, "SOURCES", {"fake_pos": fake})
    sync.run_once("pytest", store=False)
    run = last_run()
    assert run["status"] == "waiting" and "no API client yet" in run["message"]
    assert feed().last_error is None


def test_failing_source_is_recorded_on_the_feed(env, monkeypatch):
    from prodash import sync
    monkeypatch.setattr(sync, "SOURCES", {"fake_pos": FakePos(error=ConnectionError("shop system unreachable"))})
    sync.run_once("pytest", store=False)
    assert feed().last_error == "ConnectionError: shop system unreachable"
    assert last_run()["status"] == "failed"


def test_no_active_feeds_means_no_run(env, monkeypatch):
    from prodash import sync
    from prodash.db import read_sql, transaction
    with transaction() as conn:
        conn.execute("update ops.source_sync set is_active = false")
    before = read_sql("select count(*) as n from ops.etl_runs").n[0]
    assert sync.run_once("pytest", store=False) == 0
    assert read_sql("select count(*) as n from ops.etl_runs").n[0] == before
