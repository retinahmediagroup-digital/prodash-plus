/* ============================================================
   ProDash+ | tests/sql/test_base_schema.sql
   Assertions for the base schema. LOCAL / THROWAWAY DATABASE ONLY:
   inserts test users, branches and traders. Run via run_local.sh.
   Every failed assert stops the run (ON_ERROR_STOP).
   ============================================================ */
\set ON_ERROR_STOP on
\set QUIET on

/* ---------- fixtures (as superuser) ---------- */
insert into gold.dim_branch (branch_id, client_id, branch_name, region)
values ('BW', 'PRODAIRY', 'Budiriro West (test)', 'Harare');

insert into gold.dim_client (client_id, client_name, code_prefix) values ('OTHERCO', 'Other tenant (test)', 'OC');
insert into gold.dim_brand  (brand_id, client_id, brand_name) values ('OTHERBRAND', 'OTHERCO', 'Other');
insert into gold.dim_branch (branch_id, client_id, branch_name) values ('OC1', 'OTHERCO', 'Other branch');

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'hq@test'),
  ('00000000-0000-0000-0000-00000000000b', 'bm.hf@test'),
  ('00000000-0000-0000-0000-00000000000c', 'bm.bw@test'),
  ('00000000-0000-0000-0000-00000000000d', 'rmg@test'),
  ('00000000-0000-0000-0000-00000000000e', 'other.hq@test');

insert into app.user_profiles (user_id, client_id, role, full_name) values
  ('00000000-0000-0000-0000-00000000000a', 'PRODAIRY', 'hq',             'HQ user'),
  ('00000000-0000-0000-0000-00000000000b', 'PRODAIRY', 'branch_manager', 'HF manager'),
  ('00000000-0000-0000-0000-00000000000c', 'PRODAIRY', 'branch_manager', 'BW manager'),
  ('00000000-0000-0000-0000-00000000000d', null,       'rmg_admin',      'RMG admin'),
  ('00000000-0000-0000-0000-00000000000e', 'OTHERCO',  'hq',             'Other HQ');

insert into app.user_branches (user_id, client_id, branch_id) values
  ('00000000-0000-0000-0000-00000000000b', 'PRODAIRY', 'HF'),
  ('00000000-0000-0000-0000-00000000000c', 'PRODAIRY', 'BW');

/* ---------- 1. normalisers and trader codes ---------- */
do $$
declare c1 text; c2 text; c3 text;
begin
  assert ops.normalise_cell('0772 123 456')     = '+263772123456', 'cell 07.. format';
  assert ops.normalise_cell('+263 77 212 3456') = '+263772123456', 'cell +263 format';
  assert ops.normalise_cell('00263772123456')   = '+263772123456', 'cell 00263 format';
  assert ops.normalise_cell('772123456')        = '+263772123456', 'cell 9-digit format';
  assert ops.normalise_cell('0242 123456') is null, 'landline rejected';
  assert ops.normalise_product_name('  LIFE   250ML ') = 'life 250ml', 'product normaliser';

  c1 := gold.issue_trader_code('PRODAIRY', 'HF');
  c2 := gold.issue_trader_code('PRODAIRY', 'HF');
  c3 := gold.issue_trader_code('PRODAIRY', 'BW');
  assert c1 = 'PD-HF-000001', 'first HF code, got ' || c1;
  assert c2 = 'PD-HF-000002', 'second HF code, got ' || c2;
  assert c3 = 'PD-BW-000001', 'BW counter independent, got ' || c3;
  raise notice 'PASS 1 normalisers and trader codes';
end $$;

/* ---------- 2. identity constraints ---------- */
insert into gold.dim_customer (customer_id, client_id, cell_normalised, trader_code, display_name, home_branch_id, first_seen, last_seen)
values
  ('11111111-0000-0000-0000-000000000001', 'PRODAIRY', '+263772000001', 'PD-HF-000001', 'Tendai (HF)', 'HF', '2026-04-01', '2026-09-20'),
  ('11111111-0000-0000-0000-000000000002', 'PRODAIRY', '+263772000002', 'PD-BW-000001', 'Rudo (BW)',   'BW', '2026-05-01', '2026-09-18'),
  ('11111111-0000-0000-0000-000000000003', 'PRODAIRY', null,            'PD-HF-000002', 'No phone (HF)', 'HF', null, null);

do $$
begin
  begin
    insert into gold.dim_customer (client_id, display_name, home_branch_id) values ('PRODAIRY', 'Anonymous walk-in', 'HF');
    raise exception 'walk-in without cell or trader code was accepted';
  exception when check_violation then null;
  end;
  begin
    insert into gold.dim_customer (client_id, cell_normalised, trader_code) values ('PRODAIRY', '+263772000001', 'PD-HF-000099');
    raise exception 'duplicate phone accepted';
  exception when unique_violation then null;
  end;
  begin
    insert into gold.dim_customer (client_id, trader_code) values ('PRODAIRY', 'PD-HF-1');
    raise exception 'malformed trader code accepted';
  exception when check_violation then null;
  end;
  begin
    insert into gold.dim_customer (client_id, cell_normalised, home_branch_id) values ('OTHERCO', '+263772000009', 'HF');
    raise exception 'cross-tenant branch reference accepted';
  exception when foreign_key_violation then null;
  end;
  assert not exists (select 1 from information_schema.columns
                     where table_schema = 'gold' and table_name = 'dim_customer' and column_name = 'walk_in_flag'),
         'walk_in_flag should be retired';
  raise notice 'PASS 2 identity constraints';
end $$;

/* ---------- 3. load log lifecycle and facts ---------- */
insert into ops.load_log (client_id, source_file, file_sha256, branch_id, rows_in_file, rows_loaded,
                          min_receipt_date, max_receipt_date, status, finished_at, published_at, reconciliation_status)
values ('PRODAIRY', 'hf_sep.csv', repeat('a', 64), 'HF', 3, 3, '2026-09-01', '2026-09-20', 'published', now(), now(), 'passed'),
       ('PRODAIRY', 'bw_sep.csv', repeat('b', 64), 'BW', 2, 2, '2026-09-01', '2026-09-18', 'published', now(), now(), 'passed');

do $$
begin
  begin
    insert into ops.load_log (client_id, source_file, file_sha256, status, finished_at)
    values ('PRODAIRY', 'dup.csv', repeat('a', 64), 'failed', now());
    raise exception 'duplicate file hash accepted';
  exception when unique_violation then null;
  end;
  begin
    insert into ops.load_log (client_id, source_file, file_sha256, rows_in_file, rows_loaded, max_receipt_date, status, finished_at)
    values ('PRODAIRY', 'short.csv', repeat('c', 64), 10, 9, '2026-09-20', 'loaded', now());
    raise exception 'load gate (rows_loaded = rows_in_file) not enforced';
  exception when check_violation then null;
  end;
  raise notice 'PASS 3a load log';
end $$;

insert into gold.fact_sales (client_id, branch_id, receipt_no, line_no, date_key, receipt_ts, customer_id,
                             product_id, quantity, unit_price, line_total, currency, line_total_usd, source, load_id)
select 'PRODAIRY', 'HF', 'HF-1', 1, date '2026-09-20', timestamptz '2026-09-20 10:00+02', uuid '11111111-0000-0000-0000-000000000001',
       'LIFE_250ML', 12, 0.45, 5.40, 'USD', 5.40, 'csv', load_id from ops.load_log where source_file = 'hf_sep.csv'
union all
select 'PRODAIRY', 'HF', 'HF-2', 1, '2026-09-19', '2026-09-19 09:00+02', null,
       'LIFE_250ML', 2, 0.45, 0.90, 'USD', 0.90, 'csv', load_id from ops.load_log where source_file = 'hf_sep.csv'
union all
select 'PRODAIRY', 'BW', 'BW-1', 1, '2026-09-18', '2026-09-18 11:00+02', '11111111-0000-0000-0000-000000000002',
       'LIFE_250ML', 24, 0.45, 10.80, 'USD', 10.80, 'csv', load_id from ops.load_log where source_file = 'bw_sep.csv';

do $$
begin
  begin
    insert into gold.fact_sales (client_id, branch_id, receipt_no, line_no, date_key, receipt_ts, product_id,
                                 quantity, line_total, currency, source)
    values ('PRODAIRY', 'HF', 'HF-9', 1, '2026-09-20', now(), 'LIFE_250ML', 1, 1, 'USD', 'csv');
    raise exception 'csv fact without load_id accepted';
  exception when check_violation then null;
  end;
  begin
    insert into gold.fact_sales (client_id, branch_id, receipt_no, line_no, date_key, receipt_ts, customer_id, product_id,
                                 quantity, line_total, currency, source)
    values ('PRODAIRY', 'HF', 'HF-1', 1, '2026-09-20', now(), null, 'LIFE_250ML', 1, 1, 'USD', 'counter');
    raise exception 'duplicate receipt line accepted';
  exception when unique_violation then null;
  end;
  assert (select snapshot_date from gold.v_branch_data_freshness where branch_id = 'HF') = '2026-09-20', 'HF snapshot';
  assert (select snapshot_date from gold.v_branch_data_freshness where branch_id = 'BW') = '2026-09-18', 'BW snapshot';
  raise notice 'PASS 3b facts and per-branch snapshot';
end $$;

/* ---------- 4. consent rules ---------- */
insert into crm.consent (client_id, customer_id, channel, status, source, wording_version)
values ('PRODAIRY', '11111111-0000-0000-0000-000000000001', 'whatsapp', 'opted_in', 'whatsapp_bot', 'v1');
insert into crm.consent (client_id, customer_id, channel, status, source)
values ('PRODAIRY', '11111111-0000-0000-0000-000000000001', 'whatsapp', 'opted_out', 'stop_keyword');

do $$
begin
  begin
    insert into crm.consent (client_id, customer_id, channel, status, source, wording_version)
    values ('PRODAIRY', '11111111-0000-0000-0000-000000000001', 'whatsapp', 'opted_in', 'counter', 'v1');
    raise exception 'staff re-opt-in after opt-out accepted';
  exception when raise_exception then
    if sqlerrm not like '%only the trader%' then raise; end if;
  end;
  assert (select status from crm.v_consent_current
          where customer_id = '11111111-0000-0000-0000-000000000001' and channel = 'whatsapp') = 'opted_out',
         'current consent should be opted_out';
  -- the trader can opt back in themselves
  insert into crm.consent (client_id, customer_id, channel, status, source, wording_version)
  values ('PRODAIRY', '11111111-0000-0000-0000-000000000001', 'whatsapp', 'opted_in', 'whatsapp_bot', 'v1');
  raise notice 'PASS 4 consent';
end $$;

/* ---------- 5. orders, holdout, exposures ---------- */
insert into crm.orders (order_id, client_id, branch_id, customer_id, source, is_usual_reorder)
values ('22222222-0000-0000-0000-000000000001', 'PRODAIRY', 'HF', '11111111-0000-0000-0000-000000000001', 'whatsapp', true);
insert into crm.order_items (order_id, client_id, line_no, product_id, quantity)
values ('22222222-0000-0000-0000-000000000001', 'PRODAIRY', 1, 'LIFE_250ML', 12);

do $$
declare v_bucket numeric;
begin
  begin
    update crm.orders set status = 'fulfilled', fulfilled_at = now()
    where order_id = '22222222-0000-0000-0000-000000000001';
    raise exception 'requested -> fulfilled accepted';
  exception when raise_exception then
    if sqlerrm not like '%cannot move%' then raise; end if;
  end;
  update crm.orders set status = 'confirmed', confirmed_at = now() where order_id = '22222222-0000-0000-0000-000000000001';
  update crm.orders set status = 'fulfilled', fulfilled_at = now(), receipt_no = 'HF-3' where order_id = '22222222-0000-0000-0000-000000000001';

  v_bucket := crm.holdout_bucket('salt', '11111111-0000-0000-0000-000000000001');
  assert v_bucket >= 0 and v_bucket < 1, 'bucket in [0,1)';
  assert v_bucket = crm.holdout_bucket('salt', '11111111-0000-0000-0000-000000000001'), 'bucket deterministic';

  insert into crm.experiment_assignments (experiment_id, client_id, customer_id, arm, bucket)
  values ('PD_HOLDOUT_2026Q4', 'PRODAIRY', '11111111-0000-0000-0000-000000000001', 'holdout', 0.05);
  begin
    update crm.experiment_assignments set arm = 'treatment' where customer_id = '11111111-0000-0000-0000-000000000001';
    raise exception 'assignment change accepted';
  exception when raise_exception then
    if sqlerrm not like '%permanent%' then raise; end if;
  end;

  begin
    insert into crm.queue_exposures (client_id, branch_id, customer_id, queue_date, trigger_type, state, experiment_id, arm)
    values ('PRODAIRY', 'HF', '11111111-0000-0000-0000-000000000001', '2026-10-05', 'lapse', 'at_risk', 'PD_HOLDOUT_2026Q4', 'holdout');
    raise exception 'holdout exposure without suppression accepted';
  exception when check_violation then null;
  end;
  raise notice 'PASS 5 orders and holdout';
end $$;

insert into crm.queue_exposures (client_id, branch_id, customer_id, queue_date, trigger_type, state, channel,
                                 experiment_id, arm, suppressed_reason)
values ('PRODAIRY', 'HF', '11111111-0000-0000-0000-000000000001', current_date, 'lapse', 'at_risk', 'call',
        'PD_HOLDOUT_2026Q4', 'holdout', 'holdout'),
       ('PRODAIRY', 'HF', '11111111-0000-0000-0000-000000000003', current_date, 'lapse', 'at_risk', 'call',
        null, null, null),
       ('PRODAIRY', 'BW', '11111111-0000-0000-0000-000000000002', current_date, 'lapse', 'at_risk', 'call',
        null, null, null);

insert into crm.conversations (client_id, wa_id, customer_id, last_inbound_at, handover_status, handover_branch_id, handover_opened_at)
values ('PRODAIRY', '+263772000002', '11111111-0000-0000-0000-000000000002', now(), 'open', 'BW', now());

/* ---------- 6. RLS: branch manager HF ---------- */
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true) as _jwt \gset
do $$
begin
  assert (select count(*) from gold.dim_customer) = 2, 'HF manager sees 2 HF traders, got ' || (select count(*) from gold.dim_customer);
  assert not exists (select 1 from gold.dim_customer where home_branch_id <> 'HF'), 'HF manager sees other branch trader';
  assert (select count(*) from gold.fact_sales) = 2, 'HF manager sees only HF sales';
  assert (select count(*) from gold.dim_branch) = 2, 'branch list is client-wide';
  assert not exists (select 1 from gold.dim_client where client_id = 'OTHERCO'), 'other tenant visible';
  assert (select count(*) from crm.queue_exposures) = 1, 'holdout exposure must be hidden from branch staff';
  assert (select count(*) from crm.experiment_assignments) = 0, 'assignments hidden from branch staff';
  assert (select count(*) from api.action_queue) = 1, 'api.action_queue: one HF row';
  assert (select count(*) from api.handover_inbox) = 0, 'BW handover hidden from HF';
  assert (select count(*) from api.bot_orders) = 1, 'HF bot order visible';
  assert (select count(*) from api.upload_history()) = 1, 'HF manager sees only HF uploads';
  assert (select count(*) from api.traders) = 2, 'api.traders scoped';
  assert (select whatsapp_consent from api.traders where trader_code = 'PD-HF-000001') = 'opted_in', 'consent in api.traders';
  raise notice 'PASS 6a HF manager reads';
end $$;

insert into crm.contacts (client_id, branch_id, customer_id, user_id, channel, outcome)
values ('PRODAIRY', 'HF', '11111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000b', 'call', 'reached');

do $$
begin
  begin
    insert into crm.contacts (client_id, branch_id, customer_id, user_id, channel, outcome)
    values ('PRODAIRY', 'BW', '11111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000b', 'call', 'reached');
    raise exception 'HF manager logged a contact for a BW trader';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into crm.contacts (client_id, branch_id, customer_id, user_id, channel, outcome)
    values ('PRODAIRY', 'HF', '11111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000c', 'call', 'reached');
    raise exception 'contact logged as another user';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from ops.load_log;
    raise exception 'ops schema reachable by authenticated';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from bronze.receipts_raw;
    raise exception 'bronze schema reachable by authenticated';
  exception when insufficient_privilege then null;
  end;
  begin
    update crm.orders set cancel_reason = 'x' where branch_id = 'BW';
    -- no error expected, but no BW rows can be touched
  end;
  begin
    update gold.dim_customer set display_name = 'hacked';
    raise exception 'direct trader update allowed';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 6b HF manager writes';
end $$;
commit;

/* ---------- 7. RLS: HQ, RMG, other tenant, kill switch ---------- */
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true) as _jwt \gset
do $$
begin
  assert (select count(*) from gold.dim_customer) = 3, 'HQ sees all ProDairy traders';
  assert (select count(*) from gold.fact_sales) = 3, 'HQ sees all ProDairy sales';
  assert (select count(*) from crm.queue_exposures) = 3, 'HQ sees holdout exposures';
  assert (select count(*) from crm.experiment_assignments) = 1, 'HQ sees assignments';
  assert (select count(*) from api.upload_history()) = 2, 'HQ sees all uploads';
  assert (select snapshot_date from gold.current_snapshot where client_id = 'PRODAIRY') = '2026-09-20', 'HQ snapshot';
  raise notice 'PASS 7a HQ';
end $$;
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000e","role":"authenticated"}', true) as _jwt \gset
do $$
begin
  assert (select count(*) from gold.dim_customer) = 0, 'other tenant sees ProDairy traders';
  assert (select count(*) from gold.fact_sales) = 0, 'other tenant sees ProDairy sales';
  assert gold.snapshot_date('PRODAIRY') is null, 'other tenant reads ProDairy snapshot';
  raise notice 'PASS 7b tenant isolation';
end $$;
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000d","role":"authenticated"}', true) as _jwt \gset
do $$
begin
  assert (select count(*) from gold.dim_client) = 2, 'RMG sees every client';
  assert (select count(*) from gold.dim_customer) = 3, 'RMG sees all traders';
  raise notice 'PASS 7c RMG admin';
end $$;
commit;

update gold.dim_client set status = 'suspended' where client_id = 'PRODAIRY';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true) as _jwt \gset
do $$
begin
  assert (select count(*) from gold.dim_customer) = 0, 'suspended client still visible to HQ';
  raise notice 'PASS 7d subscription kill switch';
end $$;
commit;
update gold.dim_client set status = 'active' where client_id = 'PRODAIRY';

/* ---------- 8. anon sees nothing ---------- */
begin;
set local role anon;
do $$
begin
  begin
    perform count(*) from gold.dim_customer;
    raise exception 'anon can read gold';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from api.traders;
    raise exception 'anon can read api';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 8 anon locked out';
end $$;
commit;

/* ---------- 9. opt-out call outcome becomes consent ---------- */
insert into crm.contacts (client_id, branch_id, customer_id, user_id, channel, outcome)
values ('PRODAIRY', 'BW', '11111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000c', 'call', 'opted_out');
do $$
begin
  assert (select count(*) from crm.v_consent_current
          where customer_id = '11111111-0000-0000-0000-000000000002' and status = 'opted_out') = 2,
         'opt-out outcome should write whatsapp + sms opt-outs';
  raise notice 'PASS 9 opt-out outcome';
end $$;

\echo 'ALL TESTS PASSED'
