#!/usr/bin/env bash
# Run the durable sync tests against a disposable, local PostgreSQL cluster.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
pg_bin="${MCP_SYNC_PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}"
if [[ ! -x "$pg_bin/postgres" ]]; then
  printf '%s\n' 'Set MCP_SYNC_PG_BIN to a PostgreSQL 17+ server bin directory.' >&2
  exit 1
fi
sync_temp="$(mktemp -d /tmp/noizu-mcp-sync.XXXXXX)"
sync_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
cleanup() {
  "$pg_bin/pg_ctl" -D "$sync_temp/data" stop -m fast -w >/dev/null 2>&1 || true
  rm -rf -- "$sync_temp"
}
trap cleanup EXIT
"$pg_bin/initdb" -D "$sync_temp/data" -U sync_admin -A trust --no-locale >"$sync_temp/init.log" 2>&1
"$pg_bin/pg_ctl" -D "$sync_temp/data" -l "$sync_temp/postgres.log" -o "-h 127.0.0.1 -p $sync_port -k ''" start -w >/dev/null
for database in noizu_mcp_sync_cache_test noizu_mcp_sync_source_test; do
  "$pg_bin/createdb" -h 127.0.0.1 -p "$sync_port" -U sync_admin "$database"
done
if [[ "${1:-}" == "--sql-only" ]]; then
  cp "$repo_dir/priv/sql/noizu_mcp_sync.sql" "$sync_temp/schema.sql"
  for database in noizu_mcp_sync_cache_test noizu_mcp_sync_source_test; do
    "$pg_bin/psql" --no-psqlrc -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$sync_port" -U sync_admin -d "$database" -f "$sync_temp/schema.sql"
  done
  printf '%s\n' 'SQL migration loaded successfully in both isolated databases.'
  exit 0
fi
if [[ "${1:-}" == "--liquibase-only" ]]; then
  command -v liquibase >/dev/null
  cd "$repo_dir"
  for pass in first second; do
    if ! liquibase --changelog-file=priv/liquibase/noizu_mcp_sync.yaml \
      --url="jdbc:postgresql://127.0.0.1:$sync_port/noizu_mcp_sync_cache_test" \
      --username=sync_admin update >"$sync_temp/liquibase-$pass.log" 2>&1; then
      tail -40 "$sync_temp/liquibase-$pass.log" >&2
      exit 1
    fi
  done
  changesets="$("$pg_bin/psql" --no-psqlrc -At -h 127.0.0.1 -p "$sync_port" -U sync_admin \
    -d noizu_mcp_sync_cache_test -c 'SELECT count(*) FROM databasechangelog')"
  [[ "$changesets" == "1" ]]
  printf '%s\n' 'Liquibase update applied and second update preserved exactly one tracked changeset.'
  exit 0
fi
export MCP_SYNC_TEST_DATABASE_URL="postgres://sync_admin@127.0.0.1:$sync_port/noizu_mcp_sync_cache_test"
export MCP_SYNC_SOURCE_DATABASE_URL="postgres://sync_admin@127.0.0.1:$sync_port/noizu_mcp_sync_source_test"
export MCP_SYNC_ISOLATED=1 MCP_SKIP_FULL_COVERAGE=1
export MCP_SYNC_PSQL="$pg_bin/psql"
canonical_deps="$(cd "$repo_dir/deps" && pwd -P)"
canonical_repo="$(dirname "$canonical_deps")"
export MIX_DEPS_PATH="${MIX_DEPS_PATH:-$canonical_deps}"
export MIX_BUILD_PATH="${MIX_BUILD_PATH:-$canonical_repo/_build}"
export MIX_ENV=test
cd "$repo_dir"
printf '%s\n' 'Running sync integration tests on isolated PostgreSQL:'
"$pg_bin/postgres" --version
if [[ "$#" -eq 0 ]]; then
  mix test test/noizu/mcp/sync
else
  mix test "$@"
fi
