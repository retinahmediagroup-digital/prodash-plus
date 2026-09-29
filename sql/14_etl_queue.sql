/* ============================================================
   ProDash+ | 14_etl_queue.sql
   ops.load_log becomes the ETL work queue. A worker (GitHub
   Actions now, cPanel cron later: same code) claims the next
   landed file, cleanses bronze -> silver, publishes silver -> gold,
   scores, and records the outcome. Safe to re-run.

   Load lifecycle:
     started -> loaded -> processing -> published | held
                    ^          |
                    +----------+  retry later (attempts < max), or -> failed
   ============================================================ */

alter table ops.load_log add column if not exists attempts        integer not null default 0;
alter table ops.load_log add column if not exists claimed_by      text;
alter table ops.load_log add column if not exists claimed_at      timestamptz;
alter table ops.load_log add column if not exists next_attempt_at timestamptz;
alter table ops.load_log add column if not exists last_error      text;

do $$
begin
  alter table ops.load_log drop constraint if exists load_log_status_check;
  alter table ops.load_log add constraint load_log_status_check
    check (status in ('started','loaded','processing','held','published','failed','rejected'));

  alter table ops.load_log drop constraint if exists ck_load_log_gate;
  alter table ops.load_log add constraint ck_load_log_gate
    check (status not in ('loaded','processing','held','published')
           or (rows_loaded = rows_in_file and max_receipt_date is not null));

  if not exists (select 1 from pg_constraint where conname = 'ck_load_log_attempts') then
    alter table ops.load_log add constraint ck_load_log_attempts check (attempts >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_load_log_claim') then
    alter table ops.load_log add constraint ck_load_log_claim
      check ((status = 'processing') = (claimed_at is not null));
  end if;
end $$;

comment on column ops.load_log.attempts is 'ETL attempts so far; the worker stops retrying at its max (default 3) and marks the load failed.';
comment on column ops.load_log.next_attempt_at is 'Earliest time a failed attempt is retried (back-off).';

-- the worker's queue scan: waiting loads in arrival order
create index if not exists ix_load_log_queue
  on ops.load_log (started_at) where status in ('loaded','processing');

/* ---------- claim the next load ----------
   SKIP LOCKED: two workers (e.g. GitHub Actions and cPanel during the
   switch-over) never take the same file. A 'processing' load whose
   worker died (claimed longer ago than p_stale_minutes) is reclaimed. */
create or replace function ops.claim_next_load(
  p_worker        text,
  p_max_attempts  integer default 3,
  p_stale_minutes integer default 30
)
returns setof ops.load_log
language sql
volatile
set search_path = ''
as $$
  update ops.load_log l
     set status = 'processing', claimed_by = p_worker, claimed_at = now(),
         attempts = l.attempts + 1
   where l.load_id = (
           select q.load_id
           from ops.load_log q
           where (q.status = 'loaded'
                  and q.attempts < p_max_attempts
                  and (q.next_attempt_at is null or q.next_attempt_at <= now()))
              or (q.status = 'processing'
                  and q.claimed_at < now() - make_interval(mins => p_stale_minutes))
           order by q.started_at
           for update skip locked
           limit 1)
  returning l.*
$$;

revoke execute on function ops.claim_next_load(text, integer, integer) from public;

/* ---------- run log: one row per worker run (Data Health, monitoring) ---------- */
create table if not exists ops.etl_runs (
  run_id           bigint generated always as identity primary key,
  worker           text    not null,                 -- e.g. 'github-actions', 'cpanel-retinah'
  mode             text    not null check (mode in ('once','nightly')),
  status           text    not null default 'running'
                   check (status in ('running','succeeded','partial','failed','waiting')),
  loads_claimed    integer not null default 0,
  loads_published  integer not null default 0,
  loads_held       integer not null default 0,
  loads_retrying   integer not null default 0,
  loads_failed     integer not null default 0,
  message          text,
  started_at       timestamptz not null default now(),
  finished_at      timestamptz,
  constraint ck_etl_run_finished check (status = 'running' or finished_at is not null)
);
alter table ops.etl_runs enable row level security;
create index if not exists ix_etl_runs_started on ops.etl_runs (started_at desc);

comment on table ops.etl_runs is
  'Every worker run. status waiting = a pipeline step is not implemented yet, so loads stay queued.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'etl_worker') then
    execute 'grant execute on function ops.claim_next_load(text, integer, integer) to etl_worker';
    execute 'grant select, insert, update on ops.etl_runs to etl_worker';
    execute 'grant usage, select on all sequences in schema ops to etl_worker';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on ops.etl_runs to service_role';
    execute 'grant execute on function ops.claim_next_load(text, integer, integer) to service_role';
  end if;
end $$;
