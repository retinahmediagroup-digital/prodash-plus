/* ============================================================
   ProDash+ | 02_identity_reference.sql
   SSOT v1.0 §4 identity model, §5 data contract reference data,
   §12.7 engine parameters. Builds on 00 and 01. Safe to re-run.
   ============================================================ */

create schema if not exists scoring;  -- engine outputs: tiers, rhythm, priority, triggers
create schema if not exists app;      -- app users, roles, branch access
create schema if not exists api;      -- the only schema exposed to the web app

/* ---------- client: trader-code prefix, locale, currency ---------- */
alter table gold.dim_client add column if not exists code_prefix   text;
alter table gold.dim_client add column if not exists timezone      text not null default 'Africa/Harare';
alter table gold.dim_client add column if not exists base_currency text not null default 'USD';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ck_client_code_prefix') then
    alter table gold.dim_client add constraint ck_client_code_prefix
      check (code_prefix is null or code_prefix ~ '^[A-Z]{2,5}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_client_base_currency') then
    alter table gold.dim_client add constraint ck_client_base_currency
      check (base_currency in ('USD','ZIG'));
  end if;
end $$;

comment on column gold.dim_client.code_prefix is
  'Prefix of every trader code for this client, e.g. PD in PD-HF-000123 (SSOT §4).';

/* ---------- branch: upload cadence for the staleness flag ---------- */
alter table gold.dim_branch add column if not exists expected_upload_days integer not null default 7;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ck_branch_upload_days') then
    alter table gold.dim_branch add constraint ck_branch_upload_days
      check (expected_upload_days between 1 and 31);
  end if;
end $$;
comment on column gold.dim_branch.expected_upload_days is
  'Days between CSV drops before Data Health flags the branch as stale (SSOT §11.5).';

/* ---------- product: case conversion for the Deck's "cases" KPIs ---------- */
alter table gold.dim_product add column if not exists units_per_case integer;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ck_product_units_per_case') then
    alter table gold.dim_product add constraint ck_product_units_per_case
      check (units_per_case is null or units_per_case > 0);
  end if;
end $$;
comment on column gold.dim_product.units_per_case is
  'Units in one case. Null until ProDairy confirms (SSOT §18 Q12); cases KPIs stay blank while null.';

/* ---------- customer = trader: identity columns (SSOT §4) ---------- */
alter table gold.dim_customer add column if not exists trader_code         text;
alter table gold.dim_customer add column if not exists business_name       text;
alter table gold.dim_customer add column if not exists outlet_type         text;
alter table gold.dim_customer add column if not exists catchment           text;
alter table gold.dim_customer add column if not exists registration_source text not null default 'csv_backfill';
alter table gold.dim_customer add column if not exists registered_at       timestamptz;
alter table gold.dim_customer add column if not exists capture_level       text not null default 'L0';
alter table gold.dim_customer add column if not exists preferred_language  text not null default 'en';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ck_customer_trader_code_format') then
    alter table gold.dim_customer add constraint ck_customer_trader_code_format
      check (trader_code is null or trader_code ~ '^[A-Z]{2,5}-[A-Z][A-Z0-9_]*-[0-9]{6}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_customer_outlet_type') then
    alter table gold.dim_customer add constraint ck_customer_outlet_type
      check (outlet_type is null or outlet_type in
             ('tuckshop','musika','vendor','small_shop','wholesaler','household','other'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_customer_registration_source') then
    alter table gold.dim_customer add constraint ck_customer_registration_source
      check (registration_source in ('csv_backfill','whatsapp','counter','qr','field','app'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_customer_capture_level') then
    alter table gold.dim_customer add constraint ck_customer_capture_level
      check (capture_level in ('L0','L1','L2','L3'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_customer_language') then
    alter table gold.dim_customer add constraint ck_customer_language
      check (preferred_language in ('en','sn','nd'));
  end if;
end $$;

create unique index if not exists ux_customer_client_trader_code
  on gold.dim_customer (client_id, trader_code) where trader_code is not null;

comment on column gold.dim_customer.trader_code is
  'Primary business identity (SSOT §4): system-issued, printed on the QR card, never reused. Issue with gold.issue_trader_code().';
comment on column gold.dim_customer.cell_normalised is
  'Unique contact attribute per client. Matches CSV history, stops duplicate registrations, and is the WhatsApp/SMS address.';

/* ---------- retire walk-in placeholders (SSOT §4, Appendix A) ----------
   Walk-in sales stay in the fact table with a null customer_id; they are
   never a customer row. Runs once: skipped after walk_in_flag is gone. */
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'gold' and table_name = 'dim_customer'
                and column_name = 'walk_in_flag') then
    drop view if exists gold._customer_scorable;
    drop view if exists gold._customer_active;
    delete from gold.dim_customer where walk_in_flag;
    drop index if exists gold.ux_customer_walkin_per_branch;
    alter table gold.dim_customer drop constraint if exists ck_customer_walkin_has_branch;
    alter table gold.dim_customer drop constraint if exists ck_customer_walkin_no_cell;
    alter table gold.dim_customer drop column walk_in_flag;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_customer_identified') then
    alter table gold.dim_customer add constraint ck_customer_identified
      check (cell_normalised is not null or trader_code is not null);
  end if;
end $$;

/* ---------- customer views ---------- */
drop view if exists gold._customer_scorable;
drop view if exists gold._customer_active;

create view gold._customer_active with (security_invoker = true) as
select * from gold.dim_customer where merged_into_customer_id is null;

create view gold._customer_scorable with (security_invoker = true) as
select * from gold.dim_customer
where  merged_into_customer_id is null
  and  first_seen is not null;

comment on view gold._customer_active is
  'Traders not merged into another record.';
comment on view gold._customer_scorable is
  'Active traders with at least one purchase: the population the engine scores.';

/* ---------- trader code issuance ----------
   One counter per (client, branch). The UPDATE ... RETURNING takes a
   row lock, so concurrent registrations never get the same number. */
create table if not exists gold.trader_code_counter (
  client_id   text    not null,
  branch_id   text    not null,
  last_value  integer not null default 0 check (last_value between 0 and 999999),
  primary key (client_id, branch_id),
  constraint fk_trader_counter_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id)
);
alter table gold.trader_code_counter enable row level security;

create or replace function gold.issue_trader_code(p_client_id text, p_branch_id text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_prefix text;
  v_next   integer;
begin
  select code_prefix into v_prefix
  from gold.dim_client where client_id = p_client_id;
  if v_prefix is null then
    raise exception 'Client % has no code_prefix; set gold.dim_client.code_prefix first', p_client_id;
  end if;

  insert into gold.trader_code_counter as c (client_id, branch_id, last_value)
  values (p_client_id, p_branch_id, 1)
  on conflict (client_id, branch_id)
  do update set last_value = c.last_value + 1
  returning c.last_value into v_next;

  return v_prefix || '-' || p_branch_id || '-' || lpad(v_next::text, 6, '0');
end;
$$;

comment on function gold.issue_trader_code(text, text) is
  'Next trader code for a branch, e.g. PD-HF-000124. Backend and api RPCs only.';
revoke execute on function gold.issue_trader_code(text, text) from public;

/* ---------- FX rates: USD-equivalent reporting (SSOT §5.3) ---------- */
create table if not exists gold.ref_fx_rate (
  rate_date     date    not null,
  currency      text    not null check (currency in ('USD','ZIG')),
  usd_per_unit  numeric(18,8) not null check (usd_per_unit > 0),
  source        text    not null,                   -- e.g. 'RBZ interbank mid'
  created_at    timestamptz not null default now(),
  primary key (rate_date, currency)
);
alter table gold.ref_fx_rate enable row level security;
comment on table gold.ref_fx_rate is
  'Official daily rate. Mixed currencies are never summed raw: value KPIs are per currency plus a USD-equivalent from this table.';

/* ---------- engine parameters (SSOT §12.7) ----------
   Every threshold the engine uses, versioned. Changes need owner approval. */
create table if not exists gold.ref_engine_param (
  client_id    text    not null references gold.dim_client(client_id),
  param_key    text    not null,
  version      integer not null default 1 check (version > 0),
  value_num    numeric,
  value_text   text,
  description  text,
  valid_from   date    not null default current_date,
  approved_by  text,
  created_at   timestamptz not null default now(),
  primary key (client_id, param_key, version),
  constraint ck_engine_param_has_value check (value_num is not null or value_text is not null)
);
alter table gold.ref_engine_param enable row level security;

create or replace view gold.v_engine_param_current with (security_invoker = true) as
select distinct on (client_id, param_key)
       client_id, param_key, version, value_num, value_text, description, valid_from, approved_by
from   gold.ref_engine_param
where  valid_from <= current_date
order  by client_id, param_key, version desc;

/* ---------- independent control totals (SSOT §5.4) ----------
   Supplied by ProDairy finance / till reports. An upload whose silver
   totals disagree beyond tolerance is held, not published. */
create table if not exists gold.ref_branch_control_total (
  client_id     text    not null,
  branch_id     text    not null,
  month_start   date    not null check (month_start = date_trunc('month', month_start)::date),
  currency      text    not null check (currency in ('USD','ZIG')),
  revenue       numeric(14,2) not null,
  receipts      integer check (receipts >= 0),
  source        text    not null,                   -- 'finance report', 'till Z-reports'
  supplied_by   text,
  supplied_at   timestamptz not null default now(),
  primary key (client_id, branch_id, month_start, currency),
  constraint fk_control_total_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id)
);
alter table gold.ref_branch_control_total enable row level security;
