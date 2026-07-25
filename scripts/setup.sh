#!/usr/bin/env bash
# Creates the `perch` database inside the existing shared Postgres container and
# applies migrations. Safe to re-run.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_container

if database_exists; then
  ok "database '$PG_DATABASE' already exists in '$PG_CONTAINER'"
else
  info "creating database '$PG_DATABASE' in '$PG_CONTAINER'"
  psql_admin -c "CREATE DATABASE \"$PG_DATABASE\"" >/dev/null
  ok "database created"
fi

API_DIR="$PERCH_ROOT/apps/api"
if [ -f "$API_DIR/package.json" ]; then
  command -v bun >/dev/null 2>&1 || fail "bun not found"
  info "installing api dependencies"
  (cd "$API_DIR" && bun install --silent)
  if [ -d "$API_DIR/drizzle" ]; then
    info "applying migrations"
    (cd "$API_DIR" && DATABASE_URL="$DATABASE_URL" bun run db:migrate)
    ok "migrations applied"
  else
    warn "no migrations yet — skipping"
  fi
else
  warn "apps/api not built yet — database is ready for it"
fi

echo
ok "setup complete"
echo "  DATABASE_URL=$DATABASE_URL"
