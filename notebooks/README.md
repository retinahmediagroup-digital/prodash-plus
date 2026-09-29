# Notebooks

Working notebooks for profiling, cleansing and scoring. Reusable code goes in
the `prodash` package, not in notebook cells, so the same functions later run
in the automated pipeline.

## One-time setup (VS Code terminal, repo root)

```bash
python3.12 -m venv .venv             # Windows: py -3.12 -m venv .venv  (3.11 or 3.12, not 3.13+)
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -e ".[notebook,dev]"
python -m ipykernel install --user --name prodash --display-name "ProDash+"
nbstripout --install                 # REQUIRED: strips outputs (personal data) on commit
cp .env.example .env                 # then fill in PRODASH_DB_URL and the secret key (sb_secret_...)
python -m prodash.check              # should end with OK
```

In VS Code, open a notebook and pick the **ProDash+** kernel (or `.venv`).

## First cell of every notebook

```python
%load_ext autoreload
%autoreload 2          # edits to prodash/*.py apply without restarting the kernel

import pandas as pd
from prodash.db import read_sql, transaction
from prodash.landing import land_file
```

## Receiving a CSV

1. Save the file under `data/` (git-ignored; never commit customer data).
2. Land it:
   ```python
   result = land_file("data/<file>.csv", branch_id="HF")
   result
   ```
   - `loaded`: the original is in Storage (`raw-uploads/PRODAIRY/HF/<date>/<sha>.csv`), the rows are in `bronze.receipts_raw`, and the load is in `ops.load_log`.
   - `rejected`: `result.message` says why, usually unrecognised column names. Add them to `HEADER_ALIASES` in `prodash/contract.py` and run `land_file` again. The retry reuses the same load.
   - `duplicate`: this exact file was already landed.
3. Look at what landed:
   ```python
   raw = read_sql("select * from bronze.receipts_raw where load_id = %(id)s", {"id": result.load_id})
   ```

## Suggested notebooks

| Notebook | Purpose |
|---|---|
| `01_profile.ipynb` | Row counts, date range, cell coverage, currencies, product names, totals (Tasks T030–T036) |
| `02_cleanse.ipynb` | bronze → `silver.receipt_items` → `gold.fact_sales` + `gold.dim_customer` |
| `03_scoring.ipynb` | RFM, rhythm, lapse, tiers, priority → `scoring.*` |

## Rules

- Connect as `etl_worker`, never `postgres`.
- Write to the database only inside `with transaction() as conn:`.
- Never edit data in the Supabase table editor: every change should be reproducible from a notebook.
- Before committing, check `git diff` shows no output cells.
