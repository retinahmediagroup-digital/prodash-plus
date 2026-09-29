"""silver -> gold: publish one cleansed file.

Contract for run():
  - issue trader codes and upsert gold.dim_customer for new traders
  - upsert gold.fact_sales for the load's receipts (latest load wins)
  - reconcile against gold.ref_branch_control_total
  - use only `conn` (the worker commits or rolls back the whole load)
  - return "published", or "held" when reconciliation fails
    (a held load is visible on Data Health and is not retried)

Develop the logic in notebooks/02_cleanse.ipynb, then move it here.
"""

import psycopg

from prodash.pipeline import Load, StepNotReady


def run(conn: psycopg.Connection, load: Load) -> str:
    raise StepNotReady("publish is not implemented yet (prodash/publish.py)")
