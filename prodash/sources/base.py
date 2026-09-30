"""Building blocks for API feeds (see prodash.sync).

A source turns the shop system's receipts into rows of the CSV data contract
(prodash.contract), so everything after bronze treats an API batch like a file.
A new feed needs a field map and fetch(); flattening, landing and cursors are shared.
"""

from collections.abc import Iterator
from dataclasses import dataclass


class SourceNotReady(Exception):
    """The feed has no API client yet (waiting for documentation and credentials)."""


@dataclass
class Page:
    """One response from the source system."""
    receipts: list[dict]
    cursor: str | None      # change marker to resume from, e.g. the newest updated_at on this page


def dig(obj, path: str):
    """obj["a"]["b"] for path "a.b"; None when any step is missing."""
    for key in path.split("."):
        if not isinstance(obj, dict) or key not in obj:
            return None
        obj = obj[key]
    return obj


def flatten_receipts(receipts: list[dict], header_map: dict[str, str], line_map: dict[str, str],
                     lines_key: str = "lines") -> list[dict]:
    """One contract row per receipt line; receipt-level fields repeat on each line.

    Maps are {output column: dotted path in the source JSON}. Output columns
    outside the contract (e.g. product_code) land in bronze.receipts_raw.extra.
    """
    rows = []
    for receipt in receipts:
        head = {col: dig(receipt, path) for col, path in header_map.items()}
        for line in dig(receipt, lines_key) or []:
            rows.append({**head, **{col: dig(line, path) for col, path in line_map.items()}})
    return rows


class Source:
    """One shop system. Subclasses set the field maps and implement fetch()."""

    name = ""                           # ops.source_sync.source_name
    header_map: dict[str, str] = {}     # contract column -> path in a receipt
    line_map: dict[str, str] = {}       # contract column -> path in one of its lines
    lines_key = "lines"                 # path to the list of lines in a receipt

    def fetch(self, external_id: str, since: str | None) -> Iterator[Page]:
        """Pages of receipts created or changed at shop external_id since the marker (None = everything)."""
        raise SourceNotReady(f"{self.name}: no API client yet")

    def to_contract(self, receipts: list[dict]) -> list[dict]:
        return flatten_receipts(receipts, self.header_map, self.line_map, self.lines_key)
