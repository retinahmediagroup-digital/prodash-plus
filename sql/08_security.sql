/* ============================================================
   ProDash+ | 08_security.sql
   Users, roles, branch access and row-level security (SSOT §10.4,
   §13). Roles:
     rmg_admin       every client, every branch, Data Health
     hq              every branch of their own client
     branch_manager  only the branches in app.user_branches
   A suspended/ended client disappears for hq and branch managers
   (subscription kill switch); RMG admins still see it.
   bronze, silver and ops stay unreachable from the API; the backend
   uses service_role. Safe to re-run.
   ============================================================ */

/* ---------- app users ---------- */
create table if not exists app.user_profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  client_id   text references gold.dim_client(client_id),
  role        text not null check (role in ('rmg_admin','hq','branch_manager')),
  full_name   text not null,
  phone       text check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint ck_profile_client check (role = 'rmg_admin' or client_id is not null)
);
alter table app.user_profiles enable row level security;

drop trigger if exists trg_user_profiles_updated_at on app.user_profiles;
create trigger trg_user_profiles_updated_at before update on app.user_profiles
  for each row execute function gold.set_updated_at();

create table if not exists app.user_branches (
  user_id    uuid not null references app.user_profiles(user_id) on delete cascade,
  client_id  text not null,
  branch_id  text not null,
  primary key (user_id, branch_id),
  constraint fk_user_branch_client foreign key (branch_id, client_id)
    references gold.dim_branch (branch_id, client_id)
);
alter table app.user_branches enable row level security;

/* ---------- access helpers ----------
   SECURITY DEFINER so policies can read app.* without granting it.
   Call them as (select app.fn()) in policies: Postgres then evaluates
   them once per statement instead of once per row. */
create or replace function app.my_role()
returns text language sql stable security definer set search_path = '' as $$
  select p.role from app.user_profiles p
  where p.user_id = auth.uid() and p.is_active
$$;

create or replace function app.my_client_ids()
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(c.client_id), '{}')
  from gold.dim_client c
  join app.user_profiles p on p.user_id = auth.uid() and p.is_active
  where (p.role = 'rmg_admin')
     or (p.client_id = c.client_id and c.status = 'active')
$$;

create or replace function app.sees_all_branches()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(app.my_role() in ('rmg_admin','hq'), false)
$$;

create or replace function app.my_branch_ids()
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(ub.branch_id), '{}')
  from app.user_branches ub
  join app.user_profiles p on p.user_id = ub.user_id and p.is_active
  where ub.user_id = auth.uid()
$$;

create or replace function app.can_see_branch(p_client_id text, p_branch_id text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_client_id = any(app.my_client_ids())
     and (app.sees_all_branches() or p_branch_id = any(app.my_branch_ids()))
$$;

revoke execute on function app.my_role(), app.my_client_ids(), app.sees_all_branches(),
                           app.my_branch_ids(), app.can_see_branch(text, text) from public;

/* ---------- snapshot accessor (final definition) ----------
   Supersedes 00/03: membership comes from app.user_profiles, and loads
   that are published count as well as loaded. */
create or replace function gold.snapshot_date(p_client_id text)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select max(l.max_receipt_date)
  from ops.load_log l
  where l.client_id = p_client_id
    and l.status in ('loaded','published')
    and (coalesce(auth.jwt() ->> 'role', '') = 'service_role'
         or p_client_id = any(app.my_client_ids()))
$$;
revoke execute on function gold.snapshot_date(text) from public;

create or replace view gold.current_snapshot with (security_invoker = true) as
select c.client_id, gold.snapshot_date(c.client_id) as snapshot_date
from   gold.dim_client c;

/* ---------- grants ---------- */
do $$
declare
  s text;
begin
  -- service_role: full backend access to every ProDash+ schema
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    foreach s in array array['bronze','silver','gold','crm','ops','scoring','app','api'] loop
      execute format('grant usage on schema %I to service_role', s);
      execute format('grant all on all tables in schema %I to service_role', s);
      execute format('grant all on all sequences in schema %I to service_role', s);
      execute format('grant execute on all functions in schema %I to service_role', s);
      execute format('alter default privileges in schema %I grant all on tables to service_role', s);
      execute format('alter default privileges in schema %I grant all on sequences to service_role', s);
      execute format('alter default privileges in schema %I grant execute on functions to service_role', s);
    end loop;
  end if;

  -- anon: nothing, anywhere
  if exists (select 1 from pg_roles where rolname = 'anon') then
    foreach s in array array['bronze','silver','gold','crm','ops','scoring','app','api'] loop
      execute format('revoke all on all tables in schema %I from anon', s);
      execute format('revoke usage on schema %I from anon', s);
    end loop;
  end if;

  -- authenticated: reads through RLS; no raw layers
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke usage on schema bronze, silver, ops from authenticated';
    execute 'grant usage on schema gold, crm, scoring, app, api to authenticated';
    execute 'grant execute on function app.my_role(), app.my_client_ids(), app.sees_all_branches(),
                                       app.my_branch_ids(), app.can_see_branch(text, text),
                                       gold.snapshot_date(text) to authenticated';

    execute 'grant select on gold.dim_client, gold.dim_brand, gold.dim_branch, gold.dim_product,
                             gold.ref_product_mapping, gold.dim_customer, gold.dim_date,
                             gold.ref_fx_rate, gold.ref_engine_param, gold.ref_branch_control_total,
                             gold.fact_sales, gold._customer_active, gold._customer_scorable,
                             gold.v_engine_param_current, gold.v_branch_data_freshness,
                             gold.current_snapshot
             to authenticated';
    execute 'grant select on crm.consent, crm.v_consent_current, crm.playbooks,
                             crm.experiment_assignments, crm.queue_exposures, crm.contacts, crm.notes,
                             crm.orders, crm.order_items, crm.field_tasks, crm.wa_templates,
                             crm.conversations, crm.messages
             to authenticated';
    -- never the salt: with it, holdout membership could be recomputed by branch staff
    execute 'revoke select on crm.experiments from authenticated';
    execute 'grant select (experiment_id, client_id, name, holdout_share, eligible_states,
                           starts_on, ends_on, status, created_at)
             on crm.experiments to authenticated';
    execute 'grant select on scoring.runs, scoring.trader_scores, scoring.triggers,
                             scoring.v_current_scores to authenticated';
    execute 'grant select on app.user_profiles, app.user_branches to authenticated';

    -- writes staff make directly (everything else goes through api RPCs / service role)
    execute 'grant insert (client_id, branch_id, customer_id, exposure_id, user_id, channel, outcome, note)
             on crm.contacts to authenticated';
    execute 'grant insert (client_id, branch_id, customer_id, user_id, body) on crm.notes to authenticated';
    execute 'grant insert (client_id, customer_id, channel, status, source, wording_version, branch_id, captured_by, note)
             on crm.consent to authenticated';
    execute 'grant update (status, fulfilment_type, requested_for, receipt_no, confirmed_at, confirmed_by,
                           fulfilled_at, cancelled_at, cancelled_by, cancel_reason)
             on crm.orders to authenticated';
    execute 'grant update (status, outcome, completed_at, assigned_to) on crm.field_tasks to authenticated';
    execute 'grant update (handover_status, handover_assigned_to, handover_closed_at)
             on crm.conversations to authenticated';
  end if;
end $$;

/* ---------- RLS policies (authenticated) ---------- */
do $$
declare
  t text;
  v_client   constant text := 'array[client_id] <@ (select app.my_client_ids())';
  v_branch   constant text := 'array[client_id] <@ (select app.my_client_ids()) and ((select app.sees_all_branches()) or array[branch_id] <@ (select app.my_branch_ids()))';
  v_customer constant text := 'customer_id in (select customer_id from gold.dim_customer)';  -- inherits dim_customer RLS
  v_allrows  constant text := 'true';
begin
  -- client-wide reference data
  foreach t in array array['gold.dim_client','gold.dim_brand','gold.dim_branch','gold.dim_product',
                           'gold.ref_product_mapping','gold.ref_engine_param','crm.playbooks',
                           'crm.experiments','crm.wa_templates','scoring.runs'] loop
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (%s)', t, v_client);
  end loop;

  -- shared lookups
  foreach t in array array['gold.dim_date','gold.ref_fx_rate'] loop
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (%s)', t, v_allrows);
  end loop;

  -- branch-scoped data
  foreach t in array array['gold.fact_sales','gold.ref_branch_control_total','crm.contacts',
                           'crm.orders','crm.field_tasks','scoring.trader_scores','scoring.triggers'] loop
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (%s)', t, v_branch);
  end loop;

  -- notes may have no branch: visible if the trader is visible
  drop policy if exists p_select on crm.notes;
  execute format('create policy p_select on crm.notes for select to authenticated using (%s and %s)', v_client, v_customer);

  -- traders: HQ/RMG see all; branch managers see their home-branch traders
  drop policy if exists p_select on gold.dim_customer;
  execute format('create policy p_select on gold.dim_customer for select to authenticated using (%s)',
                 replace(v_branch, 'array[branch_id]', 'array[home_branch_id]'));

  -- consent: visible when the trader is visible
  drop policy if exists p_select on crm.consent;
  execute format('create policy p_select on crm.consent for select to authenticated using (%s and %s)', v_client, v_customer);

  -- holdout membership is hidden from branch staff so it cannot bias who they call
  drop policy if exists p_select on crm.experiment_assignments;
  execute format('create policy p_select on crm.experiment_assignments for select to authenticated using (%s and (select app.sees_all_branches()))', v_client);

  drop policy if exists p_select on crm.queue_exposures;
  execute format('create policy p_select on crm.queue_exposures for select to authenticated using (%s and ((select app.sees_all_branches()) or suppressed_reason is distinct from %L))',
                 v_branch, 'holdout');

  drop policy if exists p_select on crm.order_items;
  create policy p_select on crm.order_items for select to authenticated
    using (order_id in (select order_id from crm.orders));

  -- conversations: HQ/RMG, the handover branch, or the trader's home branch
  drop policy if exists p_select on crm.conversations;
  execute format('create policy p_select on crm.conversations for select to authenticated using (%s and ((select app.sees_all_branches()) or array[handover_branch_id] <@ (select app.my_branch_ids()) or %s))',
                 v_client, v_customer);

  drop policy if exists p_select on crm.messages;
  execute format('create policy p_select on crm.messages for select to authenticated using (%s and (%s or conversation_id in (select conversation_id from crm.conversations)))',
                 v_client, v_customer);

  -- users: yourself; HQ sees their client's users; RMG sees all
  drop policy if exists p_select on app.user_profiles;
  create policy p_select on app.user_profiles for select to authenticated
    using (user_id = (select auth.uid())
           or ((select app.sees_all_branches()) and (array[client_id] <@ (select app.my_client_ids()) or (select app.my_role()) = 'rmg_admin')));
  drop policy if exists p_select on app.user_branches;
  create policy p_select on app.user_branches for select to authenticated
    using (user_id = (select auth.uid())
           or ((select app.sees_all_branches()) and array[client_id] <@ (select app.my_client_ids())));

  /* ---- writes ---- */
  drop policy if exists p_insert on crm.contacts;
  execute format('create policy p_insert on crm.contacts for insert to authenticated with check (%s and user_id = (select auth.uid()) and %s)', v_branch, v_customer);

  drop policy if exists p_insert on crm.notes;
  execute format('create policy p_insert on crm.notes for insert to authenticated with check (%s and user_id = (select auth.uid()) and %s and (branch_id is null or array[branch_id] <@ (select app.my_branch_ids()) or (select app.sees_all_branches())))', v_client, v_customer);

  drop policy if exists p_insert on crm.consent;
  execute format('create policy p_insert on crm.consent for insert to authenticated with check (%s and %s and captured_by = (select auth.uid()) and source in (%L, %L, %L, %L))',
                 v_client, v_customer, 'counter', 'call', 'field', 'app');

  drop policy if exists p_update on crm.orders;
  execute format('create policy p_update on crm.orders for update to authenticated using (%s) with check (%s)', v_branch, v_branch);

  drop policy if exists p_update on crm.field_tasks;
  execute format('create policy p_update on crm.field_tasks for update to authenticated using (%s) with check (%s)', v_branch, v_branch);

  drop policy if exists p_update on crm.conversations;
  execute format('create policy p_update on crm.conversations for update to authenticated using (%s and ((select app.sees_all_branches()) or array[handover_branch_id] <@ (select app.my_branch_ids()))) with check (%s)',
                 v_client, v_client);
end $$;
