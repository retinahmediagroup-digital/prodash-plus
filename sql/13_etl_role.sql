/* ============================================================
   ProDash+ | 13_etl_role.sql
   etl_worker: the login used by notebooks and pipeline jobs.
   It reads and writes the data layers, and cannot change the
   schema, read auth, or grant access. BYPASSRLS because the
   backend tables have RLS on with no policies (deny-all for API
   roles). Safe to re-run.

   After running, set its password yourself (it never goes in Git):
     alter role etl_worker with login password '<strong password>';
   Session pooler username: etl_worker.<project_ref>
   ============================================================ */

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'etl_worker') then
    create role etl_worker nologin bypassrls;
  end if;
end $$;

-- the Data API timeouts do not apply to direct logins; keep jobs bounded
alter role etl_worker set statement_timeout = '10min';

grant usage on schema bronze, silver, gold, crm, ops, scoring to etl_worker;

-- raw, cleaned and scoring layers: full data access (no DDL)
grant select, insert, update, delete on all tables in schema bronze, silver, ops, scoring to etl_worker;
grant usage, select on all sequences in schema bronze, silver, ops, scoring, gold, crm to etl_worker;

-- gold: read everything; write what the pipeline maintains
grant select on all tables in schema gold to etl_worker;
grant insert, update, delete on gold.fact_sales, gold.dim_customer, gold.ref_product_mapping,
                                gold.ref_fx_rate, gold.ref_branch_control_total to etl_worker;
grant insert on gold.ref_engine_param to etl_worker;          -- new versions only, never edits
grant execute on function gold.issue_trader_code(text, text) to etl_worker;

-- crm: read what scoring needs; write assignments and exposures only
grant select on crm.consent, crm.v_consent_current, crm.playbooks, crm.experiments,
                crm.experiment_assignments, crm.queue_exposures, crm.contacts, crm.orders,
                crm.order_items to etl_worker;
grant insert on crm.experiment_assignments, crm.queue_exposures to etl_worker;
grant update (status, receipt_no, fulfilled_at) on crm.orders to etl_worker;   -- mark bot orders fulfilled

-- future tables in the pipeline's own layers
alter default privileges in schema bronze, silver, ops, scoring
  grant select, insert, update, delete on tables to etl_worker;
alter default privileges in schema gold grant select on tables to etl_worker;
