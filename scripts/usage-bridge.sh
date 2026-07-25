#!/usr/bin/env bash
# Connects Perch to Claude Code's subscription quota.
#
#   ./scripts/usage-bridge.sh            # install
#   ./scripts/usage-bridge.sh --remove   # reverse it
#   ./scripts/usage-bridge.sh --status   # what is installed right now
#
# Claude Code publishes `rate_limits` exactly once: on the stdin it hands to the statusline
# command, every render. There is no other local source. So the only way to read it is to
# sit in front of that command — which means being extremely careful not to change what the
# user sees.
#
# The bridge reads stdin once, caches `.rate_limits`, then replays the identical bytes to
# the original command. Your statusline output is unchanged, and removing the bridge
# restores the original command verbatim.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

SETTINGS="$HOME/.claude/settings.json"
BRIDGE="$PERCH_HOME/bin/perch-statusline"
ORIGINAL="$PERCH_HOME/statusline-original.json"
CACHE="$PERCH_HOME/cache/rate-limits.json"

current_command() {
  [ -f "$SETTINGS" ] || return 0
  jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null
}

status() {
  local command
  command="$(current_command)"
  if [ -z "$command" ]; then
    info "statusLine: none configured"
  elif [ "$command" = "$BRIDGE" ]; then
    ok "bridge installed"
    [ -f "$ORIGINAL" ] && info "wrapping: $(jq -r '.command // "(nothing)"' "$ORIGINAL")"
  else
    info "statusLine: $command"
    info "bridge not installed"
  fi
  if [ -f "$CACHE" ]; then
    ok "quota cache present ($(wc -c <"$CACHE" | tr -d ' ') bytes)"
  else
    warn "no quota seen yet — render a statusline in any Claude Code session"
  fi
}

remove() {
  [ -f "$SETTINGS" ] || { info "nothing to remove"; return 0; }
  local command
  command="$(current_command)"
  [ "$command" = "$BRIDGE" ] || { info "bridge not installed — nothing to remove"; return 0; }

  local backup="$SETTINGS.perch-statusline-backup.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$backup"

  if [ -f "$ORIGINAL" ] && [ "$(jq -r '.command // empty' "$ORIGINAL")" != "" ]; then
    # Put the user's own statusLine object back exactly as it was.
    jq --slurpfile original "$ORIGINAL" '.statusLine = $original[0]' "$SETTINGS" >"$SETTINGS.tmp"
  else
    jq 'del(.statusLine)' "$SETTINGS" >"$SETTINGS.tmp"
  fi

  jq empty "$SETTINGS.tmp" 2>/dev/null || fail "produced invalid JSON — original left untouched"
  mv "$SETTINGS.tmp" "$SETTINGS"
  rm -f "$BRIDGE" "$ORIGINAL"
  ok "bridge removed, original statusLine restored"
  info "backup at $backup"
}

install() {
  mkdir -p "$(dirname "$BRIDGE")" "$(dirname "$CACHE")" "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"

  local command
  command="$(current_command)"
  if [ "$command" = "$BRIDGE" ]; then
    ok "bridge already installed"
    return 0
  fi

  # Remember the whole statusLine object, not just the command: padding and
  # refreshInterval are the user's settings too.
  jq '.statusLine // {}' "$SETTINGS" >"$ORIGINAL"

  cat >"$BRIDGE" <<'BRIDGE_SCRIPT'
#!/bin/sh
# Perch statusline bridge (managed — remove with scripts/usage-bridge.sh --remove).
#
# Reads Claude Code's stdin once, caches `rate_limits`, then replays the identical bytes
# to the original statusline command so its output is byte-for-byte what it was.
PERCH_HOME="${PERCH_HOME:-$HOME/.perch}"
CACHE="$PERCH_HOME/cache/rate-limits.json"
ORIGINAL="$PERCH_HOME/statusline-original.json"
STDIN_FILE="${TMPDIR:-/tmp}/perch-statusline-stdin.$$"

cleanup() { rm -f "$STDIN_FILE"; }
trap cleanup EXIT HUP INT TERM

cat >"$STDIN_FILE"

# Caching must never be able to break the statusline: everything here is best-effort.
if command -v jq >/dev/null 2>&1; then
  _limits=$(jq -c '{rate_limits, rate_limits_available}' <"$STDIN_FILE" 2>/dev/null)
  if [ -n "$_limits" ] && [ "$_limits" != "null" ]; then
    mkdir -p "$(dirname "$CACHE")" 2>/dev/null
    # Write then move, so a reader never sees half a file.
    printf '%s\n' "$_limits" >"$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE" 2>/dev/null
  fi
fi

_command=""
if [ -f "$ORIGINAL" ] && command -v jq >/dev/null 2>&1; then
  _command=$(jq -r '.command // empty' "$ORIGINAL" 2>/dev/null)
fi

# No original statusline: the user had none, so print nothing and keep it that way.
[ -n "$_command" ] || exit 0

exec /bin/sh -c "$_command" <"$STDIN_FILE"
BRIDGE_SCRIPT
  chmod +x "$BRIDGE"

  local backup="$SETTINGS.perch-statusline-backup.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$backup"

  jq --arg bin "$BRIDGE" '
    .statusLine = ((.statusLine // {}) + {type: "command", command: $bin})
  ' "$backup" >"$SETTINGS.tmp"

  jq empty "$SETTINGS.tmp" 2>/dev/null || fail "produced invalid JSON — original left untouched"
  mv "$SETTINGS.tmp" "$SETTINGS"

  ok "usage bridge installed"
  info "wrapping: $(jq -r '.command // "(nothing — you had no statusline)"' "$ORIGINAL")"
  info "backup at $backup"
  warn "restart any open Claude Code session — statusLine is read at session start"
  info "remove with: ./scripts/usage-bridge.sh --remove"
}

case "${1:-}" in
  --remove) remove ;;
  --status) status ;;
  "") install ;;
  *) fail "usage: usage-bridge.sh [--remove|--status]" ;;
esac
