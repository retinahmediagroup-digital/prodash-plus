/* ============================================================
   ProDash+ | 09_api.sql
   The web app's read surface. Every view is security_invoker, so
   the caller's RLS from 08 applies underneath. Expose ONLY `api`
   in Supabase Settings > API > Exposed schemas.
   Write RPCs (log contact, confirm order, register trader, ...)
   are added with the app screens that use them. Safe to re-run.
   ============================================================ */

drop view if exists api.branches;
drop view if exists api.traders;
drop view if exists api.action_queue;
drop view if exists api.bot_orders;
drop view if exists api.handover_inbox;

/* ---------- branches + "data current to" stamp ---------- */
create view api.branches with (security_invoker = true) as
select b.client_id, b.branch_id, b.branch_name, b.region, b.tier, b.is_active,
       f.snapshot_date, f.days_since_data, f.is_stale
from   gold.dim_branch b
left   join gold.v_branch_data_freshness f using (client_id, branch_id);

/* ---------- traders with current tier, state and consent ---------- */
create view api.traders with (security_invoker = true) as
select c.client_id,
       c.customer_id,
       c.trader_code,
       c.display_name,
       c.business_name,
       c.cell_normalised,
       c.outlet_type,
       c.catchment,
       c.home_branch_id,
       c.registration_source,
       c.registered_at,
       c.first_seen,
       c.last_seen,
       c.shared_phone_flag,
       s.tier,
       s.state,
       s.sub_segment,
       s.recency_days,
       s.expected_gap_days,
       s.overdue_ratio,
       s.next_expected_date,
       s.avg_monthly_spend_usd,
       s.priority,
       coalesce(wa.status, 'unknown')  as whatsapp_consent,
       coalesce(sms.status, 'unknown') as sms_consent
from   gold.dim_customer c
left   join scoring.v_current_scores s  on s.customer_id = c.customer_id
left   join crm.v_consent_current wa    on wa.customer_id  = c.customer_id and wa.channel  = 'whatsapp'
left   join crm.v_consent_current sms   on sms.customer_id = c.customer_id and sms.channel = 'sms'
where  c.merged_into_customer_id is null;

/* ---------- today's Action Queue per branch (SSOT §10.3) ---------- */
create view api.action_queue with (security_invoker = true) as
select e.exposure_id,
       e.client_id,
       e.branch_id,
       e.queue_date,
       e.rank_in_branch,
       e.priority,
       e.trigger_type,
       e.state,
       e.sub_segment,
       e.channel,
       p.offer_code,
       p.offer_text,
       p.template_name,
       c.customer_id,
       c.trader_code,
       c.display_name,
       c.business_name,
       c.cell_normalised,
       lc.outcome      as last_outcome,
       lc.contacted_at as last_contacted_at
from   crm.queue_exposures e
join   gold.dim_customer c on c.customer_id = e.customer_id
left   join crm.playbooks p on p.playbook_id = e.playbook_id
left   join lateral (
         select k.outcome, k.contacted_at
         from   crm.contacts k
         where  k.customer_id = e.customer_id
         order  by k.contacted_at desc
         limit  1) lc on true
where  e.suppressed_reason is null
  and  e.channel in ('call','visit','counter')
  and  e.queue_date = (current_timestamp at time zone 'Africa/Harare')::date;

/* ---------- WhatsApp bot orders awaiting the branch ---------- */
create view api.bot_orders with (security_invoker = true) as
select o.order_id, o.client_id, o.branch_id, o.status, o.source,
       o.fulfilment_type, o.requested_for, o.is_usual_reorder,
       o.currency, o.estimated_total, o.requested_at, o.confirmed_at, o.fulfilled_at,
       c.customer_id, c.trader_code, c.display_name, c.business_name, c.cell_normalised,
       (select jsonb_agg(jsonb_build_object('line_no', i.line_no, 'product_id', i.product_id,
                                            'quantity', i.quantity, 'unit', i.unit)
                         order by i.line_no)
        from crm.order_items i where i.order_id = o.order_id) as items
from   crm.orders o
join   gold.dim_customer c on c.customer_id = o.customer_id;

/* ---------- human handover inbox (SSOT §9.2 B) ---------- */
create view api.handover_inbox with (security_invoker = true) as
select v.conversation_id, v.client_id, v.handover_branch_id as branch_id,
       v.wa_id, v.language, v.handover_opened_at, v.handover_assigned_to,
       v.last_inbound_at,
       v.last_inbound_at > now() - interval '24 hours' as within_service_window,
       c.customer_id, c.trader_code, c.display_name, c.business_name
from   crm.conversations v
left   join gold.dim_customer c on c.customer_id = v.customer_id
where  v.handover_status = 'open';

/* ---------- upload history (ops is not API-reachable, so a definer
   function with the access check written out) ---------- */
create or replace function api.upload_history(p_branch_id text default null, p_limit integer default 50)
returns table (
  load_id bigint, client_id text, branch_id text, source_file text, status text,
  rows_in_file integer, rows_loaded integer, rows_rejected integer, rows_published integer,
  reconciliation_status text, min_receipt_date date, max_receipt_date date,
  error_message text, started_at timestamptz, finished_at timestamptz, published_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select l.load_id, l.client_id, l.branch_id, l.source_file, l.status,
         l.rows_in_file, l.rows_loaded, l.rows_rejected, l.rows_published,
         l.reconciliation_status, l.min_receipt_date, l.max_receipt_date,
         l.error_message, l.started_at, l.finished_at, l.published_at
  from   ops.load_log l
  where  l.client_id = any(app.my_client_ids())
    and  (app.sees_all_branches() or l.branch_id = any(app.my_branch_ids()))
    and  (p_branch_id is null or l.branch_id = p_branch_id)
  order  by l.started_at desc
  limit  least(greatest(coalesce(p_limit, 50), 1), 500)
$$;

revoke execute on function api.upload_history(text, integer) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on api.branches, api.traders, api.action_queue, api.bot_orders,
                             api.handover_inbox to authenticated';
    execute 'grant execute on function api.upload_history(text, integer) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select on all tables in schema api to service_role';
    execute 'grant execute on all functions in schema api to service_role';
  end if;
end $$;
