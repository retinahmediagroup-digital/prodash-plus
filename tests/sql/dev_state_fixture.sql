/* ============================================================
   ProDash+ | tests/sql/dev_state_fixture.sql
   Recreates ProDash+_dev's data as of 27 Sep 2026 (after 00 and 01
   and the first seed), so the upgrade path 02..10 can be tested
   against it: one client, brand, branch, product, six product
   mappings and one walk-in placeholder customer.
   ============================================================ */
insert into gold.dim_client (client_id, client_name, status) values ('PRODAIRY', 'ProDairy', 'active');
insert into gold.dim_brand  (brand_id, client_id, brand_name) values ('LIFE', 'PRODAIRY', 'LIFE');
insert into gold.dim_branch (branch_id, client_id, branch_name, region) values ('HF', 'PRODAIRY', 'Highfield', 'Harare');
insert into gold.dim_product (product_id, client_id, brand_id, product_name, category, pack_size_ml, is_250_ml)
values ('LIFE_250ML', 'PRODAIRY', 'LIFE', 'LIFE 250ml', 'Dairy', 250, true);
insert into gold.ref_product_mapping (client_id, raw_product_name, product_id)
select 'PRODAIRY', n, 'LIFE_250ML'
from unnest(array['life 250','life250','life 250ml','life 250 ml','life 250mls','life 250 mls']) n;
insert into gold.dim_customer (client_id, home_branch_id, walk_in_flag) values ('PRODAIRY', 'HF', true);
