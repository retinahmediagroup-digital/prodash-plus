# ProDash+ — Handover (state as of 29 Sep 2026)

Read this first in any new working session. It records what exists, what was decided, and what comes next.
The approved scope document is `docs/ProDash_Plus_SSOT.docx` (SSOT v1.0; owners Tinashe and Alvon).

---

## 1. What ProDash+ is

A CRM and BI sales-push platform for **ProDairy (LIFE 250ml)**, built and operated by **RMG Digital (Retinah Media Group)**. Phase 1 has three parts:
- **WhatsApp trader bot:** registration, opt-in, one-tap reorder, tier and offers, human handover.
- **Branch Manager interface:** CSV drop, branch-level BI, Action Queue.
- **HQ dashboard.**

Timeline (the GTM deck governs flow, Phase 1 scope and dates):

| Milestone | Date |
|---|---|
| **Test Day** | 5 Oct 2026 |
| Iterate | 6–19 Oct |
| 16-shop rollout | 20 Oct – 4 Nov |
| Promo activation | Nov–Dec |

## 2. Decisions already taken (don't re-open without the owners)

| Topic | Decision |
|---|---|
| Source of truth | SSOT v1.0 (`docs/ProDash_Plus_SSOT.docx`). GTM deck wins on flow, Phase 1 and timelines; Spec wins on data contract, analytics, security; BRD on vision and governance. |
| Trader identity | System-issued **trader code** (e.g. `PD-HF-000001`, primary key) plus normalised cell `+2637XXXXXXXX` (unique contact attribute). Walk-ins are never a customer row. |
| Segments | Trader-facing tiers New / Regular / Champion; engine states At-Risk / Lapsed. Lapse = 14 days, or 1.5× the trader's own gap, whichever comes first. |
| Holdout | Persistent 20% hash holdout, measured intent-to-treat. Hidden from branch staff. |
| Architecture | Medallion on **Supabase Postgres**: bronze → silver → gold → scoring. `ops` = control plane. `crm` = operational writes. The web app reads only the `api` schema. |
| Hosting | **Vercel** = Next.js web app. **Supabase** = database, auth, storage, WhatsApp webhook. Python ETL = **GitHub Actions now**, **cPanel cron later** (same command). dbt later, for silver/gold. |
| Python | Python 3.11/3.12 (not 3.13+). All logic lives in the `prodash` package; notebooks only call it. |
| ETL runtime | Run-once worker driven by a scheduler (no daemon). `ops.load_log` is the queue (`FOR UPDATE SKIP LOCKED`). |
| Orchestration | Prefect considered; adopt at the pipeline stage if needed (the worker code wraps unchanged). |
| Git | Work on branch **`supabase/base-schemas`** (Claude sessions too), merge to **`main`** only when the user asks. Never commit customer data (`.gitignore` blocks `data/`, `*.csv`, `.env`). |

## 3. Environments

| Item | Value |
|---|---|
| GitHub repo | `retinahmediagroup-digital/prodash-plus` (private) |
| Supabase org | ProDash+ (Free plan). **Prod must move to Pro before real data** (backups). |
| Supabase dev | `ProDash+_dev`, ref `mxcadrfzjamyllfbvnrb`, eu-west-2 (London). All migrations 00–14 and the seed applied. |
| Supabase prod | `ProDash+_pro`, ref `zzgdrgsxkpuhvrpalsvn`. **Empty. Don't touch it until the user says so.** |
| Session pooler host | `aws-0-eu-west-2.pooler.supabase.com:5432`. User `etl_worker.<project_ref>` |
| Exposed API schema | `api` only (set in the dashboard by the user) |
| cPanel server | User `retinah`; Python app env at `/home/retinah/virtualenv/prodash-etl/3.11`. **Outbound port 5432 is blocked; the host has been asked to open 5432/6543.** |
| Branches | `main` = last merge. `supabase/base-schemas` = working branch, ahead of `main` by the 29 Sep fixes (secret key, schedule). `feat/web-init`, `claude/festive-turing-qkvniz` and `claude/practical-hamilton-w81wo5` are fully contained in these and can be deleted. |

Secrets live only in the password manager, GitHub Actions secrets and local `.env` files. Never in chat or Git.

## 4. What is built

**Database (`sql/`, see `sql/README.md`)**
- `00`–`01`: schemas, `ops.load_log`, normalisers, dimensions (client, brand, branch, product, customer, date).
- `02`: trader identity and `gold.issue_trader_code()`, FX, engine parameters, control totals.
- `03`: bronze (`receipts_raw`, `wa_events`), `ops.load_rejects`, silver (`receipt_items`, `receipts` view).
- `04`: `gold.fact_sales`, per-branch data freshness.
- `05`: CRM (sticky-opt-out consent, playbooks, holdout, queue exposures, contacts, notes, bot orders, field tasks).
- `06`: WhatsApp templates, conversations (24-hour window, handover), messages.
- `07`: scoring runs, trader scores (tier history), triggers.
- `08`: roles (`rmg_admin` / `hq` / `branch_manager`), the subscription kill switch, grants, RLS on every table.
- `09`: `api` views plus `api.upload_history()`.
- `10`: private `raw-uploads` bucket.
- `11`: foreign-key indexes.
- `12`: `app.grant_access()` / `app.revoke_access()`.
- `13`: `etl_worker` login (bypasses RLS, no DDL, no auth access).
- `14`: ETL queue (`ops.claim_next_load()`, `ops.etl_runs`).
- `seed/seed_prodairy.sql`: client `PRODAIRY` (prefix `PD`), brand LIFE, product `LIFE_250ML`, branch **HF Highfield only**, 20 engine parameters, holdout experiment, 8 draft playbooks (inactive), 5 English WhatsApp templates (draft).

**Python (`prodash/`)**

| Module | Status |
|---|---|
| `config`, `db` (`read_sql`, `transaction`, `copy_rows`), `storage`, `contract` (data contract + `HEADER_ALIASES`), `check` | Done |
| `landing.land_file()`: fingerprint → Storage → header check → bronze → `load_log` | Done, tested |
| `worker` (`--once`, `--nightly`): claim → cleanse → publish → score, retries, `etl_runs` | Done, tested |
| `cleanse.py`, `publish.py`, `scoring.py` | **Placeholders** (raise `StepNotReady`). Logic to be developed in notebooks, then moved here. |

**Automation**
- `.github/workflows/etl-worker.yml` runs every 30 min at :07 and :37, 07:07–20:37 Harare, plus 02:07 nightly. The minutes avoid :00, where GitHub delays or drops scheduled runs under load.
- Secrets set: `PRODASH_DB_URL`, `SUPABASE_URL`.
- Switch-off: set repo variable `ETL_RUNNER=cpanel`.
- **First run verified 29 Sep:** `ops.etl_runs` run 1, worker `github-actions`, `succeeded` (started by hand).
- **No scheduled run had fired by 12:30 UTC on 29 Sep.** The old `*/30` schedule was registered at 10:18 UTC and skipped four slots. Check the Actions tab after the new minutes reach `main`.

**Tests**
- `tests/sql/run_local.sh`: 17 SQL test groups × 2 scenarios (fresh install / dev upgrade).
- `tests/python`: 13 pytest tests (contract, landing, storage, worker).
- Both need a throwaway local Postgres. Never point them at Supabase.
- Last full run 29 Sep: all passed on Postgres 16 with Python 3.11 and 3.12 (pip now installs pandas 3.0 and SQLAlchemy 2.1).

**Docs:** `docs/ProDash_Plus_SSOT.docx`, `docs/ProDash_Plus_Medallion_Architecture.pptx`, `docs/ProDash_Plus_Backend_Architecture.pptx` (13-slide technical deck with speaker notes: tools, schemas, pipeline, engine rules, security, status), `docs/etl_worker.md` (runbook incl. cPanel switch-over), `notebooks/README.md`, `sql/README.md`.

**Web (`web/`):** Next.js 16 scaffold only. No Supabase wiring or screens yet.

## 5. Where we stopped

The user is setting up **Python on a Windows laptop** (VS Code), step by step:
- Python **3.12** is installed alongside **3.14**. 3.14 is the default, so always create the venv with `py -3.12`.
- Repo at `C:\Users\User\prodash-plus`, on `supabase/base-schemas`.
- **Steps 1–5 done on 29 Sep.** `python -m prodash.check` passes from the laptop, including Storage. The laptop `.env` uses the legacy service_role key; swap it for an `sb_secret_` key before the end of 2026.
- Step 3 first failed because the laptop's `.venv` dated from 28 Sep and was built with 3.14. Recreating it with 3.12 kept the 3.14 packages, and pip skipped them as already installed. Fix: delete `.venv` and redo steps 2–3.
- **Open:** the `etl_worker` password appeared in a chat screenshot on 29 Sep. Change it (SQL editor on dev), then update the GitHub secret `PRODASH_DB_URL` and the laptop `.env`.
- Next: step 6.

Remaining laptop steps:
1. Get the code on the working branch: `git checkout supabase/base-schemas && git pull` (or clone, then check out that branch).
2. Delete any older `.venv` (`Remove-Item -Recurse -Force .venv`), then `py -3.12 -m venv .venv` and `.venv\Scripts\activate`.
3. `pip install -e ".[notebook,dev]"`, `python -m ipykernel install --user --name prodash --display-name "ProDash+"`, `nbstripout --install`.
4. `.env` from `.env.example`: `PRODASH_DB_URL` = session pooler as `etl_worker`, plus `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` = the **secret key** (`sb_secret_…`, Settings → API Keys). Legacy service_role keys also work, but Supabase retires them at the end of 2026, as the Nov–Dec promo ends.
5. `python -m prodash.check` should end with **OK**. This also checks Storage access with the key, which has never been tested against Supabase. The first real upload happens in the first `land_file`.
6. Create `notebooks/01_profile.ipynb` with the ProDash+ kernel. **The user writes the notebooks; the assistant assists.**
7. **dbt setup** (`dbt/`, dbt-postgres, profile pointing to dev) was requested. It needs a decision on its own schema and role grants.

## 6. Next work, in order

1. Finish the laptop setup (above).
2. When the CSV arrives: `land_file("data/<file>.csv", branch_id="HF")`, then add real column names to `HEADER_ALIASES` if it's rejected, then profile it (Tasks T030–T036).
3. Build cleanse (bronze → silver) and publish (silver → gold, trader codes, reconciliation) in a notebook, then move them into `prodash/cleanse.py` / `publish.py`. The worker then runs them automatically.
4. Scoring: RFM (fixed F thresholds), shrunk rhythm, lapse, tiers, priority, holdout assignment, then `prodash/scoring.py`.
5. Web app: Supabase auth, Branch Manager CSV drop (signed upload URL, then `ops.load_log`), branch BI, Action Queue, HQ overview.
6. WhatsApp: Meta verification / test number, Edge Function webhook, bot flows.
7. When the host opens port 5432: cPanel cron (`docs/etl_worker.md`), then `ETL_RUNNER=cpanel`.
8. Prod: upgrade to Pro, apply `00`–`14` plus the seed as migrations, set up users with `app.grant_access()`.

## 7. Waiting on others

| Item | From |
|---|---|
| Six-month receipts CSV (or a 100-row sample with the real headers) | ProDairy |
| The other 15 branch codes and names | ProDairy |
| LIFE 250ml units per case | ProDairy |
| Independent monthly revenue totals per branch (for reconciliation) | ProDairy |
| Offers and budgets per playbook (Sponsor approval) | ProDairy Sponsor |
| Meta Business verification, WhatsApp number, template approval (EN + Shona) | ProDairy / RMG |
| Outbound TCP 5432/6543 on the cPanel server | Hosting provider |
| Names, emails and roles of dashboard users | RMG / ProDairy |

## 8. Known caveats

- Nobody can see data in the app until they have a profile (`app.grant_access`); there are no users yet.
- The GitHub schedule can start a few minutes late. Private-repo Actions minutes are sized for about 30 runs a day.
- The advisor still lists 11 "unindexed" foreign keys. These are covered by `(client_id, branch_id, …)` indexes; the advisor only counts exact column order.
- Security advisor, as intended: "RLS enabled, no policy" on the backend tables (deny-all for API roles), and a warning that `api.upload_history()` is a SECURITY DEFINER function signed-in users can call. `ops` is not reachable from the API, so the function checks access itself.
- `public.rls_auto_enable()` is Supabase's own event trigger; if the advisor warns about it, the warning is harmless.
- Supabase retires legacy `anon`/`service_role` keys at the end of 2026. `prodash` accepts the new secret key. The web app should use the publishable key (`sb_publishable_…`).
- The Claude cloud sandbox can't reach `*.supabase.co` directly (network policy). It works through the Supabase connector (SQL, migrations, advisors) instead.
- LibreOffice doesn't work in the assistant's sandbox, so generated `.docx`/`.pptx` files were validated but not visually rendered. Open them in Office to check the layout.

## 9. How to verify the current state quickly

```sql
-- migrations on dev (expect 00 … 14)
select version, name from supabase_migrations.schema_migrations order by version;
-- worker runs
select run_id, worker, mode, status, loads_claimed, message, started_at from ops.etl_runs order by run_id desc limit 10;
-- the queue
select load_id, branch_id, source_file, status, attempts, last_error from ops.load_log order by load_id desc limit 10;
```
