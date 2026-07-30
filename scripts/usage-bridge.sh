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
#
# Every session renders through the same bridge into the same cache, and the numbers a
# session sends are the ones its own last API response carried — so a session idle since
# yesterday renders yesterday's quota, right now. Writing unconditionally means the last
# writer wins, and the last writer may be the stalest session: a cache file four seconds
# old holding a week that reset hours ago. So the bridge only writes forward.
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

  # Already pointing here is not a reason to stop: the shim is a managed file, and a run
  # that returned early would leave every machine on whichever version of it was installed
  # first. So it is rewritten every time, and only the settings work is skipped.
  local command already=0
  command="$(current_command)"
  if [ "$command" = "$BRIDGE" ]; then already=1; fi

  # Remember the whole statusLine object, not just the command: padding and
  # refreshInterval are the user's settings too. Not when the bridge is already installed —
  # recording it as its own original is how a statusline ends up calling itself.
  if [ "$already" = 0 ]; then
    jq '.statusLine // {}' "$SETTINGS" >"$ORIGINAL"
  fi

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
    # Only ever write forward. A render carries no timestamp of its own, but every window
    # carries the instant it resets, and that instant moves with the window — so the latest
    # `resets_at` in a payload dates the observation well enough to tell an idle session's
    # old snapshot from a current one. Nothing to compare against, or jq choking on a
    # corrupt cache: write, which is what this did before the comparison existed.
    _write=1
    if [ -f "$CACHE" ]; then
      _write=$(printf '%s' "$_limits" | jq --slurpfile cached "$CACHE" --argjson now "$(date +%s)" '
        def stamps: [ (.rate_limits // {}) | .. | objects | .resets_at? | select(. != null)
                      | if type == "number" then . else (fromdateiso8601? // 0) end ];
        def freshness: (stamps | max) // 0;
        # A cache whose every window has already reset is spent, and anything beats it —
        # without that, one stale file could block every later write for ever.
        if (freshness >= ($cached[0] | freshness)) or (($cached[0] | freshness) <= $now)
        then 1 else 0 end' 2>/dev/null) || _write=1
      [ -n "$_write" ] || _write=1
    fi
    if [ "$_write" != "0" ]; then
      mkdir -p "$(dirname "$CACHE")" 2>/dev/null
      # Write then move, so a reader never sees half a file — under a name of our own, so
      # two sessions rendering at the same moment cannot share one temporary.
      _tmp="$CACHE.$$.tmp"
      printf '%s\n' "$_limits" >"$_tmp" 2>/dev/null && mv "$_tmp" "$CACHE" 2>/dev/null
      rm -f "$_tmp" 2>/dev/null
    fi
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

  if [ "$already" = 1 ]; then
    ok "bridge already installed — shim refreshed"
    info "wrapping: $(jq -r '.command // "(nothing — you had no statusline)"' "$ORIGINAL")"
    return 0
  fi

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
