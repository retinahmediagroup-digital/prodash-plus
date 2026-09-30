# ETL worker runbook

The worker turns landed files into published data:

```
ops.load_log (status loaded) ──► claim ──► cleanse (bronze → silver) ──► publish (silver → gold) ──► score
                                                                              │
                                             status: published | held | retry later | failed
```

It never runs continuously. A scheduler starts it, it processes whatever is waiting, and it exits:

| Command | What it does |
|---|---|
| `python -m prodash.worker --once` | Process every waiting load (up to 20), then exit |
| `python -m prodash.worker --nightly` | Re-score every branch, then exit |

- **Safe to overlap:** loads are claimed with `FOR UPDATE SKIP LOCKED`, so GitHub Actions and cPanel can even run at the same time during the switch-over.
- **Retries:** a failing load is retried after 10, then 20 minutes. After 3 attempts it is marked `failed`, with the error in `ops.load_log.error_message`.
- **Held loads:** a load that doesn't reconcile with ProDairy's control totals is marked `held` and is not retried.
- **Steps not built yet:** until `prodash/cleanse.py`, `publish.py` and `scoring.py` contain real logic, runs finish as `waiting` and loads stay queued, untouched.

## Where it runs

| Phase | Runner | Status |
|---|---|---|
| Interim | GitHub Actions: `.github/workflows/etl-worker.yml`, every 30 min (:07 and :37) 07:07–20:37 Harare, nightly at 02:07 | Active once secrets are set and the workflow is on `main` |
| Target | cPanel cron on the agency server (user `retinah`) | Waiting for the host to open outbound TCP 5432/6543 |

## GitHub Actions setup (interim)

Repository → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `PRODASH_DB_URL` | Session pooler URL as `etl_worker`: `postgresql://etl_worker.mxcadrfzjamyllfbvnrb:<password>@aws-0-eu-west-2.pooler.supabase.com:5432/postgres` |
| `SUPABASE_URL` | `https://mxcadrfzjamyllfbvnrb.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Secret key `sb_secret_…` from Settings → API Keys (only needed by steps that read Storage). Legacy service_role keys also work until Supabase retires them at the end of 2026. |

Until `PRODASH_DB_URL` is set, scheduled runs skip with a notice. To run it by hand: **Actions → ETL worker → Run workflow**.

## Switching to cPanel

1. The host opens outbound TCP **5432** and **6543** to `aws-0-eu-west-2.pooler.supabase.com`.
2. In **cPanel → Terminal**:
   ```bash
   source /home/retinah/virtualenv/prodash-etl/3.11/bin/activate
   cd ~ && git clone https://github.com/retinahmediagroup-digital/prodash-plus.git
   cd ~/prodash-plus && pip install -e .
   cp .env.example .env && nano .env      # PRODASH_DB_URL, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
   chmod 600 .env
   python -m prodash.check                # must end with OK
   python -m prodash.worker --once --worker cpanel
   ```
   The repository is private. Clone it with a read-only **deploy key** (repo → Settings → Deploy keys) or a fine-grained token that is limited to this repository and read-only.
3. In **cPanel → Cron Jobs**, add two jobs. First create the log folder with `mkdir -p ~/logs`.
   ```
   */5 * * * *  cd /home/retinah/prodash-plus && /home/retinah/virtualenv/prodash-etl/3.11/bin/python -m prodash.worker --once --worker cpanel >> /home/retinah/logs/prodash-etl.log 2>&1
   0 2 * * *    cd /home/retinah/prodash-plus && /home/retinah/virtualenv/prodash-etl/3.11/bin/python -m prodash.worker --nightly --worker cpanel >> /home/retinah/logs/prodash-etl.log 2>&1
   ```
   Cron uses the server's time zone. Check it with `date` and adjust `0 2` so the job runs at 02:00 Harare time.
4. Watch a few runs (query below). Then, in GitHub, set repository variable `ETL_RUNNER` = `cpanel`, so the Actions jobs skip from then on.
5. To update the code on the server later: `cd ~/prodash-plus && git pull && pip install -e .`

## API feeds (`prodash.sync`)

For shops whose system has an API. Needs `sql/15_api_source.sql` applied (drafted, not yet on dev).

1. Write the source in `prodash/sources/pos_api.py`: the field maps and `fetch()` (the file says how).
2. Register each shop, inactive, and map its product codes (from a notebook, as `etl_worker`):
   ```sql
   insert into ops.source_sync (client_id, source_name, branch_id, external_id)
   values ('PRODAIRY', 'pos_api', 'HF', '<the shop''s id in their system>');
   insert into gold.ref_product_code (client_id, source_name, external_code, product_id)
   values ('PRODAIRY', 'pos_api', '<their product code>', 'LIFE_250ML');
   ```
3. Try one shop by hand: `update ops.source_sync set is_active = true where ...`, then `python -m prodash.sync --once --source pos_api`. Check `ops.source_sync` (cursor, `last_error`) and `ops.load_log` (`source = 'api'`).
4. Run it from cron just before the worker, replacing the worker's `*/5` line above (GitHub Actions is too irregular for a live feed):
   ```
   */5 * * * *  cd /home/retinah/prodash-plus && ( PY=/home/retinah/virtualenv/prodash-etl/3.11/bin/python; $PY -m prodash.sync --once --worker cpanel; $PY -m prodash.worker --once --worker cpanel ) >> /home/retinah/logs/prodash-etl.log 2>&1
   ```
5. **Shadow week.** While `gold.dim_branch.ingest_source` is still `csv`, the branch's API batches land in bronze but the worker leaves them queued, so nothing reaches gold twice. Compare them with the CSV drops in bronze: same receipt numbers, same daily totals. Then switch: `update gold.dim_branch set ingest_source = 'api' where ...`. The worker then processes the queued batches too; silver keeps one copy of each receipt number. CSV drop stays as the fallback.

How it behaves:
- Each page of receipts is one load (`source = 'api'`), landed in the same transaction that moves the feed's cursor.
- Every run re-reads 10 minutes before the cursor. Batches already landed are skipped, and a re-sent receipt replaces its earlier copy in silver.
- A page that fails the contract check is `rejected` (visible in `ops.load_log`) and the feed stops with its cursor unchanged, so nothing is skipped. Fix the field map; the next run retries it.
- Sync runs appear in `ops.etl_runs` with `mode = 'sync'` and `loads_landed`. With no active feeds, a run writes nothing.

## Monitoring

```sql
-- last runs
select run_id, worker, mode, status, loads_claimed, loads_published, loads_held,
       loads_retrying, loads_failed, message, started_at, finished_at
from ops.etl_runs order by run_id desc limit 20;

-- the queue
select load_id, branch_id, source_file, status, attempts, next_attempt_at, last_error
from ops.load_log where status in ('loaded','processing','held','failed') order by started_at;
```

To retry a failed load after fixing the cause:
```sql
update ops.load_log
set status = 'loaded', attempts = 0, next_attempt_at = null, error_message = null
where load_id = <id>;
```
