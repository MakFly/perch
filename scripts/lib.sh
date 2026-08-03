#!/usr/bin/env bash
# Shared settings for setup.sh and remove.sh.

# Perch reuses the already-running shared Postgres container rather than starting its
# own. That container hosts one database per project; Perch adds exactly one.
PG_CONTAINER="${PERCH_PG_CONTAINER:-infra-postgres}"
PG_USER="${PERCH_PG_USER:-test}"
PG_PASSWORD="${PERCH_PG_PASSWORD:-test}"
PG_HOST="${PERCH_PG_HOST:-localhost}"
PG_PORT="${PERCH_PG_PORT:-5432}"
PG_DATABASE="${PERCH_PG_DATABASE:-perch}"
# Connecting to an admin database to create/drop ours.
PG_ADMIN_DATABASE="${PERCH_PG_ADMIN_DATABASE:-postgres}"

PERCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERCH_HOME="$HOME/.perch"
PERCH_SUPPORT="$HOME/Library/Application Support/Perch"

# Where the app is — and these scripts run from two places.
#
# In a clone, from `scripts/`, next to the bundle `make-app.sh` builds. In a shipped copy
# they are inside that bundle, at `Contents/Resources/scripts`, wherever the user dragged
# it — so the app to wire up is the one two directories above, and deriving it from the
# repository layout instead would point at a path that does not exist. `PERCH_APP` stays
# overridable for the case neither guess fits.
case "$PERCH_ROOT" in
  */Contents/Resources)
    PERCH_APP="${PERCH_APP:-$(cd "$PERCH_ROOT/../.." && pwd)}"
    ;;
  *)
    PERCH_APP="${PERCH_APP:-$PERCH_ROOT/apps/mac/build.noindex/Perch.app}"
    ;;
esac

DATABASE_URL="postgresql://$PG_USER:$PG_PASSWORD@$PG_HOST:$PG_PORT/$PG_DATABASE"

info() { printf '\033[36m›\033[0m %s\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
fail() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

require_container() {
  command -v docker >/dev/null 2>&1 || fail "docker not found"
  docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" ||
    fail "container '$PG_CONTAINER' is not running (start it, or set PERCH_PG_CONTAINER)"
}

# Runs psql inside the shared container, against the admin database.
psql_admin() {
  docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$PG_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_ADMIN_DATABASE" "$@"
}

database_exists() {
  local found
  found="$(psql_admin -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$PG_DATABASE'" 2>/dev/null || true)"
  [ "$found" = "1" ]
}
