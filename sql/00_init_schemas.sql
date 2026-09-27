/* ============================================================
   ProDash+ | 00_init_schemas.sql
   Schemas, extensions, pipeline load log, normalisers, snapshot.
   Matches ProDash+_dev as applied on 25 Sep 2026. Safe to re-run.
   ============================================================ */

create extension if not exists "pgcrypto";      -- gen_random_uuid(), digest()

create schema if not exists bronze;   -- raw rows, append-only, replayable
create schema if not exists silver;   -- cleaned, typed, de-duplicated
create schema if not exists gold;     -- star schema the app reads
create schema if not exists crm;      -- operational writes: consent, contacts, orders, messages
create schema if not exists ops;      -- load log, rejects, pipeline runs

/* ---- lock down raw and intermediate schemas ----
   Per role, so a missing role cannot abort the whole statement.
   Withholding USAGE is the actual protection: without it these
   schemas are unreachable from the API whatever tables appear in
   them later. (Also keep them out of Settings > API > Exposed schemas.) */
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke usage on schema bronze, silver, ops from %I', r);
    end if;
  end loop;
end $$;

/* ---- normalisers used by the loader, constraints and silver ---- */
create or replace function ops.normalise_cell(raw text)
returns text
language plpgsql
immutable parallel safe
set search_path = ''
as $$
declare
  d text := regexp_replace(coalesce(raw, ''), '\D', '', 'g');
begin
  d := case
         when d ~ '^002637[0-9]{8}$' then substr(d, 3)
         when d ~ '^2637[0-9]{8}$'   then d
         when d ~ '^07[0-9]{8}$'     then '263' || substr(d, 2)
         when d ~ '^7[0-9]{8}$'      then '263' || d
         else null
       end;
  return case when d is null then null else '+' || d end;
end;
$$;

comment on function ops.normalise_cell(text) is
  'Zimbabwe mobile -> +2637XXXXXXXX, else null. Use in the loader and silver->gold SQL.';

create or replace function ops.normalise_product_name(raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(lower(btrim(regexp_replace(raw, '\s+', ' ', 'g'))), '');
$$;

comment on function ops.normalise_product_name(text) is
  'Lowercase, trim, collapse spaces. Use before looking up ref_product_mapping.';

/* ---- pipeline load log ---- */
create table if not exists ops.load_log (
  load_id           bigint generated always as identity primary key,
  client_id         text        not null,
  source            text        not null default 'csv'
                    check (source in ('csv','app')),
  source_file       text        not null,
  file_sha256       text        not null
                    check (file_sha256 ~ '^[0-9a-f]{64}$'),
  storage_path      text,
  branch_id         text,       -- null when one file spans all branches
  rows_in_file      integer     check (rows_in_file >= 0),
  rows_loaded       integer     check (rows_loaded >= 0),
  min_receipt_date  date,
  max_receipt_date  date,
  status            text        not null default 'started'
                    check (status in ('started','loaded','failed')),
  error_message     text,
  started_at        timestamptz not null default now(),
  finished_at       timestamptz,
  constraint uq_load_log_file unique (client_id, file_sha256),
  constraint ck_load_log_dates
    check (min_receipt_date is null or max_receipt_date is null
           or min_receipt_date <= max_receipt_date),
  constraint ck_load_log_finished
    check (status = 'started' or finished_at is not null),
  constraint ck_load_log_gate
    check (status <> 'loaded'
           or (rows_loaded = rows_in_file and max_receipt_date is not null))
);

comment on table ops.load_log is
  'One row per uploaded file. file_sha256 is unique per client, so the same file cannot be loaded twice for one client while two clients may legitimately send identical files. max_receipt_date drives the snapshot rule: all recency uses the latest receipt date in the data, never the calendar date.';

alter table ops.load_log enable row level security;

create index if not exists ix_load_log_client
  on ops.load_log (client_id, started_at desc);
create index if not exists ix_load_log_client_open
  on ops.load_log (client_id, status) where status <> 'loaded';
create index if not exists ix_load_log_client_loaded
  on ops.load_log (client_id, max_receipt_date desc) where status = 'loaded';
create index if not exists ix_load_log_branch_client
  on ops.load_log (branch_id, client_id);

/* ---- snapshot: internal view for backend jobs ---- */
create or replace view ops.current_snapshot as
select client_id,
       max(max_receipt_date) as snapshot_date,
       max(finished_at)      as last_loaded_at
from   ops.load_log
where  status = 'loaded'
group  by client_id;

comment on view ops.current_snapshot is
  'As-at date per client for all scoring. Backend only: the ops schema is not reachable from the API. The app reads gold.current_snapshot (created in 08_security.sql).';

/* ---- snapshot accessor usable from gold/crm objects ----
   SECURITY DEFINER so security_invoker views can resolve the snapshot
   without the caller needing rights on ops. Returns null for a client
   the caller does not belong to. */
create or replace function gold.snapshot_date(p_client_id text)
returns date
language sql
stable
security definer
set search_path = ops, pg_temp
as $$
  select max(l.max_receipt_date)
  from ops.load_log l
  where l.client_id = p_client_id
    and l.status = 'loaded'
    and (
          coalesce(auth.jwt() ->> 'role', '') = 'service_role'
       or p_client_id = auth.jwt() -> 'app_metadata' ->> 'client_id'
    )
$$;

comment on function gold.snapshot_date(text) is
  'Latest loaded receipt date for one client. The single source of the as-at date used by every score and view. Returns null for a client the caller does not belong to.';

revoke execute on function gold.snapshot_date(text) from public;
do $$
declare r text;
begin
  foreach r in array array['authenticated','service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('grant execute on function gold.snapshot_date(text) to %I', r);
    end if;
  end loop;
end $$;
