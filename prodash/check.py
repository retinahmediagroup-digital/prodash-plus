"""Check the local setup:  python -m prodash.check"""

import sys

import requests

from prodash.config import settings
from prodash.db import read_sql


def main() -> int:
    ok = True
    s = settings()

    who = read_sql("""select current_user as db_user,
                             (select rolbypassrls from pg_roles where rolname = current_user) as bypass_rls,
                             current_setting('server_version') as postgres""").iloc[0]
    print(f"database : connected as {who.db_user} (Postgres {who.postgres})")
    if who.db_user == "postgres":
        print("  warning: connected as postgres. Use etl_worker (sql/13_etl_role.sql).")
    if not who.bypass_rls:
        print("  ERROR: this user cannot bypass RLS, so backend tables will look empty.")
        ok = False

    counts = read_sql("""select (select count(*) from gold.dim_branch where client_id = %(c)s) as branches,
                                (select count(*) from gold.ref_product_mapping where client_id = %(c)s) as product_names,
                                (select count(*) from ops.load_log where client_id = %(c)s) as loads,
                                (select count(*) from bronze.receipts_raw where client_id = %(c)s) as bronze_rows""",
                      {"c": s.client_id}).iloc[0]
    print(f"client   : {s.client_id} - {counts.branches} branches, {counts.product_names} product names, "
          f"{counts.loads} loads, {counts.bronze_rows} bronze rows")

    if s.supabase_url and s.service_key:
        resp = requests.get(f"{s.supabase_url.rstrip('/')}/storage/v1/bucket/{s.bucket}",
                            headers={"Authorization": f"Bearer {s.service_key}", "apikey": s.service_key},
                            timeout=30)
        if resp.ok:
            print(f"storage  : bucket {s.bucket} reachable (public={resp.json().get('public')})")
        else:
            print(f"storage  : ERROR {resp.status_code} {resp.text[:200]}")
            ok = False
    else:
        print("storage  : skipped (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set)")

    print("OK" if ok else "Fix the errors above.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
