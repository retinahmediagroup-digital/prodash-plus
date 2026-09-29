from prodash.contract import check_headers, normalise_header


def test_normalise_header_aliases_and_spacing():
    assert normalise_header(" Cell Number ") == "customer_cell"
    assert normalise_header("Receipt-No") == "receipt_no"
    assert normalise_header("QTY") == "quantity"
    assert normalise_header("Unit Price (USD)") == "unit_price_usd"   # unknown: kept in extra


def test_line_item_shape_ok():
    r = check_headers(["Receipt No", "Receipt Datetime", "Branch", "Customer Name", "Cell",
                       "Product", "Qty", "Unit Price", "Line Total", "Till Operator"])
    assert r.ok and r.shape == "line_item"
    assert r.unknown == ["Till Operator"]


def test_packed_shape_ok():
    r = check_headers(["receipt_no", "receipt_datetime", "branch", "customer_name", "customer_cell", "Items"])
    assert r.ok and r.shape == "packed"


def test_missing_columns_reported():
    r = check_headers(["receipt_no", "branch", "product", "quantity", "unit_price", "line_total"])
    assert not r.ok
    assert set(r.missing) == {"receipt_datetime", "customer_name", "customer_cell"}


def test_two_headers_mapping_to_one_column_rejected():
    r = check_headers(["receipt_no", "receipt_datetime", "branch", "customer_name",
                       "Cell", "Phone", "product", "quantity", "unit_price", "line_total"])
    assert not r.ok and r.duplicates == ["customer_cell"]
