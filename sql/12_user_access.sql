/* ============================================================
   ProDash+ | 12_user_access.sql
   Admin helpers for giving people dashboard access. Every RLS
   policy reads app.user_profiles / app.user_branches, so a signed-in
   user with no profile sees nothing.

   Steps for each person:
     1. Supabase dashboard > Authentication > Users > Invite user (email)
     2. SQL editor:
          select app.grant_access('manager.hf@prodairy.co.zw', 'branch_manager',
                                  'PRODAIRY', 'Highfield Manager', array['HF']);
          select app.grant_access('sponsor@prodairy.co.zw', 'hq', 'PRODAIRY', 'ProDairy Sponsor');
          select app.grant_access('analyst@rmg.co.zw', 'rmg_admin', null, 'RMG Analyst');
     3. To remove access:  select app.revoke_access('manager.hf@prodairy.co.zw');

   Callable only by postgres (SQL editor) and service_role, never by
   app users. Safe to re-run.
   ============================================================ */

create or replace function app.grant_access(
  p_email       text,
  p_role        text,
  p_client_id   text,
  p_full_name   text,
  p_branch_ids  text[] default '{}'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  select id into v_user_id
  from auth.users
  where lower(email) = lower(btrim(p_email));
  if v_user_id is null then
    raise exception 'No auth user with email %. Invite them first (Authentication > Users > Invite user).', p_email;
  end if;

  if p_role = 'branch_manager' and coalesce(cardinality(p_branch_ids), 0) = 0 then
    raise exception 'A branch_manager needs at least one branch_id.';
  end if;
  if p_role <> 'branch_manager' and coalesce(cardinality(p_branch_ids), 0) > 0 then
    raise exception 'Only branch_manager users are given branches; % sees all branches of their client.', p_role;
  end if;

  insert into app.user_profiles (user_id, client_id, role, full_name, is_active)
  values (v_user_id, p_client_id, p_role, p_full_name, true)
  on conflict (user_id) do update
    set client_id = excluded.client_id,
        role      = excluded.role,
        full_name = excluded.full_name,
        is_active = true;

  delete from app.user_branches where user_id = v_user_id;
  insert into app.user_branches (user_id, client_id, branch_id)
  select v_user_id, p_client_id, b
  from unnest(p_branch_ids) b;

  return v_user_id;
end;
$$;

create or replace function app.revoke_access(p_email text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update app.user_profiles p
     set is_active = false
    from auth.users u
   where u.id = p.user_id
     and lower(u.email) = lower(btrim(p_email));
  if not found then
    raise exception 'No ProDash+ profile for %', p_email;
  end if;
end;
$$;

comment on function app.grant_access(text, text, text, text, text[]) is
  'Create or update a user''s ProDash+ role and branches. Run by an RMG admin in the SQL editor.';
comment on function app.revoke_access(text) is
  'Deactivate a user: they keep their login but see nothing.';

revoke execute on function app.grant_access(text, text, text, text, text[]) from public;
revoke execute on function app.revoke_access(text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke execute on function app.grant_access(text, text, text, text, text[]) from authenticated';
    execute 'revoke execute on function app.revoke_access(text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function app.grant_access(text, text, text, text, text[]) to service_role';
    execute 'grant execute on function app.revoke_access(text) to service_role';
  end if;
end $$;
