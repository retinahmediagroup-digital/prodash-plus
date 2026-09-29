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
| Interim | GitHub Actions: `.github/workflows/etl-worker.yml`, every 30 min 07:00–21:00 Harare, nightly at 02:00 | Active once secrets are set and the workflow is on `main` |
| Target | cPanel cron on the agency server (user `retinah`) | Waiting for the host to open outbound TCP 5432/6543 |

## GitHub Actions setup (interim)

Repository → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `PRODASH_DB_URL` | Session pooler URL as `etl_worker`: `postgresql://etl_worker.mxcadrfzjamyllfbvnrb:<password>@aws-0-eu-west-2.pooler.supabase.com:5432/postgres` |
| `SUPABASE_URL` | `https://mxcadrfzjamyllfbvnrb.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role / secret key (only needed by steps that read Storage) |

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
