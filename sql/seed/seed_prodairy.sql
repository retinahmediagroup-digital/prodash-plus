/* ============================================================
   ProDash+ | seed/seed_prodairy.sql
   Tenant one: ProDairy. Reference data only -- never customer data.
   Run after sql/00..10. Safe to re-run (upserts).
   ============================================================ */

/* ---------- client ---------- */
insert into gold.dim_client (client_id, client_name, status, code_prefix, timezone, base_currency)
values ('PRODAIRY', 'ProDairy', 'active', 'PD', 'Africa/Harare', 'USD')
on conflict (client_id) do update
  set client_name = excluded.client_name,
      code_prefix = coalesce(gold.dim_client.code_prefix, excluded.code_prefix);

/* ---------- brand & focus product ---------- */
insert into gold.dim_brand (brand_id, client_id, brand_name)
values ('LIFE', 'PRODAIRY', 'LIFE')
on conflict (brand_id) do nothing;

insert into gold.dim_product (product_id, client_id, brand_id, product_name, category, pack_size_ml, is_250_ml)
values ('LIFE_250ML', 'PRODAIRY', 'LIFE', 'LIFE 250ml', 'Dairy', 250, true)
on conflict (product_id) do nothing;
-- units_per_case: set once ProDairy confirms (SSOT §18 Q12), e.g.
-- update gold.dim_product set units_per_case = 24 where product_id = 'LIFE_250ML';

insert into gold.ref_product_mapping (client_id, raw_product_name, product_id)
select 'PRODAIRY', n, 'LIFE_250ML'
from unnest(array['life 250','life250','life 250ml','life 250 ml','life 250mls','life 250 mls']) n
on conflict (client_id, raw_product_name) do nothing;

/* ---------- branches ----------
   Only Highfield is confirmed. Add the other 15 shops once ProDairy
   sends the list (SSOT §18 Q1/Q6). branch_id: short uppercase code. */
insert into gold.dim_branch (branch_id, client_id, branch_name, region)
values ('HF', 'PRODAIRY', 'Highfield', 'Harare')
on conflict (branch_id) do nothing;

/* ---------- FX: USD is its own base ---------- */
insert into gold.ref_fx_rate (rate_date, currency, usd_per_unit, source)
select d::date, 'USD', 1, 'identity'
from generate_series(date '2025-01-01', date '2028-12-31', interval '1 day') d
on conflict (rate_date, currency) do nothing;

/* ---------- engine parameters v1 (SSOT §6, §7, §11.7) ---------- */
insert into gold.ref_engine_param (client_id, param_key, version, value_num, value_text, description, valid_from)
values
  ('PRODAIRY','at_risk_days',            1, 14,   null, 'Deck rule: no order for this many days -> At-Risk', '2026-09-27'),
  ('PRODAIRY','overdue_multiplier',      1, 1.5,  null, 'At-Risk when days since last > multiplier x expected gap', '2026-09-27'),
  ('PRODAIRY','overdue_min_days',        1, 7,    null, 'Minimum days before the rhythm rule can fire', '2026-09-27'),
  ('PRODAIRY','lapsed_multiplier',       1, 3,    null, 'Lapsed when days since last > multiplier x expected gap', '2026-09-27'),
  ('PRODAIRY','lapsed_max_days',         1, 90,   null, 'Lapsed when days since last > this', '2026-09-27'),
  ('PRODAIRY','new_tenure_days',         1, 30,   null, 'New: first purchase within this many days', '2026-09-27'),
  ('PRODAIRY','new_max_purchases',       1, 2,    null, 'New: at most this many purchase days', '2026-09-27'),
  ('PRODAIRY','min_history_days',        1, 45,   null, 'Below this tenure a trader is not RFM-scored', '2026-09-27'),
  ('PRODAIRY','gap_shrink_k',            1, 3,    null, 'Shrinkage weight towards the segment median gap', '2026-09-27'),
  ('PRODAIRY','f_thresholds',            1, null, '1,2,3,5,9', 'Purchase-day lower bounds for F scores 1..5', '2026-09-27'),
  ('PRODAIRY','pool_min_traders',        1, 100,  null, 'Branches with fewer scored traders are pooled for percentiles', '2026-09-27'),
  ('PRODAIRY','basket_drop_ratio',       1, 0.6,  null, 'Basket-drop trigger: last basket < ratio x 90-day median', '2026-09-27'),
  ('PRODAIRY','prompt_send_hour',        1, 9,    null, 'Local hour for usual-day reorder prompts', '2026-09-27'),
  ('PRODAIRY','holdout_share',           1, 0.20, null, 'Share of eligible traders held out', '2026-09-27'),
  ('PRODAIRY','lift_min_per_arm',        1, 400,  null, 'Hide lift until this many traders per arm are evaluated', '2026-09-27'),
  ('PRODAIRY','weight_cant_lose',        1, 1.5,  null, 'Priority weight', '2026-09-27'),
  ('PRODAIRY','weight_at_risk',          1, 1.3,  null, 'Priority weight', '2026-09-27'),
  ('PRODAIRY','weight_needs_attention',  1, 1.0,  null, 'Priority weight', '2026-09-27'),
  ('PRODAIRY','weight_other',            1, 0.7,  null, 'Priority weight', '2026-09-27'),
  ('PRODAIRY','reconcile_tolerance_pct', 1, 0.5,  null, 'Max % revenue difference vs control totals before an upload is held', '2026-09-27')
on conflict (client_id, param_key, version) do nothing;

/* ---------- holdout experiment (starts on Test Day) ---------- */
insert into crm.experiments (experiment_id, client_id, name, holdout_share, eligible_states, starts_on, status)
values ('PD_HOLDOUT_2026Q4', 'PRODAIRY', 'Phase 1 persistent holdout', 0.20,
        array['at_risk','regular'], '2026-10-05', 'draft')
on conflict (experiment_id) do nothing;

/* ---------- playbooks (inactive until the Sponsor approves offers) ---------- */
insert into crm.playbooks (playbook_id, client_id, state, sub_segment, trigger_type, channel, template_name, offer_text, cap_days)
values
  ('PD_CANT_LOSE_CALL',   'PRODAIRY', 'at_risk',  'cant_lose', 'lapse',        'call',     null,                 'Priority service / loyalty reward', 7),
  ('PD_AT_RISK_RECOVERY', 'PRODAIRY', 'at_risk',  null,        'lapse',        'whatsapp', 'pd_recovery',        'Small bundle incentive', 7),
  ('PD_REGULAR_USUAL',    'PRODAIRY', 'regular',  null,        'usual_day',    'whatsapp', 'pd_reorder_prompt',  null, 7),
  ('PD_BASKET_DROP',      'PRODAIRY', 'regular',  null,        'basket_drop',  'whatsapp', 'pd_reorder_prompt',  'Small add-on', 14),
  ('PD_NEW_WELCOME',      'PRODAIRY', 'new',      null,        'welcome',      'whatsapp', 'pd_welcome',         'First-order incentive', 14),
  ('PD_TIER_PROMOTION',   'PRODAIRY', 'champion', null,        'segment_move', 'whatsapp', 'pd_tier_promotion',  'Tier perks', 30),
  ('PD_LAPSED_REACT',     'PRODAIRY', 'lapsed',   null,        'lapse',        'whatsapp', 'pd_recovery',        'Come-back offer', 30),
  ('PD_CHAMPION_VISIT',   'PRODAIRY', 'champion', null,        'event',        'visit',    null,                 'Recognition, volume bundle', 30)
on conflict (playbook_id) do nothing;

/* ---------- WhatsApp templates (English drafts; Shona added by the
   translator before submission on 29 Sep -- SSOT §9.4) ---------- */
insert into crm.wa_templates (client_id, template_name, language, category, purpose, body_preview, button_labels)
values
  ('PRODAIRY','pd_welcome',         'en','marketing','welcome',
   'Welcome to ProDairy, {{1}}! Your trader code is {{2}}. Show it at the counter on every order. Reply MENU to reorder, see your tier or offers.',
   array['Menu']),
  ('PRODAIRY','pd_reorder_prompt',  'en','utility','usual_day',
   'Hi {{1}}, it''s your usual order day. Reorder your usual {{2}}?',
   array['Yes reorder','Change','Not now']),
  ('PRODAIRY','pd_recovery',        'en','marketing','lapse',
   'Hi {{1}}, we miss you at ProDairy {{2}}. {{3}} Reply to order.',
   array['Reorder','Talk to shop']),
  ('PRODAIRY','pd_order_confirmed', 'en','utility','order_confirmed',
   'Confirmed ✓ Your order {{1}} will be ready for {{2}} on {{3}}.',
   null),
  ('PRODAIRY','pd_tier_promotion',  'en','marketing','segment_move',
   'Congratulations {{1}}! You are now a ProDairy {{2}}. {{3}}',
   array['My tier'])
on conflict (client_id, template_name, language) do nothing;
