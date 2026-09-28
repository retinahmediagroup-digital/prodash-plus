/* ============================================================
   ProDash+ | 07_scoring.sql
   Engine outputs (SSOT §6, §7, §12.1). Append-only per run, so tier
   history, month-to-month movement and any past queue can be
   reproduced. Written by the pipeline (service role) only.
   Safe to re-run.
   ============================================================ */

create table if not exists scoring.runs (
  run_id          bigint generated always as identity primary key,
  client_id       text    not null references gold.dim_client(client_id),
  run_type        text    not null check (run_type in ('upload','nightly','weekly_tier','manual','backfill')),
  as_of_date      date    not null,              -- for backfill: the historical month-end being scored
  load_id         bigint  references ops.load_log(load_id),
  params          jsonb   not null,              -- snapshot of gold.v_engine_param_current used
  status          text    not null default 'running' check (status in ('running','succeeded','failed')),
  error_message   text,
  started_at      timestamptz not null default now(),
  finished_at     timestamptz,
  constraint uq_run_client unique (run_id, client_id),
  constraint ck_run_finished check (status = 'running' or finished_at is not null)
);
alter table scoring.runs enable row level security;
create index if not exists ix_runs_client_latest on scoring.runs (client_id, as_of_date desc, run_id desc) where status = 'succeeded';

create table if not exists scoring.trader_scores (
  run_id                 bigint  not null,
  client_id              text    not null,
  customer_id            uuid    not null,
  branch_id              text    not null,       -- home branch the trader is scored and queued in
  scoring_pool           text    not null,       -- branch_id, or 'POOLED' for branches under the minimum size
  snapshot_date          date    not null,       -- branch snapshot used for recency (SSOT §11.5)
  first_purchase_date    date    not null,
  last_purchase_date     date    not null,
  tenure_days            integer not null check (tenure_days >= 0),
  recency_days           integer not null check (recency_days >= 0),
  purchase_days_180d     integer not null check (purchase_days_180d >= 0),
  purchase_days_total    integer not null check (purchase_days_total > 0),
  spend_180d_usd         numeric(14,2),
  avg_monthly_spend_usd  numeric(14,2),
  r_score                smallint check (r_score between 1 and 5),
  f_score                smallint check (f_score between 1 and 5),
  m_score                smallint check (m_score between 1 and 5),
  sub_segment            text    check (sub_segment in
                           ('champions','loyal','promising_new','needs_attention','at_risk','cant_lose','lapsed')),
  state                  text    not null check (state in ('new','regular','champion','at_risk','lapsed')),
  tier                   text    not null check (tier in ('new','regular','champion')),
  expected_gap_days      numeric(8,2) check (expected_gap_days > 0),
  gap_source             text    check (gap_source in ('own','shrunk','segment')),
  overdue_ratio          numeric(8,3) check (overdue_ratio >= 0),
  priority               numeric(10,4),
  usual_basket           jsonb,                  -- [{"product_id":"LIFE_250ML","quantity":12,"unit":"case"}]
  next_expected_date     date,
  created_at             timestamptz not null default now(),
  primary key (run_id, customer_id),
  constraint fk_score_run_client foreign key (run_id, client_id)
    references scoring.runs (run_id, client_id),
  constraint fk_score_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_score_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint ck_score_dates check (first_purchase_date <= last_purchase_date and last_purchase_date <= snapshot_date),
  constraint ck_score_tier_matches_state check (state not in ('new','regular','champion') or tier = state),
  constraint ck_score_rfm_complete check (
    (r_score is null and f_score is null and m_score is null and sub_segment is null)
    or (r_score is not null and f_score is not null and m_score is not null and sub_segment is not null))
);
alter table scoring.trader_scores enable row level security;
create index if not exists ix_scores_customer on scoring.trader_scores (customer_id, run_id desc);
create index if not exists ix_scores_branch   on scoring.trader_scores (run_id, branch_id, priority desc);

comment on column scoring.trader_scores.tier is
  'Trader-facing tier shown in the bot. For at_risk / lapsed traders this is the last tier they held (SSOT §6.1).';
comment on column scoring.trader_scores.r_score is
  'Null (with f, m and sub_segment) for traders with under the minimum history: they are New and not RFM-scored (SSOT §6.2).';

create table if not exists scoring.triggers (
  trigger_id     bigint generated always as identity primary key,
  run_id         bigint  not null,
  client_id      text    not null,
  customer_id    uuid    not null,
  branch_id      text    not null,
  trigger_type   text    not null check (trigger_type in
                   ('welcome','usual_day','lapse','basket_drop','event','segment_move','stock_signal')),
  scheduled_for  timestamptz not null,
  playbook_id    text,
  status         text    not null default 'pending'
                 check (status in ('pending','exposed','suppressed','cancelled')),
  exposure_id    bigint  references crm.queue_exposures(exposure_id),
  created_at     timestamptz not null default now(),
  constraint uq_trigger_run unique (run_id, customer_id, trigger_type),
  constraint fk_trigger_run_client foreign key (run_id, client_id)
    references scoring.runs (run_id, client_id),
  constraint fk_trigger_customer_client foreign key (customer_id, client_id)
    references gold.dim_customer (customer_id, client_id),
  constraint fk_trigger_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id),
  constraint fk_trigger_playbook_client foreign key (playbook_id, client_id)
    references crm.playbooks (playbook_id, client_id),
  constraint ck_trigger_exposed check (status not in ('exposed','suppressed') or exposure_id is not null)
);
alter table scoring.triggers enable row level security;
create index if not exists ix_triggers_due on scoring.triggers (scheduled_for) where status = 'pending';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fk_exposure_run') then
    alter table crm.queue_exposures add constraint fk_exposure_run
      foreign key (run_id) references scoring.runs(run_id);
  end if;
end $$;

/* ---------- latest succeeded run per client ---------- */
create or replace view scoring.v_current_scores with (security_invoker = true) as
select s.*
from   scoring.trader_scores s
join  (select distinct on (client_id) client_id, run_id
       from   scoring.runs
       where  status = 'succeeded' and run_type <> 'backfill'
       order  by client_id, as_of_date desc, run_id desc) r
  on   r.run_id = s.run_id;

comment on view scoring.v_current_scores is
  'Current tier, state and priority for every scored trader (latest succeeded non-backfill run).';
