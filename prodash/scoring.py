"""gold -> scoring: RFM, rhythm, lapse, tiers, priority and triggers.

Contract for run():
  - create a scoring.runs row, write scoring.trader_scores / scoring.triggers,
    mark the run succeeded
  - branch_id None = score every branch of the client
  - use only `conn`; return a dict of counts

Develop the logic in notebooks/03_scoring.ipynb, then move it here.
"""

import psycopg

from prodash.pipeline import StepNotReady


def run(conn: psycopg.Connection, client_id: str, branch_id: str | None = None,
        run_type: str = "upload") -> dict:
    raise StepNotReady("scoring is not implemented yet (prodash/scoring.py)")
