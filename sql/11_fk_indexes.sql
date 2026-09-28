/* ============================================================
   ProDash+ | 11_fk_indexes.sql
   An index behind every foreign key that had none (Supabase
   performance advisor, 27 Sep 2026). Without them, deleting or
   re-keying a parent row (a merged trader, a cancelled order) and
   the trader/branch joins the app runs scan the whole child table.
   Cheap while tables are small; add before receipt volumes arrive.
   Safe to re-run.
   ============================================================ */

-- app
create index if not exists ix_user_branches_branch_client   on app.user_branches (branch_id, client_id);
create index if not exists ix_user_profiles_client          on app.user_profiles (client_id);

-- crm: consent, contacts, notes, tasks
create index if not exists ix_consent_branch_client         on crm.consent (branch_id, client_id);
create index if not exists ix_consent_customer_client       on crm.consent (customer_id, client_id);
create index if not exists ix_contacts_exposure             on crm.contacts (exposure_id);
create index if not exists ix_contacts_customer_client      on crm.contacts (customer_id, client_id);
create index if not exists ix_notes_branch_client           on crm.notes (branch_id, client_id);
create index if not exists ix_notes_customer_client         on crm.notes (customer_id, client_id);
create index if not exists ix_field_tasks_exposure          on crm.field_tasks (exposure_id);
create index if not exists ix_field_tasks_customer_client   on crm.field_tasks (customer_id, client_id);

-- crm: experiment, playbooks, exposures
create index if not exists ix_experiments_client            on crm.experiments (client_id);
create index if not exists ix_assignments_customer_client   on crm.experiment_assignments (customer_id, client_id);
create index if not exists ix_assignments_experiment_client on crm.experiment_assignments (experiment_id, client_id);
create index if not exists ix_playbooks_client              on crm.playbooks (client_id);
create index if not exists ix_exposures_assignment          on crm.queue_exposures (experiment_id, customer_id);
create index if not exists ix_exposures_playbook_client     on crm.queue_exposures (playbook_id, client_id);
create index if not exists ix_exposures_run                 on crm.queue_exposures (run_id);

-- crm: orders
create index if not exists ix_orders_customer_client        on crm.orders (customer_id, client_id);
create index if not exists ix_orders_exposure               on crm.orders (exposure_id);
create index if not exists ix_order_items_order_client      on crm.order_items (order_id, client_id);
create index if not exists ix_order_items_product_client    on crm.order_items (product_id, client_id);

-- crm: WhatsApp
create index if not exists ix_conversations_customer_client on crm.conversations (customer_id, client_id);
create index if not exists ix_messages_conversation_client  on crm.messages (conversation_id, client_id);
create index if not exists ix_messages_customer_client      on crm.messages (customer_id, client_id);
create index if not exists ix_messages_template             on crm.messages (client_id, template_name, template_language);
create index if not exists ix_messages_order                on crm.messages (order_id);
create index if not exists ix_messages_wa_event             on crm.messages (wa_event_id);

-- gold
create index if not exists ix_customer_merge_client         on gold.dim_customer (merged_into_customer_id, client_id);
create index if not exists ix_fact_date                     on gold.fact_sales (date_key);
create index if not exists ix_fact_customer_client          on gold.fact_sales (customer_id, client_id);
create index if not exists ix_fact_order                    on gold.fact_sales (order_id);
create index if not exists ix_fact_product_client           on gold.fact_sales (product_id, client_id);

-- silver
create index if not exists ix_items_customer_client         on silver.receipt_items (customer_id, client_id);
create index if not exists ix_items_product_client          on silver.receipt_items (product_id, client_id);

-- scoring
create index if not exists ix_runs_load                     on scoring.runs (load_id);
create index if not exists ix_scores_branch_client          on scoring.trader_scores (branch_id, client_id);
create index if not exists ix_scores_customer_client        on scoring.trader_scores (customer_id, client_id);
create index if not exists ix_scores_run_client             on scoring.trader_scores (run_id, client_id);
create index if not exists ix_triggers_branch_client        on scoring.triggers (branch_id, client_id);
create index if not exists ix_triggers_customer_client      on scoring.triggers (customer_id, client_id);
create index if not exists ix_triggers_playbook_client      on scoring.triggers (playbook_id, client_id);
create index if not exists ix_triggers_run_client           on scoring.triggers (run_id, client_id);
create index if not exists ix_triggers_exposure             on scoring.triggers (exposure_id);
