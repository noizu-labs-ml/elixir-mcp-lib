#!/usr/bin/env bash
#
# run-tests.sh — deterministic pg_mcp test runner.
#
# `cargo pgrx test` wraps the same checks in the pgrx-tests framework
# (initdb → CREATE EXTENSION → SELECT tests.<probe>()), but its framework
# misbehaves on some machines (the CREATE EXTENSION step and the probe queries
# end up against different state, so every probe reports "does not exist").
# This script performs the identical flow explicitly, so it can be watched and
# trusted:
#
#   1. build the crate (pg_test features, same flags as `cargo pgrx test`)
#   2. generate the extension SQL (including the tests.* probe functions)
#   3. initdb a throwaway cluster under target/, start it on a free port
#   4. replay the SQL (with MODULE_PATHNAME resolved to the built dylib)
#   5. run every tests.* probe; any SQL error counts as a failure
#
# Usage: ./run-tests.sh [--keep]      (--keep leaves the cluster running)
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")" && pwd)"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
TOOLCHAIN="${TOOLCHAIN:-}"    # e.g. +1.98.1; empty = default
KEEP="${1:-}"

WORK="$CRATE_DIR/target/testrunner"
SOCK="/tmp/pg_mcp_test_sock.$$"
PORT="${PORT:-$(( (RANDOM % 20000) + 30000 ))}"

cd "$CRATE_DIR"

echo "== building (pg_test, pg${PG_MAJOR:-18})"
# shellcheck disable=SC2086
cargo $TOOLCHAIN build --lib --quiet --no-default-features --features "pg${PG_MAJOR:-18} pg_test"

echo "== generating extension SQL"
mkdir -p "$WORK"
# shellcheck disable=SC2086
cargo $TOOLCHAIN pgrx schema --no-default-features --features "pg${PG_MAJOR:-18} pg_test" \
  > "$WORK/pg_mcp--0.1.0.sql" 2>"$WORK/schema.log"
sed -i '' "s|'MODULE_PATHNAME'|'\$libdir/pg_mcp'|g" "$WORK/pg_mcp--0.1.0.sql"

DYLIB=$(find "$CRATE_DIR/target" -maxdepth 3 -name "libpg_mcp.dylib" -newer "$WORK/schema.log" 2>/dev/null | head -1)
[ -z "$DYLIB" ] && DYLIB=$(find "$CRATE_DIR/target" -maxdepth 3 -name "libpg_mcp.dylib" | head -1)
if [ -z "$DYLIB" ]; then
  echo "FATAL: built dylib not found" >&2
  exit 1
fi
cp "$DYLIB" "$WORK/pg_mcp.dylib"

echo "== initdb + start on port $PORT"
rm -rf "$WORK/data" "$SOCK"
mkdir -p "$SOCK"
"$PGBIN/initdb" --locale=C --lc-ctype=UTF-8 -D "$WORK/data" > "$WORK/initdb.log" 2>&1
cat >> "$WORK/data/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '$SOCK'
dynamic_library_path = '$WORK'
listen_addresses = ''
EOF
"$PGBIN/pg_ctl" -D "$WORK/data" -l "$WORK/postgres.log" start -w > /dev/null

cleanup() {
  if [ "$KEEP" != "--keep" ]; then
    "$PGBIN/pg_ctl" -D "$WORK/data" stop -m fast > /dev/null 2>&1 || true
    rm -rf "$WORK/data" "$SOCK"
  fi
}
trap cleanup EXIT

echo "== installing extension"
"$PGBIN/createdb" -h "$SOCK" -p "$PORT" pgrx_tests
if ! "$PGBIN/psql" -X -q -h "$SOCK" -p "$PORT" -d pgrx_tests -v ON_ERROR_STOP=1 \
     -f "$WORK/pg_mcp--0.1.0.sql" > "$WORK/install.log" 2>&1; then
  echo "FATAL: extension SQL failed — see $WORK/install.log" >&2
  tail -20 "$WORK/install.log" >&2
  exit 1
fi

echo "== running test probes"
PASS=0
FAIL=0
FAILED_NAMES=()
# Probe names come from the generated SQL: CREATE  FUNCTION tests."name"()
PROBES=$(grep -oE 'CREATE +FUNCTION tests\."[^"]+"' "$WORK/pg_mcp--0.1.0.sql" \
  | sed -E 's/.*tests\."([^"]+)".*/\1/' | sort -u)

for name in $PROBES; do
  if "$PGBIN/psql" -X -q -h "$SOCK" -p "$PORT" -d pgrx_tests -v ON_ERROR_STOP=1 \
       -c "SELECT tests.\"$name\"();" > /dev/null 2>"$WORK/last.err"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "FAIL: $name"
    sed 's/^/      /' "$WORK/last.err" | head -4
  fi
done

echo
echo "test result: $PASS passed; $FAIL failed; total $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
