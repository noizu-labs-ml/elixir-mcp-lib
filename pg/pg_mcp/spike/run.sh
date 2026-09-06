#!/usr/bin/env bash
#
# run.sh — PRD-6 §7.5 go/no-go spike (S1..S4) + AC-6.1…AC-6.8 hand checks.
#
# Boots Noizu.MCP.Fixtures.Server behind two Bandit listeners (open + bearer
# auth), installs the freshly built pg_mcp extension into a throwaway Postgres
# cluster / database `pg_mcp_spike`, runs spike/checks.sql, measures latency,
# verifies the pg_dump round-trip (AC-6.8), then tears everything down.
#
# Usage: spike/run.sh
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
CRATE_DIR="$(dirname "$SPIKE_DIR")"
REPO_ROOT="$(cd "$CRATE_DIR/../.." && pwd)"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"

WORK="$CRATE_DIR/target/spike"
SOCK="/tmp/pg_mcp_spike_sock.$$"
PORT="${PORT:-$(( (RANDOM % 20000) + 30000 ))}"
DB="pg_mcp_spike"
DB_RESTORE="pg_mcp_spike_restore"

FAILURES=0

note() { echo; echo "== $*"; }

cleanup() {
  "$PGBIN/pg_ctl" -D "$WORK/data" stop -m fast > /dev/null 2>&1 || true
  [ -n "${EXE_PID:-}" ] && kill "$EXE_PID" > /dev/null 2>&1 || true
  rm -rf "$WORK" "$SOCK"
}
trap cleanup EXIT

# ── 1. boot the fixture MCP servers ──────────────────────────────────────────
mkdir -p "$WORK"
note "booting fixture MCP servers (mix run spike/server.exs)"
cd "$REPO_ROOT"
EXE_OUT="$WORK/elixir.out"
rm -f "$EXE_OUT"
# test/support (the fixtures) only compiles in :test env — hence MIX_ENV=test.
MIX_ENV=test mix run "$SPIKE_DIR/server.exs" > "$EXE_OUT" 2>"$WORK/elixir.err" &
EXE_PID=$!

PORTS=""
for _ in $(seq 1 150); do
  grep -q SPIKE_PORTS "$EXE_OUT" 2>/dev/null && break
  kill -0 "$EXE_PID" 2>/dev/null || break
  sleep 0.2
done
PORTS=$(grep -oE 'SPIKE_PORTS \{.*\}' "$EXE_OUT" | head -1 | sed 's/^SPIKE_PORTS //')
if [ -z "$PORTS" ]; then
  echo "FATAL: fixture servers did not boot — see $WORK/elixir.err" >&2
  tail -20 "$WORK/elixir.err" >&2
  exit 1
fi
OPEN_PORT=$(echo "$PORTS" | sed -E 's/.*"open":([0-9]+).*/\1/')
AUTH_PORT=$(echo "$PORTS" | sed -E 's/.*"auth":([0-9]+).*/\1/')
BLACKHOLE_PORT=$(echo "$PORTS" | sed -E 's/.*"blackhole":([0-9]+).*/\1/')
echo "fixture listeners: open=127.0.0.1:$OPEN_PORT auth=127.0.0.1:$AUTH_PORT blackhole=127.0.0.1:$BLACKHOLE_PORT"

# ── 2. build the extension ───────────────────────────────────────────────────
note "building pg_mcp"
cd "$CRATE_DIR"
cargo build --lib --quiet --no-default-features --features "pg18 pg_test"
cargo pgrx schema --no-default-features --features "pg18 pg_test" \
  > "$WORK/pg_mcp--0.1.0.sql" 2>/dev/null
sed -i '' "s|'MODULE_PATHNAME'|'\$libdir/pg_mcp'|g" "$WORK/pg_mcp--0.1.0.sql"
DYLIB=$(find "$CRATE_DIR/target" -maxdepth 3 -name "libpg_mcp.dylib" | head -1)
cp "$DYLIB" "$WORK/pg_mcp.dylib"

# ── 3. throwaway cluster + pg_mcp_spike database ─────────────────────────────
note "creating throwaway cluster (port $PORT) + database $DB"
rm -rf "$WORK/data"
mkdir -p "$SOCK"
"$PGBIN/initdb" --locale=C --lc-ctype=UTF-8 -D "$WORK/data" > "$WORK/initdb.log" 2>&1
cat >> "$WORK/data/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '$SOCK'
dynamic_library_path = '\$libdir:$WORK'
listen_addresses = ''
EOF
"$PGBIN/pg_ctl" -D "$WORK/data" -l "$WORK/postgres.log" start -w > /dev/null
"$PGBIN/createdb" -h "$SOCK" -p "$PORT" "$DB"

PSQL=("$PGBIN/psql" -X -q -h "$SOCK" -p "$PORT" -d "$DB" -v ON_ERROR_STOP=1)

"${PSQL[@]}" -f "$WORK/pg_mcp--0.1.0.sql" > /dev/null

"${PSQL[@]}" <<SQL > "$WORK/servers.log"
CREATE SERVER spike FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (url 'http://127.0.0.1:$OPEN_PORT/', auth 'none');
CREATE SERVER spike_auth FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (url 'http://127.0.0.1:$AUTH_PORT/');
CREATE USER MAPPING FOR CURRENT_USER SERVER spike_auth
  OPTIONS (token 'mcp_live_spike_a');
CREATE SERVER spike_auth_bad FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (url 'http://127.0.0.1:$AUTH_PORT/');
CREATE USER MAPPING FOR CURRENT_USER SERVER spike_auth_bad
  OPTIONS (token 'mcp_live_wrong');
CREATE SERVER spike_timeout FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (url 'http://127.0.0.1:$BLACKHOLE_PORT/mcp', timeout_ms '1000', auth 'none');
SQL

# ── 4. run the checks ────────────────────────────────────────────────────────
note "running spike checks"
"${PSQL[@]}" -f "$SPIKE_DIR/checks.sql" | tee "$WORK/checks.out"
grep -q FAIL "$WORK/checks.out" && FAILURES=$((FAILURES + 1)) || true

# FR-6.12 wall clock: the timeout query must fail within ~timeout_ms + 500ms.
note "FR-6.12 wall-clock timeout measurement"
T0=$(perl -MTime::HiRes=time -e 'print time')
STATE=$("${PSQL[@]}" -t -A -c "SELECT spike_sqlstate('SELECT mcp.call_tool(''spike_timeout'',''echo'',''{}'')')")
T1=$(perl -MTime::HiRes=time -e 'print time')
ELAPSED=$(perl -e "printf '%.0f', ($T1 - $T0) * 1000")
echo "timeout state=$STATE elapsed=${ELAPSED}ms (budget: 1000ms + 500ms = 1500ms)"
{ [ "$STATE" = "08006" ] && [ "$ELAPSED" -le 1500 ]; } || FAILURES=$((FAILURES + 1))

# ── 5. AC-6.8 pg_dump / restore round trip ───────────────────────────────────
note "AC-6.8 pg_dump -> restore -> options re-validate"
"$PGBIN/pg_dump" -h "$SOCK" -p "$PORT" "$DB" > "$WORK/spike.dump"
"$PGBIN/createdb" -h "$SOCK" -p "$PORT" "$DB_RESTORE"
if "$PGBIN/psql" -X -q -h "$SOCK" -p "$PORT" -d "$DB_RESTORE" -v ON_ERROR_STOP=1 \
     -f "$WORK/spike.dump" > /dev/null 2>&1 &&
   "$PGBIN/psql" -X -h "$SOCK" -p "$PORT" -d "$DB_RESTORE" -t -A -c \
     "SELECT mcp.version()" | grep -q "0.1.0"; then
  echo "PASS AC-6.8 dump/restore round-trip revalidates options"
else
  echo "FAIL AC-6.8"
  FAILURES=$((FAILURES + 1))
fi

# ── 6. teardown ──────────────────────────────────────────────────────────────
note "teardown"
"$PGBIN/dropdb" -h "$SOCK" -p "$PORT" "$DB_RESTORE" 2>/dev/null || true
"$PGBIN/dropdb" -h "$SOCK" -p "$PORT" "$DB" 2>/dev/null || true

if [ "$FAILURES" -eq 0 ]; then
  echo
  echo "SPIKE RESULT: GO"
else
  echo
  echo "SPIKE RESULT: $FAILURES check group(s) failed — see above"
  exit 1
fi
