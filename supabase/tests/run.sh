#!/usr/bin/env bash
# Applies the migrations to a throwaway local Postgres cluster (with a stub `auth` schema) and runs the
# SQL assertions. Needs Postgres 14+ binaries; set PG_BIN if they are not on PATH.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
PG_BIN="${PG_BIN:-$(dirname "$(command -v initdb 2>/dev/null || echo /opt/homebrew/opt/postgresql@14/bin/initdb)")}"
port="${PGPORT:-54329}"
dir="$(mktemp -d)"
trap '"$PG_BIN/pg_ctl" -D "$dir/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$dir"' EXIT

"$PG_BIN/initdb" -D "$dir/data" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
"$PG_BIN/pg_ctl" -D "$dir/data" -o "-p $port -k $dir -c listen_addresses=''" -l "$dir/log" -w start >/dev/null

psql_run() { "$PG_BIN/psql" -h "$dir" -p "$port" -U postgres -d tab -v ON_ERROR_STOP=1 -q "$@"; }
"$PG_BIN/createdb" -h "$dir" -p "$port" -U postgres tab

psql_run -f "$here/00_auth_stub.sql"
for migration in "$here"/../migrations/*.sql; do psql_run -f "$migration"; done
psql_run -f "$here/rls_and_rpc.test.sql"
echo "supabase SQL tests passed"
