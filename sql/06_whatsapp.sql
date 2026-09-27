/* ============================================================
   ProDash+ | 06_whatsapp.sql
   WhatsApp trader bot (SSOT §8.2, §9): approved templates, one
   conversation per trader number (bot state + 24-hour service
   window + human handover), and every inbound/outbound message
   with its delivery status. SMS backup shares the message log.
   Raw webhook payloads land first in bronze.wa_events (03).
   Safe to re-run.
   ============================================================ */

/* ---------- message templates (Meta approval tracked here) ---------- */
create table if not exists crm.wa_templates (
  client_id         text    not null references gold.dim_client(client_id),
  template_name     text    not null check (template_name ~ '^[a-z][a-z0-9_]*$'),
  language          text    not null check (language in ('en','sn','nd')),
  category          text    not null check (category in ('utility','marketing','authentication')),
  purpose           text    not null check (purpose in
                      ('welcome','usual_day','lapse','basket_drop','event','segment_move',
                       'order_confirmed','order_fulfilled','order_cancelled','consent','other')),
  status            text    not null default 'draft'
                    check (status in ('draft','submitted','approved','rejected','paused','disabled')),
  body_preview      text    not null,
  button_labels     text[],
  meta_template_id  text,
  rejection_reason  text,
  submitted_at      timestamptz,
  approved_at       timestamptz,
  updated_at        timestamptz not null default now(),
  primary key (client_id, template_name, language),
  constraint ck_template_approved check (status <> 'approved' or approved_at is not null)
);
alter table crm.wa_templates enable row level security;

drop trigger if exists trg_wa_templates_updated_at on crm.wa_templates;
create trigger trg_wa_templates_updated_at before update on crm.wa_templates
  for each row execute function gold.set_updated_at();

comment on table crm.wa_templates is
  'Business-initiated messages may only use approved templates (SSOT §8.2). Data Health shows status per template.';

/* ---------- conversations: one per trader WhatsApp number ---------- */
create table if not exists crm.conversations (
  conversation_id       uuid    primary key default gen_random_uuid(),
  client_id             text    not null references gold.dim_client(client_id),
  wa_id                 text    not null check (wa_id ~ '^\+[1-9][0-9]{7,14}$'),  -- sender number, E.164
  customer_id           uuid,                  -- null until registration links or creates the trader
  bot_state             text    not null default 'start',
  state_data            jsonb   not null default '{}'::jsonb,  -- partial answers during a flow
  language              text    not null default 'en' check (language in ('en','sn','nd')),
  last_inbound_at       timestamptz,          -- opens the 24-hour free-form service window
  handover_status       text    not null default 'none' check (handover_status in ('none','open','closed')),
  handover_branch_id    text,
  handover_opened_at    timestamptz,
  handover_assigned_to  uuid,
  handover_closed_at    timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint uq_conversation_wa unique (client_id, wa_id),
  constraint uq_conversation_client unique (conversation_id, client_id),
  constraint fk_conversation_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_conversation_branch_client foreign key (handover_branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint ck_conversation_handover check (
    handover_status = 'none'
    or (handover_branch_id is not null and handover_opened_at is not null
        and (handover_status = 'open') = (handover_closed_at is null)))
);
alter table crm.conversations enable row level security;
create index if not exists ix_conversations_handover
  on crm.conversations (client_id, handover_branch_id, handover_opened_at) where handover_status = 'open';
create index if not exists ix_conversations_customer on crm.conversations (customer_id);

drop trigger if exists trg_conversations_updated_at on crm.conversations;
create trigger trg_conversations_updated_at before update on crm.conversations
  for each row execute function gold.set_updated_at();

comment on column crm.conversations.bot_state is
  'Bot state machine position, e.g. start, consent, reg_name, reg_business, reg_outlet_type, reg_branch, reg_catchment, menu, reorder_confirm, reorder_qty, reorder_fulfilment, handover.';

/* ---------- messages: WhatsApp and SMS, both directions ---------- */
create table if not exists crm.messages (
  message_id           bigint generated always as identity primary key,
  client_id            text    not null references gold.dim_client(client_id),
  channel              text    not null check (channel in ('whatsapp','sms')),
  direction            text    not null check (direction in ('inbound','outbound')),
  conversation_id      uuid,
  customer_id          uuid,
  address              text    not null,        -- trader number, E.164
  provider_message_id  text,                    -- Meta wamid / SMS gateway id
  message_type         text    not null check (message_type in
                         ('text','interactive','template','button','image','document','location','reaction','system')),
  template_name        text,
  template_language    text,
  body                 text,
  payload              jsonb,
  status               text    not null check (status in
                         ('received','queued','sent','delivered','read','failed')),
  error_code           text,
  error_detail         text,
  exposure_id          bigint  references crm.queue_exposures(exposure_id),  -- set for trigger sends
  order_id             uuid    references crm.orders(order_id),
  sent_by_user         uuid,                    -- null = bot / engine
  wa_event_id          bigint  references bronze.wa_events(event_id),
  created_at           timestamptz not null default now(),
  status_updated_at    timestamptz not null default now(),
  constraint fk_message_conversation_client foreign key (conversation_id, client_id)
    references crm.conversations (conversation_id, client_id),
  constraint fk_message_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_message_template foreign key (client_id, template_name, template_language)
    references crm.wa_templates (client_id, template_name, language),
  constraint ck_message_template check (message_type <> 'template' or (template_name is not null and template_language is not null)),
  constraint ck_message_direction_status check (
    (direction = 'inbound'  and status = 'received')
    or (direction = 'outbound' and status <> 'received'))
);
alter table crm.messages enable row level security;
create unique index if not exists ux_messages_provider_id
  on crm.messages (channel, provider_message_id) where provider_message_id is not null;
create index if not exists ix_messages_conversation on crm.messages (conversation_id, created_at);
create index if not exists ix_messages_customer     on crm.messages (customer_id, created_at desc);
create index if not exists ix_messages_exposure     on crm.messages (exposure_id) where exposure_id is not null;
