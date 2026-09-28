# ProDash+ database (Supabase Postgres)

Built from the ProDash+ SSOT v1.0. Every file is idempotent: safe to re-run, in order.

| File | What it creates | SSOT |
|---|---|---|
| `00_init_schemas.sql` | Schemas, `ops.load_log`, phone/product normalisers, snapshot view | §5, §13 |
| `01_dimensions.sql` | Client, brand, branch, product, product mapping, customer, date | §4, §5 |
| `02_identity_reference.sql` | Trader code + identity columns, walk-in retirement, trader-code issuer, FX rates, engine parameters, control totals | §4, §5.3–5.4, §12.7 |
| `03_bronze_silver.sql` | Upload lifecycle statuses, `bronze.receipts_raw`, `bronze.wa_events`, `ops.load_rejects`, `silver.receipt_items`, `silver.receipts` | §5, §10.1 |
| `04_facts.sql` | `gold.fact_sales`, per-branch data freshness | §3.1, §11.5 |
| `05_crm.sql` | Consent (append-only, sticky opt-out), playbooks, holdout experiment, queue exposures, contacts, notes, orders, field tasks | §7, §8.3, §9.2, §10.3, §11.7, §12.8 |
| `06_whatsapp.sql` | WhatsApp templates, conversations (bot state, 24-hour window, handover), messages | §8.2, §9 |
| `07_scoring.sql` | Scoring runs, trader scores (tier history), triggers | §6, §7, §12.1 |
| `08_security.sql` | App users/roles/branches, access helpers, grants, RLS policies | §10.4, §13 |
| `09_api.sql` | `api` views and `api.upload_history()` — the web app's read surface | §10, §11 |
| `10_storage.sql` | Private `raw-uploads` bucket | §10.1 |
| `11_fk_indexes.sql` | An index behind every foreign key | — |
| `12_user_access.sql` | `app.grant_access()` / `app.revoke_access()` for giving people dashboard access | §10.4 |
| `13_etl_role.sql` | `etl_worker` login for notebooks and pipeline jobs (set its password yourself) | §13 |
| `seed/seed_prodairy.sql` | ProDairy reference data, engine parameters v1, holdout, draft playbooks and templates | — |

## Applying

Run in the Supabase SQL editor (or `psql`) in file order, then the seed:

- **ProDash+_dev** — 00–13 + seed applied. 00 and 01 were run by hand on 25 Sep and recorded in `supabase_migrations.schema_migrations` afterwards, so the history reads 00 → 13 with no gaps.
- **ProDash+_pro** is empty → apply `00` … `13` in order (each as a migration, so its history matches dev), then the seed.
- Re-running all files in order is safe, and so is re-running 00 or 01 on its own after later files (both tested). For any other file, re-run it followed by every later file.

### Giving people access

A signed-in user sees **nothing** until they have a profile. For each person: invite them under **Authentication → Users**, then in the SQL editor run `select app.grant_access(email, role, client_id, full_name, branch_ids)` — examples at the top of `12_user_access.sql`.

After applying, in the Supabase dashboard: **Settings → API → Exposed schemas = `api` only** (remove `public`/`graphql_public` if unused). `bronze`, `silver` and `ops` are never exposed.

Notes:

- `02` deletes walk-in placeholder customers and drops `walk_in_flag`. Walk-in sales are kept in `gold.fact_sales` with a null `customer_id` (SSOT §4).
- Branch users are created by an RMG admin (service role): `auth.users` → `app.user_profiles` → `app.user_branches`.

## Roles

| Role | Sees |
|---|---|
| `rmg_admin` | Every client and branch (including suspended clients) |
| `hq` | Every branch of their client; holdout assignments |
| `branch_manager` | Only their branches' traders, sales, queue, orders, handovers, uploads; never holdout membership |

A client whose `status` is not `active` disappears for `hq` and `branch_manager` (subscription kill switch).

## Testing locally

`tests/sql/run_local.sh` builds a throwaway Postgres database twice (fresh install + re-run, and a replay of dev's current state + upgrade) and runs the assertions in `tests/sql/test_base_schema.sql`. Never point it at Supabase.

```bash
PGHOST=/path/to/socket PGPORT=5432 tests/sql/run_local.sh
```
