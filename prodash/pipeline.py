"""Shared types for the ETL steps run by prodash.worker."""

from dataclasses import dataclass
from datetime import date


class StepNotReady(Exception):
    """Raised by a step whose logic has not been written yet.

    The worker puts the load back in the queue untouched (no attempt counted),
    so nothing is lost while cleansing/publishing is still being developed.
    """


@dataclass(frozen=True)
class Load:
    """One queued file, as claimed from ops.load_log."""
    load_id: int
    client_id: str
    branch_id: str | None
    source_file: str
    rows_loaded: int
    min_receipt_date: date | None
    max_receipt_date: date | None
    attempts: int
