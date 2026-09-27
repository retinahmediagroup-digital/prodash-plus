/* ============================================================
   ProDash+ | 01_dimensions.sql
   Client > brand > product hierarchy, branches, customers, dates.
   Every business table carries client_id, and every cross-table
   reference includes client_id so rows can never point across
   tenants. Matches ProDash+_dev as applied on 25 Sep 2026.
   Safe to re-run.
   ============================================================ */

/* ---------- client ---------- */
create table if not exists gold.dim_client (
  client_id    text primary key,                    -- 'PRODAIRY'
  client_name  text not null,
  status       text not null default 'active'
               check (status in ('active','suspended','ended')),
  created_at   timestamptz not null default now(),
  constraint ck_client_id_format check (client_id ~ '^[A-Z][A-Z0-9_]*$')
);
comment on table gold.dim_client is
  'One row per tenant. status drives the subscription kill switch in RLS.';

/* ---------- brand (a client may have several) ---------- */
create table if not exists gold.dim_brand (
  brand_id    text primary key,                     -- 'LIFE'
  client_id   text not null references gold.dim_client(client_id),
  brand_name  text not null,
  unique (client_id, brand_name),
  constraint uq_brand_client unique (brand_id, client_id),
  constraint ck_brand_id_format check (brand_id ~ '^[A-Z][A-Z0-9_]*$')
);

/* ---------- branch ---------- */
create table if not exists gold.dim_branch (
  branch_id    text primary key,                    -- 'HF'
  client_id    text not null references gold.dim_client(client_id),
  branch_name  text not null,
  region       text,
  tier         text,
  is_active    boolean not null default true,
  unique (client_id, branch_name),
  constraint uq_branch_client unique (branch_id, client_id),
  constraint ck_branch_id_format check (branch_id ~ '^[A-Z][A-Z0-9_]*$')
);

/* ---------- product: the controlled list, maintained by RMG ---------- */
create table if not exists gold.dim_product (
  product_id     text primary key,                  -- 'LIFE_250ML'
  client_id      text not null references gold.dim_client(client_id),
  brand_id       text not null,
  product_name   text not null,                     -- 'LIFE 250ml'
  category       text,
  pack_size_ml   integer,
  is_250_ml      boolean not null default false,    -- the pilot's focus pack
  is_active      boolean not null default true,
  unique (client_id, product_name),
  constraint uq_product_client unique (product_id, client_id),
  constraint fk_product_brand_client foreign key (brand_id, client_id)
    references gold.dim_brand (brand_id, client_id),
  constraint ck_product_id_format check (product_id ~ '^[A-Z][A-Z0-9_]*$'),
  constraint ck_product_pack_size_positive check (pack_size_ml is null or pack_size_ml > 0),
  constraint ck_product_250_flag check (not is_250_ml or pack_size_ml = 250)
);
create index if not exists ix_product_brand_client on gold.dim_product (brand_id, client_id);

/* ---------- raw name -> product mapping ---------- */
create table if not exists gold.ref_product_mapping (
  client_id         text not null references gold.dim_client(client_id),
  raw_product_name  text not null,
  product_id        text not null,
  created_at        timestamptz not null default now(),
  primary key (client_id, raw_product_name),
  constraint fk_mapping_product_client foreign key (product_id, client_id)
    references gold.dim_product (product_id, client_id),
  constraint ck_mapping_raw_normalised
    check (not (raw_product_name is distinct from ops.normalise_product_name(raw_product_name)))
);
comment on table gold.ref_product_mapping is
  'Raw CSV product name (stored via ops.normalise_product_name) -> product_id. The loader refuses unmapped names.';
create index if not exists ix_mapping_product_client on gold.ref_product_mapping (product_id, client_id);

/* ---------- customer ----------
   customer_id is a surrogate so a corrected number does not orphan
   history: the wrong record points at its survivor through
   merged_into_customer_id and is excluded from scoring. Customers are
   shared across branches within a client. Identity columns
   (trader_code etc.) are added in 02_identity_reference.sql. */
create table if not exists gold.dim_customer (
  customer_id             uuid primary key default gen_random_uuid(),
  client_id               text not null references gold.dim_client(client_id),
  cell_normalised         text,
  display_name            text,
  home_branch_id          text,
  first_seen              date,
  last_seen               date,
  shared_phone_flag       boolean not null default false,
  walk_in_flag            boolean not null default false,
  merged_into_customer_id uuid,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint uq_customer_client unique (customer_id, client_id),
  constraint fk_customer_branch_client foreign key (home_branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint fk_customer_merge_client foreign key (merged_into_customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint ck_customer_cell_e164
    check (cell_normalised is null or cell_normalised ~ '^\+2637[0-9]{8}$'),
  constraint ck_customer_not_self_merge
    check (merged_into_customer_id is distinct from customer_id),
  constraint ck_customer_seen_order
    check (first_seen is null or last_seen is null or first_seen <= last_seen),
  constraint ck_customer_walkin_has_branch
    check (not walk_in_flag or home_branch_id is not null),
  constraint ck_customer_walkin_no_cell
    check (not walk_in_flag or cell_normalised is null)
);

create unique index if not exists ux_customer_client_cell
  on gold.dim_customer (client_id, cell_normalised) where cell_normalised is not null;
-- walk_in_flag is retired in 02; only index it while the column exists
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'gold' and table_name = 'dim_customer'
                and column_name = 'walk_in_flag') then
    execute 'create unique index if not exists ux_customer_walkin_per_branch
               on gold.dim_customer (client_id, home_branch_id)
               where walk_in_flag and cell_normalised is null';
  end if;
end $$;
create index if not exists ix_customer_client_branch
  on gold.dim_customer (client_id, home_branch_id);
create index if not exists ix_customer_merged
  on gold.dim_customer (merged_into_customer_id) where merged_into_customer_id is not null;

/* ---- customer triggers: updated_at, merge guard, merge flattening ---- */
create or replace function gold.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function gold.customer_merge_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.merged_into_customer_id is not null and exists (
       select 1 from gold.dim_customer
        where customer_id = new.merged_into_customer_id
          and merged_into_customer_id is not null) then
    raise exception 'Cannot merge into %: it is already merged. Merge into its survivor instead.',
      new.merged_into_customer_id;
  end if;
  return new;
end;
$$;

create or replace function gold.customer_merge_flatten()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.merged_into_customer_id is not null then
    update gold.dim_customer
       set merged_into_customer_id = new.merged_into_customer_id
     where merged_into_customer_id = new.customer_id;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_dim_customer_updated_at on gold.dim_customer;
create trigger trg_dim_customer_updated_at
  before update on gold.dim_customer
  for each row execute function gold.set_updated_at();

drop trigger if exists trg_dim_customer_merge_guard on gold.dim_customer;
create trigger trg_dim_customer_merge_guard
  before insert or update of merged_into_customer_id on gold.dim_customer
  for each row execute function gold.customer_merge_guard();

drop trigger if exists trg_dim_customer_merge_flatten on gold.dim_customer;
create trigger trg_dim_customer_merge_flatten
  after update of merged_into_customer_id on gold.dim_customer
  for each row execute function gold.customer_merge_flatten();

/* ---- customer views (redefined in 02 once identity columns exist) ---- */
do $$
begin
  if not exists (select 1 from pg_views where schemaname = 'gold' and viewname = '_customer_active') then
    execute 'create view gold._customer_active with (security_invoker = true) as
             select * from gold.dim_customer where merged_into_customer_id is null';
  end if;
end $$;

/* ---------- date ---------- */
create table if not exists gold.dim_date (
  date_key      date primary key,
  iso_year      integer not null,
  iso_week      integer not null,
  month         integer not null,
  month_name    text    not null,
  day_of_week   integer not null,                   -- 1 = Monday
  day_name      text    not null,
  is_weekend    boolean not null,
  is_month_end  boolean not null
);

insert into gold.dim_date (date_key, iso_year, iso_week, month, month_name,
                           day_of_week, day_name, is_weekend, is_month_end)
select d::date,
       extract(isoyear from d)::int,
       extract(week    from d)::int,
       extract(month   from d)::int,
       to_char(d, 'FMMonth'),
       extract(isodow  from d)::int,
       to_char(d, 'FMDay'),
       extract(isodow  from d)::int >= 6,
       d::date = (date_trunc('month', d) + interval '1 month - 1 day')::date
from   generate_series(date '2025-01-01', date '2028-12-31', interval '1 day') d
on conflict (date_key) do nothing;

/* ---------- tie the load log to a real client and branch ---------- */
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fk_load_log_client') then
    alter table ops.load_log
      add constraint fk_load_log_client
      foreign key (client_id) references gold.dim_client(client_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fk_load_log_branch_client') then
    alter table ops.load_log
      add constraint fk_load_log_branch_client
      foreign key (branch_id, client_id) references gold.dim_branch(branch_id, client_id);
  end if;
end $$;

/* ---------- RLS on (policies in 08_security.sql) ---------- */
alter table gold.dim_client          enable row level security;
alter table gold.dim_brand           enable row level security;
alter table gold.dim_branch          enable row level security;
alter table gold.dim_product         enable row level security;
alter table gold.ref_product_mapping enable row level security;
alter table gold.dim_customer        enable row level security;
alter table gold.dim_date            enable row level security;
