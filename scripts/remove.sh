#!/usr/bin/env bash
# Uninstalls Perch and puts the machine back the way it was.
#
# Prints what it would do and changes nothing unless --yes is passed.
#
#   ./scripts/remove.sh              # dry run
#   ./scripts/remove.sh --yes        # do it
#   ./scripts/remove.sh --yes --keep-db --keep-data
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
KEEP_DB=0
KEEP_DATA=0

for argument in "$@"; do
  case "$argument" in
  --yes | -y) APPLY=1 ;;
  --keep-db) KEEP_DB=1 ;;
  --keep-data) KEEP_DATA=1 ;;
  -h | --help)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) fail "unknown option: $argument" ;;
  esac
done

if [ "$APPLY" -eq 0 ]; then
  warn "dry run — nothing will be changed. Re-run with --yes to apply."
fi
echo

# Prefixes every line so a dry run reads unambiguously.
act() {
  if [ "$APPLY" -eq 1 ]; then
    info "$1"
    return 0
  fi
  printf '\033[90m  would %s\033[0m\n' "$1"
  return 1
}

# --- 1. Stop the app -------------------------------------------------------------

if pgrep -x Perch >/dev/null 2>&1; then
  if act "quit Perch (pid $(pgrep -x Perch | tr '\n' ' '))"; then
    pkill -x Perch || true
    sleep 1
  fi
else
  ok "Perch is not running"
fi

LAUNCH_AGENT="$HOME/Library/LaunchAgents/tech.kweli.perch.plist"
if [ -f "$LAUNCH_AGENT" ]; then
  if act "unload and remove launch agent $LAUNCH_AGENT"; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
  fi
else
  ok "no launch agent installed"
fi

# --- 2. Remove Perch hooks from Claude Code settings -----------------------------
#
# Only entries whose command mentions perch-hook are dropped. Every other hook in the
# file — including ones that were there before Perch — is left untouched, and the file
# is backed up before being rewritten.

# jq strips our hook commands, then prunes groups and events left empty.
STRIP_HOOKS='
  if has("hooks") then
    .hooks |= (
      with_entries(
        .value |= (
          map(.hooks |= map(select(((.command // "") | contains("perch-hook")) | not)))
          | map(select((.hooks | length) > 0))
        )
      )
      | with_entries(select((.value | length) > 0))
    )
    | if (.hooks | length) == 0 then del(.hooks) else . end
  else . end
'

hook_sites() {
  # Sites Perch recorded when it installed hooks, plus the global settings, which we
  # always check even if the registry is missing.
  {
    if [ -f "$PERCH_HOME/hook-sites.json" ]; then
      jq -r '.[]? // empty' "$PERCH_HOME/hook-sites.json" 2>/dev/null || true
    fi
    echo "$HOME/.claude/settings.json"
    echo "$HOME/.claude/settings.local.json"
  } | sort -u
}

command -v jq >/dev/null 2>&1 || fail "jq is required to clean hook entries"

FOUND_HOOKS=0
while IFS= read -r settings; do
  [ -f "$settings" ] || continue
  grep -q 'perch-hook' "$settings" 2>/dev/null || continue
  FOUND_HOOKS=1
  if act "remove Perch hooks from $settings (backup: $settings.perch-backup)"; then
    cp "$settings" "$settings.perch-backup"
    tmp="$(mktemp)"
    jq "$STRIP_HOOKS" "$settings" >"$tmp"
    # Never leave a truncated settings file behind.
    if jq empty "$tmp" 2>/dev/null; then
      mv "$tmp" "$settings"
      ok "cleaned $settings"
    else
      rm -f "$tmp"
      warn "skipped $settings — result was not valid JSON, original left in place"
    fi
  fi
done < <(hook_sites)

[ "$FOUND_HOOKS" -eq 0 ] && ok "no Perch hooks found in any settings.json"

# --- 2b. Statusline bridge -------------------------------------------------------
#
# Must run before local data is deleted: the original statusLine command is remembered
# in ~/.perch, and without it the bridge cannot be reversed.

if grep -q 'perch-statusline' "$HOME/.claude/settings.json" 2>/dev/null; then
  if act "restore the original statusLine (Perch usage bridge)"; then
    "$(dirname "${BASH_SOURCE[0]}")/usage-bridge.sh" --remove || warn "could not remove the usage bridge"
  fi
else
  ok "no Perch usage bridge installed"
fi

# --- 2c. Editor extension --------------------------------------------------------

# A loop, not one `ls` over a brace expansion: `ls` fails as soon as *any* path is
# missing, so it reported "not installed" whenever one of the four editors was absent.
EXTENSION_FOUND=0
for dir in "$HOME"/.vscode "$HOME"/.vscode-insiders "$HOME"/.cursor "$HOME"/.windsurf; do
  for installed in "$dir"/extensions/kweli.perch-jump-*; do
    [ -d "$installed" ] && EXTENSION_FOUND=1
  done
done

if [ "$EXTENSION_FOUND" -eq 1 ]; then
  if act "remove the Perch editor extension"; then
    "$(dirname "${BASH_SOURCE[0]}")/install-extension.sh" --remove || true
  fi
else
  ok "no Perch editor extension installed"
fi

# --- 2d. kitty configuration -----------------------------------------------------

KITTY_CONF="${KITTY_CONFIG_DIRECTORY:-$HOME/.config/kitty}/kitty.conf"
if grep -q '>>> perch >>>' "$KITTY_CONF" 2>/dev/null; then
  if act "remove Perch's block from kitty.conf"; then
    "$(dirname "${BASH_SOURCE[0]}")/configure-kitty.sh" --remove || true
  fi
else
  ok "no Perch block in kitty.conf"
fi

# --- 3. Local data ---------------------------------------------------------------

if [ "$KEEP_DATA" -eq 1 ]; then
  warn "keeping local data (--keep-data)"
else
  for path in "$PERCH_HOME" "$PERCH_SUPPORT"; do
    if [ -e "$path" ]; then
      act "delete $path" && rm -rf "$path"
    else
      ok "already absent: $path"
    fi
  done
fi

# --- 4. Database -----------------------------------------------------------------
#
# Drops exactly one database inside a container shared with other projects. Every other
# database in `infra-postgres` must survive this script.

if [ "$KEEP_DB" -eq 1 ]; then
  warn "keeping database '$PG_DATABASE' (--keep-db)"
elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
  warn "container '$PG_CONTAINER' is not running — skipping database"
elif ! database_exists; then
  ok "database '$PG_DATABASE' does not exist"
else
  if [ "$APPLY" -eq 1 ]; then
    warn "about to DROP DATABASE \"$PG_DATABASE\" in container '$PG_CONTAINER'"
    read -r -p "  type the database name to confirm: " confirmation
    if [ "$confirmation" = "$PG_DATABASE" ]; then
      psql_admin -c "DROP DATABASE \"$PG_DATABASE\" WITH (FORCE)" >/dev/null
      ok "dropped database '$PG_DATABASE'"
    else
      warn "confirmation did not match — database kept"
    fi
  else
    printf '\033[90m  would DROP DATABASE "%s" in %s (with confirmation)\033[0m\n' \
      "$PG_DATABASE" "$PG_CONTAINER"
  fi
fi

# --- 5. Build artefacts ----------------------------------------------------------

for path in \
  "$PERCH_ROOT/apps/mac/build.noindex" \
  "$PERCH_ROOT/apps/mac/build" \
  "$PERCH_ROOT/apps/mac/.build" \
  "$PERCH_ROOT/apps/api/node_modules"; do
  if [ -e "$path" ]; then
    act "delete $path" && rm -rf "$path"
  fi
done

echo
if [ "$APPLY" -eq 1 ]; then
  ok "Perch removed"
else
  warn "dry run finished — re-run with --yes to apply"
fi
