import pandas as pd

from prodash.landing import canonical_json, parse_receipt_dates, records_frame
from prodash.sources.base import dig, flatten_receipts
from prodash.sync import fetch_since


def test_flatten_repeats_receipt_fields_on_each_line():
    receipts = [
        {"number": "R1", "customer": {"phone": "0772 123 456"},
         "lines": [{"item": {"name": "LIFE 250ml"}, "qty": 2}, {"item": {"name": "Yoghurt 500ml"}, "qty": 1}]},
        {"number": "R2", "lines": []},
    ]
    rows = flatten_receipts(receipts, {"receipt_no": "number", "customer_cell": "customer.phone"},
                            {"product": "item.name", "quantity": "qty", "unit": "unit"})
    assert rows == [
        {"receipt_no": "R1", "customer_cell": "0772 123 456", "product": "LIFE 250ml", "quantity": 2, "unit": None},
        {"receipt_no": "R1", "customer_cell": "0772 123 456", "product": "Yoghurt 500ml", "quantity": 1, "unit": None},
    ]


def test_dig_returns_none_for_a_missing_path():
    assert dig({"a": {"b": 1}}, "a.b") == 1
    assert dig({"a": {"b": 1}}, "a.c") is None
    assert dig({"a": 5}, "a.b") is None


def test_canonical_json_ignores_key_order():
    assert canonical_json([{"a": 1, "b": "x"}]) == canonical_json([{"b": "x", "a": 1}])


def test_records_frame_holds_text_like_a_csv():
    df = records_frame([{"quantity": 12, "unit_price": 0.45, "product": " LIFE 250ml "},
                        {"quantity": None, "note": "x"}])
    assert list(df.columns) == ["quantity", "unit_price", "product", "note"]
    assert df.iloc[0].tolist() == ["12", "0.45", "LIFE 250ml", ""]
    assert df.iloc[1].tolist() == ["", "", "", "x"]


def test_iso_dates_are_never_read_day_first():
    s = pd.Series(["2026-10-05 10:42", "17/04/2026 09:05", ""], dtype=str)
    out = parse_receipt_dates(s, None, dayfirst=True)
    assert out[0] == pd.Timestamp("2026-10-05 10:42")      # not 10 May
    assert out[1] == pd.Timestamp("2026-04-17 09:05")
    assert pd.isna(out[2])


def test_utc_offsets_become_harare_time():
    s = pd.Series(["2026-10-05T10:42:00+02:00", "2026-10-05T23:30:00Z", "2026-10-05 08:00"], dtype=str)
    out = parse_receipt_dates(s, None, dayfirst=False)
    assert list(out) == [pd.Timestamp("2026-10-05 10:42"), pd.Timestamp("2026-10-06 01:30"),
                         pd.Timestamp("2026-10-05 08:00")]


def test_fetch_since_steps_back_over_the_overlap():
    assert fetch_since(None) is None
    assert fetch_since("2026-10-05T10:45:00+02:00") == "2026-10-05T10:35:00+02:00"
    assert fetch_since("page-token-42") == "page-token-42"
