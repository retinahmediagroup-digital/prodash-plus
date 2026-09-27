/* ============================================================
   ProDash+ | 05_crm.sql
   Operational CRM written by the app, the WhatsApp bot and the
   engine: consent, playbooks, holdout experiment, queue exposures,
   staff contacts, notes, bot orders, field tasks.
   SSOT §7, §8.3, §9.2, §10.3, §11.7, §12.8. Safe to re-run.

   Codes used across the schema (display labels live in the app):
     state        new | regular | champion | at_risk | lapsed
     trigger_type welcome | usual_day | lapse | basket_drop |
                  event | segment_move | stock_signal
   ============================================================ */

/* ---------- consent: append-only events (SSOT §12.8) ----------
   No row for a trader = consent unknown. Opt-out is permanent: only
   the trader themselves (source whatsapp_bot) can opt back in. */
create table if not exists crm.consent (
  consent_id       bigint generated always as identity primary key,
  client_id        text    not null,
  customer_id      uuid    not null,
  channel          text    not null check (channel in ('whatsapp','sms')),
  status           text    not null check (status in ('opted_in','opted_out')),
  source           text    not null check (source in
                     ('whatsapp_bot','stop_keyword','counter','call','field','app')),
  wording_version  text,                        -- consent notice version shown
  branch_id        text,
  captured_by      uuid,                        -- staff user; null when the trader acted in the bot
  captured_at      timestamptz not null default now(),
  note             text,
  constraint fk_consent_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_consent_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint ck_consent_optin_wording check (status = 'opted_out' or wording_version is not null)
);
alter table crm.consent enable row level security;
create index if not exists ix_consent_customer on crm.consent (customer_id, channel, captured_at desc);

create or replace function crm.consent_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_last text;
begin
  if new.status = 'opted_in' then
    select status into v_last
    from crm.consent
    where customer_id = new.customer_id and channel = new.channel
    order by captured_at desc, consent_id desc
    limit 1;
    if v_last = 'opted_out' and new.source <> 'whatsapp_bot' then
      raise exception 'Trader % opted out of %; only the trader can opt back in via the bot.',
        new.customer_id, new.channel;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_consent_guard on crm.consent;
create trigger trg_consent_guard before insert on crm.consent
  for each row execute function crm.consent_guard();

create or replace view crm.v_consent_current with (security_invoker = true) as
select distinct on (customer_id, channel)
       client_id, customer_id, channel, status, source, captured_at
from   crm.consent
order  by customer_id, channel, captured_at desc, consent_id desc;

/* ---------- playbooks: approved action per state & trigger (SSOT §8.3) ---------- */
create table if not exists crm.playbooks (
  playbook_id    text    primary key,
  client_id      text    not null references gold.dim_client(client_id),
  state          text    not null check (state in ('new','regular','champion','at_risk','lapsed')),
  sub_segment    text    check (sub_segment is null or sub_segment in
                   ('champions','loyal','promising_new','needs_attention','at_risk','cant_lose','lapsed')),
  trigger_type   text    not null check (trigger_type in
                   ('welcome','usual_day','lapse','basket_drop','event','segment_move','stock_signal')),
  channel        text    not null check (channel in ('whatsapp','sms','call','visit','counter')),
  template_name  text,                          -- crm.wa_templates.template_name for bot sends
  offer_code     text,
  offer_text     text,
  cap_days       integer not null check (cap_days between 1 and 90),
  is_active      boolean not null default false,
  approved_by    text,
  approved_at    timestamptz,
  created_at     timestamptz not null default now(),
  constraint uq_playbook_client unique (playbook_id, client_id),
  constraint ck_playbook_id_format check (playbook_id ~ '^[A-Z][A-Z0-9_]*$'),
  constraint ck_playbook_active_approved check (not is_active or approved_at is not null)
);
alter table crm.playbooks enable row level security;
comment on table crm.playbooks is
  'Offers and budgets must be approved in writing by the ProDairy Sponsor before is_active (SSOT §8.3, Tasks T083).';

/* ---------- holdout experiment (SSOT §11.7) ----------
   Persistent assignment: hash(salt, customer_id) < holdout_share.
   Assigned once, never re-drawn during the experiment. */
create table if not exists crm.experiments (
  experiment_id   text    primary key,
  client_id       text    not null references gold.dim_client(client_id),
  name            text    not null,
  holdout_share   numeric(4,3) not null check (holdout_share > 0 and holdout_share < 1),
  salt            text    not null default encode(gen_random_bytes(16), 'hex'),
  eligible_states text[]  not null default array['at_risk','regular'],
  starts_on       date    not null,
  ends_on         date,
  status          text    not null default 'draft' check (status in ('draft','running','ended')),
  created_at      timestamptz not null default now(),
  constraint uq_experiment_client unique (experiment_id, client_id),
  constraint ck_experiment_id_format check (experiment_id ~ '^[A-Z][A-Z0-9_]*$'),
  constraint ck_experiment_dates check (ends_on is null or ends_on >= starts_on)
);
alter table crm.experiments enable row level security;

create or replace function crm.holdout_bucket(p_salt text, p_customer_id uuid)
returns numeric
language sql
immutable parallel safe
set search_path = ''
as $$
  -- first 32 bits of md5 as a uniform number in [0, 1)
  select ('x' || substr(md5(p_salt || p_customer_id::text), 1, 8))::bit(32)::bigint / 4294967296.0
$$;

create table if not exists crm.experiment_assignments (
  experiment_id  text not null,
  client_id      text not null,
  customer_id    uuid not null,
  arm            text not null check (arm in ('treatment','holdout')),
  bucket         numeric not null check (bucket >= 0 and bucket < 1),
  assigned_at    timestamptz not null default now(),
  primary key (experiment_id, customer_id),
  constraint fk_assign_experiment_client foreign key (experiment_id, client_id)
    references crm.experiments (experiment_id, client_id),
  constraint fk_assign_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id)
);
alter table crm.experiment_assignments enable row level security;

create or replace function crm.assignment_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'Experiment assignments are permanent and cannot be changed or deleted.';
end;
$$;
drop trigger if exists trg_assignment_immutable on crm.experiment_assignments;
create trigger trg_assignment_immutable before update or delete on crm.experiment_assignments
  for each row execute function crm.assignment_immutable();

/* ---------- queue exposures: what was queued or sent, to whom, when ----------
   Written by the engine for every eligible trader, INCLUDING holdout
   traders (suppressed_reason = 'holdout'), so results are intent-to-treat. */
create table if not exists crm.queue_exposures (
  exposure_id        bigint generated always as identity primary key,
  client_id          text    not null,
  branch_id          text    not null,
  customer_id        uuid    not null,
  queue_date         date    not null,
  trigger_type       text    not null check (trigger_type in
                       ('welcome','usual_day','lapse','basket_drop','event','segment_move','stock_signal')),
  state              text    not null check (state in ('new','regular','champion','at_risk','lapsed')),
  sub_segment        text,
  rank_in_branch     integer check (rank_in_branch > 0),
  priority           numeric(10,4),
  playbook_id        text,
  channel            text    check (channel in ('whatsapp','sms','call','visit','counter')),
  experiment_id      text,
  arm                text    check (arm in ('treatment','holdout')),
  run_id             bigint,                    -- scoring.runs (FK added in 07)
  suppressed_reason  text    check (suppressed_reason is null or suppressed_reason in
                       ('holdout','no_consent','contact_cap','no_route','opted_out','manual')),
  created_at         timestamptz not null default now(),
  constraint uq_exposure unique (client_id, customer_id, queue_date, trigger_type),
  constraint fk_exposure_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_exposure_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint fk_exposure_playbook_client foreign key (playbook_id, client_id)
    references crm.playbooks (playbook_id, client_id),
  constraint fk_exposure_assignment foreign key (experiment_id, customer_id)
    references crm.experiment_assignments (experiment_id, customer_id),
  constraint ck_exposure_holdout check (
    (arm is not distinct from 'holdout') = (suppressed_reason is not distinct from 'holdout'))
);
alter table crm.queue_exposures enable row level security;
create index if not exists ix_exposure_branch_day on crm.queue_exposures (client_id, branch_id, queue_date, rank_in_branch);
create index if not exists ix_exposure_customer   on crm.queue_exposures (customer_id, queue_date desc);

/* ---------- staff contacts from the Action Queue (SSOT §10.3) ---------- */
create table if not exists crm.contacts (
  contact_id    bigint generated always as identity primary key,
  client_id     text    not null,
  branch_id     text    not null,
  customer_id   uuid    not null,
  exposure_id   bigint  references crm.queue_exposures(exposure_id),
  user_id       uuid    not null,
  channel       text    not null check (channel in ('call','whatsapp_manual','sms_manual','visit','counter')),
  outcome       text    not null check (outcome in
                  ('reached','no_answer','will_order','not_interested','wrong_number','opted_out')),
  note          text,
  contacted_at  timestamptz not null default now(),
  constraint fk_contact_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_contact_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id)
);
alter table crm.contacts enable row level security;
create index if not exists ix_contacts_customer on crm.contacts (customer_id, contacted_at desc);
create index if not exists ix_contacts_branch   on crm.contacts (client_id, branch_id, contacted_at desc);

-- an "opted out" call outcome is recorded as consent on every channel
create or replace function crm.contact_optout_to_consent()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.outcome = 'opted_out' then
    insert into crm.consent (client_id, customer_id, channel, status, source, branch_id, captured_by, note)
    select new.client_id, new.customer_id, ch, 'opted_out', 'call', new.branch_id, new.user_id,
           'From contact ' || new.contact_id
    from unnest(array['whatsapp','sms']) ch;
  end if;
  return null;
end;
$$;
drop trigger if exists trg_contact_optout on crm.contacts;
create trigger trg_contact_optout after insert on crm.contacts
  for each row execute function crm.contact_optout_to_consent();

/* ---------- notes ---------- */
create table if not exists crm.notes (
  note_id      bigint generated always as identity primary key,
  client_id    text not null,
  branch_id    text,
  customer_id  uuid not null,
  user_id      uuid not null,
  body         text not null check (length(btrim(body)) > 0),
  created_at   timestamptz not null default now(),
  constraint fk_note_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_note_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id)
);
alter table crm.notes enable row level security;
create index if not exists ix_notes_customer on crm.notes (customer_id, created_at desc);

/* ---------- orders: WhatsApp bot / counter / field (SSOT §9.2 C) ----------
   requested -> confirmed -> fulfilled, or cancelled from either.
   Revenue is only counted once the order is fulfilled and its invoice
   lines reach gold.fact_sales with order_id set. */
create table if not exists crm.orders (
  order_id          uuid primary key default gen_random_uuid(),
  client_id         text    not null,
  branch_id         text    not null,
  customer_id       uuid    not null,
  source            text    not null check (source in ('whatsapp','counter','field')),
  status            text    not null default 'requested'
                    check (status in ('requested','confirmed','fulfilled','cancelled')),
  fulfilment_type   text    check (fulfilment_type in ('collection','delivery')),
  requested_for     date,
  is_usual_reorder  boolean not null default false,
  currency          text    check (currency in ('USD','ZIG')),
  estimated_total   numeric(14,2),
  exposure_id       bigint  references crm.queue_exposures(exposure_id),  -- the prompt that led to it
  receipt_no        text,                       -- invoice issued on fulfilment
  requested_at      timestamptz not null default now(),
  confirmed_at      timestamptz,
  confirmed_by      uuid,
  fulfilled_at      timestamptz,
  cancelled_at      timestamptz,
  cancelled_by      uuid,
  cancel_reason     text,
  updated_at        timestamptz not null default now(),
  constraint uq_order_client unique (order_id, client_id),
  constraint fk_order_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_order_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint ck_order_confirmed check (status not in ('confirmed','fulfilled') or confirmed_at is not null),
  constraint ck_order_fulfilled check ((status = 'fulfilled') = (fulfilled_at is not null)),
  constraint ck_order_cancelled check ((status = 'cancelled') = (cancelled_at is not null))
);
alter table crm.orders enable row level security;
create index if not exists ix_orders_branch_status on crm.orders (client_id, branch_id, status, requested_for);
create index if not exists ix_orders_customer      on crm.orders (customer_id, requested_at desc);

create or replace function crm.order_transition_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status is distinct from old.status and not (
       (old.status = 'requested' and new.status in ('confirmed','cancelled'))
    or (old.status = 'confirmed' and new.status in ('fulfilled','cancelled'))) then
    raise exception 'Order % cannot move from % to %', old.order_id, old.status, new.status;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_order_transition on crm.orders;
create trigger trg_order_transition before update of status on crm.orders
  for each row execute function crm.order_transition_guard();

drop trigger if exists trg_order_updated_at on crm.orders;
create trigger trg_order_updated_at before update on crm.orders
  for each row execute function gold.set_updated_at();

create table if not exists crm.order_items (
  order_id    uuid    not null,
  client_id   text    not null,
  line_no     integer not null check (line_no > 0),
  product_id  text    not null,
  quantity    numeric(12,3) not null check (quantity > 0),
  unit        text    not null default 'case' check (unit in ('unit','case')),
  unit_price  numeric(12,4),
  primary key (order_id, line_no),
  constraint fk_order_item_order foreign key (order_id, client_id)
    references crm.orders (order_id, client_id) on delete cascade,
  constraint fk_order_item_product_client foreign key (product_id, client_id)
    references gold.dim_product (product_id, client_id)
);
alter table crm.order_items enable row level security;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fk_fact_order') then
    alter table gold.fact_sales add constraint fk_fact_order
      foreign key (order_id) references crm.orders(order_id);
  end if;
end $$;

/* ---------- field tasks: in-person visits for high-value traders ---------- */
create table if not exists crm.field_tasks (
  task_id       bigint generated always as identity primary key,
  client_id     text    not null,
  branch_id     text    not null,
  customer_id   uuid    not null,
  exposure_id   bigint  references crm.queue_exposures(exposure_id),
  reason        text    not null,
  due_date      date    not null,
  status        text    not null default 'open' check (status in ('open','done','cancelled')),
  assigned_to   uuid,
  outcome       text    check (outcome in
                  ('reached','no_answer','will_order','not_interested','wrong_number','opted_out')),
  completed_at  timestamptz,
  created_at    timestamptz not null default now(),
  constraint fk_task_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_task_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint ck_task_done check ((status = 'done') = (completed_at is not null and outcome is not null))
);
alter table crm.field_tasks enable row level security;
create index if not exists ix_tasks_branch_open on crm.field_tasks (client_id, branch_id, due_date) where status = 'open';
