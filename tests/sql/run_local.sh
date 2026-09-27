#!/usr/bin/env bash
# ProDash+ | tests/sql/run_local.sh
# Tests sql/00..10 + seed on a THROWAWAY local Postgres. Never point
# this at Supabase.
#
#   Scenario A  fresh install (as ProDash+_pro will be built), then a
#               full re-run to prove every file is safe to re-run.
#   Scenario B  upgrade: ProDash+_dev's current state (00, 01 and its
#               data, including the walk-in placeholder) + 02..10.
#   Each scenario then runs the assertions.
#
#   PGHOST=/path/to/socket PGPORT=55432 tests/sql/run_local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${TEST_DB:-prodash_test}"
export PGUSER="${PGUSER:-postgres}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

run() { PGOPTIONS="-c client_min_messages=warning" "${PSQL[@]}" -f "$1"; }

fresh_db() {
  dropdb --if-exists "$DB"
  createdb "$DB"
  run "$ROOT/tests/sql/supabase_shim.sql"
}

apply_from() {  # apply numbered files >= $1, then the seed
  for f in "$ROOT"/sql/[0-9][0-9]_*.sql; do
    n=$(basename "$f" | cut -c1-2)
    if [ "$n" -ge "$1" ]; then echo "  $(basename "$f")"; run "$f"; fi
  done
  echo "  seed/seed_prodairy.sql"
  run "$ROOT/sql/seed/seed_prodairy.sql"
}

assertions() {
  PGOPTIONS="-c client_min_messages=notice" "${PSQL[@]}" -f "$ROOT/tests/sql/test_base_schema.sql" 2>&1 \
    | sed -e 's/^psql:[^ ]* NOTICE:  /  /'
}

echo "== Scenario A: fresh install"
fresh_db
apply_from 0
echo "-- re-run everything"
apply_from 0
assertions

echo "== Scenario B: upgrade ProDash+_dev (00, 01 + current data) with 02..10"
fresh_db
run "$ROOT/sql/00_init_schemas.sql"
run "$ROOT/sql/01_dimensions.sql"
run "$ROOT/tests/sql/dev_state_fixture.sql"
apply_from 2
PGOPTIONS="-c client_min_messages=warning" "${PSQL[@]}" -tAc \
  "select 'walk-in rows left: ' || count(*) from gold.dim_customer; select 'PRODAIRY prefix: ' || code_prefix from gold.dim_client where client_id = 'PRODAIRY';"
assertions
