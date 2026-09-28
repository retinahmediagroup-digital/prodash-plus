/* ============================================================
   ProDash+ | 04_facts.sql
   gold.fact_sales: the published sales every dashboard, score and
   result reads. Receipt-line grain. CSV drops, counter capture and
   fulfilled WhatsApp-bot orders all land here (SSOT §3.1, §9.2 C).
   Safe to re-run.
   ============================================================ */

create table if not exists gold.fact_sales (
  sales_line_id   bigint generated always as identity primary key,
  client_id       text    not null,
  branch_id       text    not null,
  receipt_no      text    not null,
  line_no         integer not null check (line_no > 0),
  date_key        date    not null references gold.dim_date(date_key),
  receipt_ts      timestamptz not null,
  customer_id     uuid,                     -- null = walk-in: counts in sales, never in customer analytics
  product_id      text    not null,
  quantity        numeric(12,3) not null,   -- in units (cases converted by the loader)
  cases           numeric(12,3),            -- quantity / units_per_case; null until the product has one
  unit_price      numeric(12,4),
  line_total      numeric(14,2) not null,   -- in currency
  currency        text    not null check (currency in ('USD','ZIG')),
  line_total_usd  numeric(14,2),            -- via gold.ref_fx_rate on date_key; null if no rate yet
  is_void         boolean not null default false,
  source          text    not null check (source in ('csv','app','counter','whatsapp','field')),
  capture_level   text    not null default 'L0' check (capture_level in ('L0','L1','L2','L3')),
  load_id         bigint  references ops.load_log(load_id),  -- null for live (non-file) sources
  order_id        uuid,                     -- set when the line fulfils a bot order (FK added in 05)
  published_at    timestamptz not null default now(),
  constraint uq_fact_sales_line unique (client_id, branch_id, receipt_no, line_no),
  constraint fk_fact_branch_client   foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint fk_fact_product_client  foreign key (product_id, client_id)
    references gold.dim_product (product_id, client_id),
  constraint fk_fact_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint ck_fact_file_sources_have_load
    check (source not in ('csv','app') or load_id is not null),
  constraint ck_fact_void_sign
    check (is_void or line_total >= 0)
);

alter table gold.fact_sales enable row level security;

create index if not exists ix_fact_client_branch_date on gold.fact_sales (client_id, branch_id, date_key);
create index if not exists ix_fact_customer_date      on gold.fact_sales (customer_id, date_key) where customer_id is not null;
create index if not exists ix_fact_product_date       on gold.fact_sales (product_id, date_key);
create index if not exists ix_fact_load               on gold.fact_sales (load_id) where load_id is not null;

comment on table gold.fact_sales is
  'Published sales, one row per receipt line. Only rows that passed silver checks and reconciliation. Revenue for bot orders is counted when fulfilled, never when requested.';
comment on column gold.fact_sales.customer_id is
  'Null for walk-ins with no cell and no trader code (SSOT §4): included in sales totals, excluded from segments, queues and the holdout.';

/* ---------- per-branch snapshot (SSOT §11.5) ----------
   Recency for a branch's traders is measured from that branch's latest
   file-loaded receipt, so a late upload never makes a whole branch look
   lapsed. Live sources (bot, counter, field) do not move it. */
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
       and f.source in ('csv','app')
group  by b.client_id, b.branch_id, b.branch_name, b.expected_upload_days;

comment on view gold.v_branch_data_freshness is
  'Per-branch "data current to" date and stale flag for Data Health and every screen stamp.';
