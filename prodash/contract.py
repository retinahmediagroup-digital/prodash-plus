"""The CSV data contract (SSOT §5.1-5.2), as code.

Two accepted shapes:
  line_item  one row per product line (preferred)
  packed     one row per receipt, items in one text column, e.g. "2x LIFE 250ml; 1x Yoghurt 500ml"

Headers are normalised (lower case, spaces/dashes -> underscores) and then
renamed through HEADER_ALIASES. Add ProDairy's real column names to
HEADER_ALIASES once the first file arrives, e.g. "cell_number": "customer_cell".
"""

import re
from dataclasses import dataclass, field

# bronze.receipts_raw columns, in contract order
CONTRACT_COLUMNS = [
    "receipt_no", "receipt_datetime", "branch", "trader_code", "customer_name",
    "customer_cell", "product", "quantity", "unit", "unit_price", "line_total",
    "currency", "payment_method", "customer_type", "fulfilment_type", "items_packed",
]

REQUIRED_COMMON = ["receipt_no", "receipt_datetime", "branch", "customer_name"]
REQUIRED_LINE_ITEM = ["product", "quantity", "unit_price", "line_total"]
REQUIRED_PACKED = ["items_packed"]
# customer_cell is required by the contract but a missing value is allowed per row
# (walk-ins): the column must exist, the cell may be empty.
REQUIRED_PRESENT = ["customer_cell"]

HEADER_ALIASES: dict[str, str] = {
    "receipt_number": "receipt_no",
    "receipt": "receipt_no",
    "date": "receipt_datetime",
    "datetime": "receipt_datetime",
    "receipt_date": "receipt_datetime",
    "branch_name": "branch",
    "shop": "branch",
    "name": "customer_name",
    "customer": "customer_name",
    "cell": "customer_cell",
    "cell_number": "customer_cell",
    "phone": "customer_cell",
    "phone_number": "customer_cell",
    "mobile": "customer_cell",
    "item": "product",
    "product_name": "product",
    "qty": "quantity",
    "price": "unit_price",
    "total": "line_total",
    "amount": "line_total",
    "items": "items_packed",
}


def normalise_header(name: str) -> str:
    h = re.sub(r"[\s\-/]+", "_", str(name).strip().lower())
    h = re.sub(r"[^a-z0-9_]", "", h)
    return HEADER_ALIASES.get(h, h)


@dataclass
class HeaderReport:
    shape: str | None                      # 'line_item', 'packed' or None if neither fits
    mapping: dict[str, str]                # original header -> contract column
    missing: list[str] = field(default_factory=list)
    unknown: list[str] = field(default_factory=list)   # kept in bronze.receipts_raw.extra
    duplicates: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.shape is not None and not self.missing and not self.duplicates


def check_headers(headers: list[str]) -> HeaderReport:
    mapping = {h: normalise_header(h) for h in headers}
    targets = list(mapping.values())
    duplicates = sorted({t for t in targets if targets.count(t) > 1 and t in CONTRACT_COLUMNS})
    present = set(targets)
    unknown = [h for h, t in mapping.items() if t not in CONTRACT_COLUMNS]

    common_missing = [c for c in REQUIRED_COMMON + REQUIRED_PRESENT if c not in present]
    line_missing = [c for c in REQUIRED_LINE_ITEM if c not in present]
    packed_missing = [c for c in REQUIRED_PACKED if c not in present]

    if not line_missing:
        shape, missing = "line_item", common_missing
    elif not packed_missing:
        shape, missing = "packed", common_missing
    else:
        shape, missing = None, common_missing + line_missing

    return HeaderReport(shape=shape, mapping=mapping, missing=missing,
                        unknown=unknown, duplicates=duplicates)
