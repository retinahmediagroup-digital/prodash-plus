/* ============================================================
   ProDash+ | 15_api_source.sql
   API feeds from the shops' system land in bronze beside CSV drops
   (SSOT §5.5, §12.5: POS feeds, Month 4+). An API batch is a load
   like a file: source = 'api', fingerprinted, queued and processed
   by the same worker (prodash.landing.land_batch, prodash.sync).
   Adds the sync checkpoint per feed, product-code mapping and each
   branch's expected source. Safe to re-run.
   ============================================================ */

/* ---------- 'api' wherever a file source is allowed; sync runs in etl_runs ---------- */
do $$
begin
  alter table ops.load_log drop constraint if exists load_log_source_check;
  alter table ops.load_log add constraint load_log_source_check
    check (source in ('csv','app','api'));

  alter table silver.receipt_items drop constraint if exists receipt_items_source_check;
  alter table silver.receipt_items add constraint receipt_items_source_check
    check (source in ('csv','app','api','counter','whatsapp','field'));

  alter table gold.fact_sales drop constraint if exists fact_sales_source_check;
  alter table gold.fact_sales add constraint fact_sales_source_check
    check (source in ('csv','app','api','counter','whatsapp','field'));

  alter table gold.fact_sales drop constraint if exists ck_fact_file_sources_have_load;
  alter table gold.fact_sales add constraint ck_fact_file_sources_have_load
    check (source not in ('csv','app','api') or load_id is not null);

  alter table ops.etl_runs drop constraint if exists etl_runs_mode_check;
  alter table ops.etl_runs add constraint etl_runs_mode_check
    check (mode in ('once','nightly','sync'));
end $$;

alter table ops.etl_runs add column if not exists loads_landed integer not null default 0;
comment on column ops.etl_runs.loads_landed is 'Sync runs: API batches landed in bronze.';

/* ---------- API sales move a branch's "data current to" date (was csv/app only in 04) ---------- */
create or replace view gold.v_branch_data_freshness with (security_invoker = true) as
select b.client_id,
       b.branch_id,
       b.branch_name,
       max(f.date_key)                                         as snapshot_date,
       b.expected_upload_days,
       current_date - max(f.date_key)                          as days_since_data,
       coalesce(current_date - max(f.date_key) > b.expected_upload_days, true) as is_stale
from   gold.dim_branch b
left   join gold.fact_sales f
       on  f.client_id = b.client_id
       and f.branch_id = b.branch_id
       and f.source in ('csv','app','api')
group  by b.client_id, b.branch_id, b.branch_name, b.expected_upload_days;

/* ---------- where each branch's sales are expected from ---------- */
alter table gold.dim_branch add column if not exists ingest_source text not null default 'csv';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ck_branch_ingest_source') then
    alter table gold.dim_branch add constraint ck_branch_ingest_source
      check (ingest_source in ('csv','app','api'));
  end if;
end $$;
comment on column gold.dim_branch.ingest_source is
  'Where the branch''s sales are expected from. Stays csv while an API feed runs its shadow week; set to api after. CSV drop remains the fallback.';

/* ---------- the worker takes an API load only once its branch is on api ----------
   Supersedes 14. During a feed's shadow week its batches wait in bronze
   (status loaded), to be compared with the CSV drops, so nothing reaches
   gold twice. CSV and app loads are claimed as before. */
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
           where ((q.status = 'loaded'
                   and q.attempts < p_max_attempts
                   and (q.next_attempt_at is null or q.next_attempt_at <= now()))
                  or (q.status = 'processing'
                      and q.claimed_at < now() - make_interval(mins => p_stale_minutes)))
             and (q.source <> 'api'
                  or exists (select 1 from gold.dim_branch b
                             where b.client_id = q.client_id and b.branch_id = q.branch_id
                               and b.ingest_source = 'api'))
           order by q.started_at
           for update skip locked
           limit 1)
  returning l.*
$$;

/* ---------- feeds: one row per source system and branch ----------
   external_id is the shop's id in the source system. cursor_value is the
   last change marker landed (an ISO time or an opaque token); prodash.sync
   moves it in the same transaction as the batch it landed. */
create table if not exists ops.source_sync (
  client_id       text    not null,
  source_name     text    not null check (source_name ~ '^[a-z][a-z0-9_]*$'),   -- e.g. 'pos_api'
  branch_id       text    not null,
  external_id     text    not null check (external_id <> ''),
  is_active       boolean not null default false,
  cursor_value    text,
  last_synced_at  timestamptz,
  last_load_id    bigint  references ops.load_log(load_id),
  last_error      text,
  updated_at      timestamptz not null default now(),
  primary key (client_id, source_name, branch_id),
  constraint uq_source_sync_external unique (client_id, source_name, external_id),
  constraint fk_source_sync_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id)
);
alter table ops.source_sync enable row level security;
create index if not exists ix_source_sync_branch_client on ops.source_sync (branch_id, client_id);
create index if not exists ix_source_sync_last_load     on ops.source_sync (last_load_id);

comment on table ops.source_sync is
  'API feeds: which branches each source system feeds, the shop id there, and the sync cursor. Activate a feed with is_active = true.';

/* ---------- product codes from a source system -> product ----------
   Codes are exact (no normalising); names still map through
   gold.ref_product_mapping. Cleansing tries the code first. */
create table if not exists gold.ref_product_code (
  client_id      text not null,
  source_name    text not null check (source_name ~ '^[a-z][a-z0-9_]*$'),
  external_code  text not null check (external_code <> '' and external_code = btrim(external_code)),
  product_id     text not null,
  created_at     timestamptz not null default now(),
  primary key (client_id, source_name, external_code),
  constraint fk_product_code_product_client foreign key (product_id, client_id)
    references gold.dim_product (product_id, client_id)
);
alter table gold.ref_product_code enable row level security;
create index if not exists ix_product_code_product_client on gold.ref_product_code (product_id, client_id);

drop policy if exists p_select on gold.ref_product_code;
create policy p_select on gold.ref_product_code for select to authenticated
  using (array[client_id] <@ (select app.my_client_ids()));

/* ---------- grants ---------- */
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on gold.ref_product_code to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on ops.source_sync, gold.ref_product_code to service_role';
  end if;
  if exists (select 1 from pg_roles where rolname = 'etl_worker') then
    execute 'grant select, insert, update, delete on ops.source_sync, gold.ref_product_code to etl_worker';
    -- RMG switches a branch to its feed from a notebook, like other reference changes
    execute 'grant update (ingest_source) on gold.dim_branch to etl_worker';
  end if;
end $$;

/* ---------- Storage: API batches are kept as JSON beside the CSVs ---------- */
do $$
begin
  if to_regclass('storage.buckets') is not null then
    update storage.buckets
       set allowed_mime_types = array['text/csv','application/vnd.ms-excel','text/plain','application/json']
     where id = 'raw-uploads';
  end if;
end $$;
