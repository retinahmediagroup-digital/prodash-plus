"""bronze -> silver: cleanse one landed file.

Contract for run():
  - read bronze.receipts_raw for load.load_id
  - write the cleaned lines to silver.receipt_items (delete that load's
    earlier rows first, so a retry never duplicates) and row-level problems
    to ops.load_rejects
  - use only `conn` (the worker commits or rolls back the whole load)
  - return a dict of counts, e.g. {"rows_clean": 1203, "rows_rejected": 14}

Develop the logic in notebooks/02_cleanse.ipynb, then move it here.
"""

import psycopg

from prodash.pipeline import Load, StepNotReady


def run(conn: psycopg.Connection, load: Load) -> dict:
    raise StepNotReady("cleanse is not implemented yet (prodash/cleanse.py)")
