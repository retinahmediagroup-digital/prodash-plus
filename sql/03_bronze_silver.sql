/* ============================================================
   ProDash+ | 03_bronze_silver.sql
   Branch Manager CSV drop lifecycle (SSOT §10.1), raw landing
   (bronze), row rejects, and the cleaned line-item layer (silver).
   Safe to re-run.
   ============================================================ */

/* ---------- load log: upload lifecycle ----------
   started   -> file row created, loader running
   loaded    -> all file rows landed in bronze (gate: rows_loaded = rows_in_file)
   held      -> loaded but reconciliation to control totals failed; not published
   published -> silver/gold updated, tests passed, visible in dashboards
   failed    -> loader error (see error_message)
   rejected  -> contract check failed before landing (bad headers, wrong branch)   */
alter table ops.load_log add column if not exists uploaded_by           uuid;
alter table ops.load_log add column if not exists file_shape            text;
alter table ops.load_log add column if not exists rows_rejected         integer;
alter table ops.load_log add column if not exists rows_published        integer;
alter table ops.load_log add column if not exists reconciliation_status text not null default 'pending';
alter table ops.load_log add column if not exists published_at          timestamptz;

do $$
begin
  alter table ops.load_log drop constraint if exists load_log_status_check;
  alter table ops.load_log add constraint load_log_status_check
    check (status in ('started','loaded','held','published','failed','rejected'));

  alter table ops.load_log drop constraint if exists ck_load_log_gate;
  alter table ops.load_log add constraint ck_load_log_gate
    check (status not in ('loaded','held','published')
           or (rows_loaded = rows_in_file and max_receipt_date is not null));

  alter table ops.load_log drop constraint if exists ck_load_log_published;
  alter table ops.load_log add constraint ck_load_log_published
    check ((status = 'published') = (published_at is not null));

  if not exists (select 1 from pg_constraint where conname = 'ck_load_log_file_shape') then
    alter table ops.load_log add constraint ck_load_log_file_shape
      check (file_shape is null or file_shape in ('line_item','packed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_load_log_reconciliation') then
    alter table ops.load_log add constraint ck_load_log_reconciliation
      check (reconciliation_status in ('pending','passed','failed','waived'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ck_load_log_row_counts') then
    alter table ops.load_log add constraint ck_load_log_row_counts
      check (coalesce(rows_rejected, 0) >= 0 and coalesce(rows_published, 0) >= 0);
  end if;
end $$;

comment on column ops.load_log.branch_id is
  'Set when a Branch Manager drops a file for their branch; null only for an RMG/HQ file spanning all branches.';
comment on column ops.load_log.uploaded_by is
  'auth.users.id of the uploader (Branch Manager, HQ or RMG admin).';

-- snapshot counts every load whose rows are in the warehouse
drop index if exists ops.ix_load_log_client_loaded;
create index if not exists ix_load_log_client_landed
  on ops.load_log (client_id, max_receipt_date desc) where status in ('loaded','published');
drop index if exists ops.ix_load_log_client_open;
create index if not exists ix_load_log_client_open
  on ops.load_log (client_id, status) where status not in ('loaded','published');

create or replace view ops.current_snapshot as
select client_id,
       max(max_receipt_date) as snapshot_date,
       max(finished_at)      as last_loaded_at
from   ops.load_log
where  status in ('loaded','published')
group  by client_id;
-- gold.snapshot_date() gets its final definition in 08_security.sql

/* ---------- bronze: raw CSV rows ----------
   Every contract field as text, exactly as received. Never edited:
   any upload can be replayed from here. Unknown columns go to extra. */
create table if not exists bronze.receipts_raw (
  load_id           bigint  not null references ops.load_log(load_id),
  row_num           integer not null check (row_num > 0),   -- data row in file, 1-based
  client_id         text    not null,
  receipt_no        text,
  receipt_datetime  text,
  branch            text,
  trader_code       text,
  customer_name     text,
  customer_cell     text,
  product           text,
  quantity          text,
  unit              text,
  unit_price        text,
  line_total        text,
  currency          text,
  payment_method    text,
  customer_type     text,
  fulfilment_type   text,
  items_packed      text,        -- accepted shape: "2x LIFE 250ml; 1x Yoghurt 500ml"
  extra             jsonb,
  landed_at         timestamptz not null default now(),
  primary key (load_id, row_num)
);
alter table bronze.receipts_raw enable row level security;
create index if not exists ix_receipts_raw_client on bronze.receipts_raw (client_id, load_id);

/* ---------- bronze: WhatsApp webhook events ----------
   Raw Meta payloads, stored before processing. event_hash makes
   webhook retries idempotent. */
create table if not exists bronze.wa_events (
  event_id         bigint generated always as identity primary key,
  client_id        text    not null,
  event_hash       text    not null check (event_hash ~ '^[0-9a-f]{64}$'),
  signature_valid  boolean not null,
  payload          jsonb   not null,
  received_at      timestamptz not null default now(),
  processed_at     timestamptz,
  process_error    text,
  constraint uq_wa_events_hash unique (client_id, event_hash)
);
alter table bronze.wa_events enable row level security;
create index if not exists ix_wa_events_unprocessed
  on bronze.wa_events (received_at) where processed_at is null;

/* ---------- ops: row-level rejects (downloadable reject file) ---------- */
create table if not exists ops.load_rejects (
  load_id      bigint  not null references ops.load_log(load_id),
  row_num      integer not null,
  reason_code  text    not null check (reason_code in (
                 'missing_required','bad_date','bad_number','invalid_cell',
                 'unmapped_product','unknown_branch','wrong_branch',
                 'currency_missing','line_total_mismatch','duplicate_line',
                 'parse_error','unknown_trader_code')),
  detail       text,
  is_blocking  boolean not null default true,      -- false = row kept with a warning
  created_at   timestamptz not null default now(),
  primary key (load_id, row_num, reason_code)
);
alter table ops.load_rejects enable row level security;

/* ---------- silver: cleaned line items ----------
   One row per receipt line. Key (client, branch, receipt_no, line_no):
   a receipt that reappears in a later file (overlapping exports)
   replaces its earlier lines -- latest load wins (SSOT §5.3). */
create table if not exists silver.receipt_items (
  client_id         text    not null,
  branch_id         text    not null,
  receipt_no        text    not null,
  line_no           integer not null check (line_no > 0),
  receipt_ts        timestamptz not null,
  receipt_date      date    not null,
  customer_id       uuid,                        -- null = walk-in / unidentified
  trader_code       text,
  cell_normalised   text,
  customer_name     text,
  product_raw       text    not null,
  product_id        text,                        -- null = unmapped (blocked from gold)
  quantity          numeric(12,3) not null,
  unit              text    not null default 'unit' check (unit in ('unit','case')),
  unit_price        numeric(12,4),
  line_total        numeric(14,2) not null,
  currency          text    check (currency in ('USD','ZIG')),
  payment_method    text,
  customer_type     text,
  fulfilment_type   text    check (fulfilment_type is null or fulfilment_type in ('collection','delivery')),
  source            text    not null default 'csv'
                    check (source in ('csv','app','counter','whatsapp','field')),
  capture_level     text    not null default 'L0' check (capture_level in ('L0','L1','L2','L3')),
  is_void           boolean not null default false,  -- refund / void / negative line
  dq_line_total_ok  boolean not null,               -- line_total = quantity * unit_price (± 0.01)
  load_id           bigint  references ops.load_log(load_id),
  row_num           integer,
  updated_at        timestamptz not null default now(),
  primary key (client_id, branch_id, receipt_no, line_no),
  constraint fk_items_branch_client   foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint fk_items_product_client  foreign key (product_id, client_id)
    references gold.dim_product (product_id, client_id),
  constraint fk_items_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint ck_items_cell check (cell_normalised is null or cell_normalised ~ '^\+2637[0-9]{8}$'),
  constraint ck_items_date check (receipt_date = (receipt_ts at time zone 'Africa/Harare')::date)
);
alter table silver.receipt_items enable row level security;
create index if not exists ix_items_customer on silver.receipt_items (customer_id, receipt_date);
create index if not exists ix_items_load     on silver.receipt_items (load_id);
create index if not exists ix_items_branch_date on silver.receipt_items (client_id, branch_id, receipt_date);

/* ---------- silver: receipt headers ---------- */
create or replace view silver.receipts as
select client_id,
       branch_id,
       receipt_no,
       min(receipt_ts)                                   as receipt_ts,
       min(receipt_date)                                 as receipt_date,
       (array_agg(customer_id) filter (where customer_id is not null))[1] as customer_id,
       count(*)                                          as line_count,
       count(distinct currency)                          as currency_count,
       min(currency)                                     as currency,
       sum(line_total)                                   as receipt_total,
       bool_and(dq_line_total_ok)
         and count(distinct currency) <= 1
         and count(distinct customer_id) <= 1            as dq_reconciled,
       bool_or(is_void)                                  as has_void,
       max(load_id)                                      as load_id
from   silver.receipt_items
group  by client_id, branch_id, receipt_no;

comment on view silver.receipts is
  'One row per receipt. dq_reconciled is false when a line total disagrees with quantity x price, or the receipt mixes currencies or customers.';
