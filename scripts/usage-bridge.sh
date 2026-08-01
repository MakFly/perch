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
# Every session renders through the same bridge, and the numbers a session sends are the
# ones its own last API response carried — so a session idle since yesterday renders
# yesterday's quota, right now. Into one file that means the last writer wins, and the last
# writer may be the stalest session. Measured on a machine with three sessions open: the
# cache cycled 43% → 20% → 10% every ten seconds, all three for the same account and the
# same window, because each idle session kept republishing what it saw hours ago.
#
# So each session writes its own file, `cache/rate-limits/<session-id>.json`, which it
# alone ever overwrites. Nothing here has to decide which reading is worth keeping: Perch
# reads them all and takes, per window, the newest — which within one window is the
# highest, because usage only goes up until it resets.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

SETTINGS="$HOME/.claude/settings.json"
BRIDGE="$PERCH_HOME/bin/perch-statusline"
ORIGINAL="$PERCH_HOME/statusline-original.json"
# The same command, as one line of text. The shim runs on every render, and starting jq
# just to read one string out of the file above was a process per render for a value that
# changes only when the bridge is installed.
ORIGINAL_COMMAND="$PERCH_HOME/statusline-original-command"
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
  rm -f "$BRIDGE" "$ORIGINAL" "$ORIGINAL_COMMAND"
  # Renders before this one leaked their stdin into TMPDIR, one file each. Nothing else
  # will ever collect them.
  rm -f "${TMPDIR:-/tmp}"/perch-statusline-stdin.* 2>/dev/null || true
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

  # The command on its own line, so the shim does not have to start jq to learn what to
  # run. Written from `$ORIGINAL` rather than from the settings, so a re-run that skipped
  # the block above still refreshes it — and so the two files can never disagree.
  jq -r '.command // empty' "$ORIGINAL" >"$ORIGINAL_COMMAND"

  cat >"$BRIDGE" <<'BRIDGE_SCRIPT'
#!/bin/sh
# Perch statusline bridge (managed — remove with scripts/usage-bridge.sh --remove).
#
# Reads Claude Code's stdin once, caches `rate_limits`, then replays the identical bytes
# to the original statusline command so its output is byte-for-byte what it was.
#
# This runs on every render of every session, so it is written to start as few processes as
# it can. It used to start thirteen — five of them jq — which on a machine with a few
# sessions open was the single largest thing Perch did to the CPU: measured at 42.7ms of
# pure overhead per render, in front of a statusline that had its own work to do. Everything
# jq is asked here is now asked once, in one program, and the rest is shell builtins.
PERCH_HOME="${PERCH_HOME:-$HOME/.perch}"
CACHE_DIR="$PERCH_HOME/cache"
CACHE="$CACHE_DIR/rate-limits.json"
SESSIONS="$CACHE_DIR/rate-limits"
ORIGINAL_COMMAND="$PERCH_HOME/statusline-original-command"
ORIGINAL="$PERCH_HOME/statusline-original.json"
STDIN_FILE="${TMPDIR:-/tmp}/perch-statusline-stdin.$$"

cleanup() { rm -f "$STDIN_FILE"; }
trap cleanup EXIT HUP INT TERM

cat >"$STDIN_FILE"

# Caching must never be able to break the statusline: everything here is best-effort.
#
# One jq for the whole job. It answers three questions at once — which session this is,
# what to write for it, and whether the shared cache may be overwritten — and prints the
# answers on three lines. Asking them separately is what made this the expensive part.
if command -v jq >/dev/null 2>&1; then
  # `--slurpfile` on a file that is not there is an error, and this must never be one.
  if [ -f "$CACHE" ]; then
    set -- --slurpfile cached "$CACHE"
  else
    set -- --argjson cached '[]'
  fi

  _answers=$(jq -r "$@" '
    def stamps: [ (.rate_limits // {}) | .. | objects | .resets_at? | select(. != null)
                  | if type == "number" then . else (fromdateiso8601? // 0) end ];
    def freshness: (stamps | max) // 0;

    . as $in
    | ($in | {rate_limits, rate_limits_available}) as $limits
    | ($cached[0] // null) as $old
    # The session id comes from the payload; anything that is not a plain identifier is
    # dropped rather than turned into a path.
    | (($in.session_id // "") | tostring | gsub("[^A-Za-z0-9._-]"; "")) as $session
    # Only ever write forward. A render carries no timestamp of its own, but every window
    # carries the instant it resets, and that instant moves with the window — so the latest
    # `resets_at` in a payload dates the observation well enough to tell an idle session s
    # old snapshot from a current one. It cannot tell two snapshots of the *same* window
    # apart, which is what the per-session files are for. A cache whose every window has
    # already reset is spent, and anything beats it — without that, one stale file could
    # block every later write for ever.
    | (if $old == null then true
       else (($limits | freshness) >= ($old | freshness)) or (($old | freshness) <= now)
       end) as $write
    | $session,
      ($in | {rate_limits, rate_limits_available, session_id, cwd} | tojson),
      (if $write then ($limits | tojson) else "" end)
  ' <"$STDIN_FILE" 2>/dev/null) || _answers=""

  # jq failed, or the payload was not JSON: nothing is cached and the statusline still runs.
  if [ -n "$_answers" ]; then
    IFS='
'
    # A here-document is a builtin redirection, so reading the three lines back costs no
    # process. Set explicitly rather than left to `read -r`, because a session id is one
    # field and the two JSON documents must survive their own spaces.
    { read -r _session
      read -r _mine_json
      read -r _cache_json
    } <<ANSWERS
$_answers
ANSWERS
    unset IFS

    # One file per session, which that session alone ever writes. Three sessions open means
    # three numbers arriving every ten seconds — the busy one's, and two frozen at whatever
    # their last API response carried — and a single file would show whichever landed last.
    if [ -n "$_session" ] && [ -n "$_mine_json" ]; then
      # Tested rather than made: after the first render these exist, and `mkdir -p` on a
      # directory that is already there is still a process.
      [ -d "$SESSIONS" ] || mkdir -p "$SESSIONS" 2>/dev/null
      _mine="$SESSIONS/$_session.json"
      _minetmp="$_mine.$$.tmp"
      # Write then move, so a reader never sees half a file — under a name of our own, so
      # two sessions rendering at the same moment cannot share one temporary. The `rm` is
      # on the failure path only: a successful `mv` has already taken the temporary away.
      if printf '%s\n' "$_mine_json" >"$_minetmp" 2>/dev/null; then
        mv "$_minetmp" "$_mine" 2>/dev/null || rm -f "$_minetmp" 2>/dev/null
      fi
    fi

    # The single file stays, for a Perch that predates the directory above: it would find
    # nothing to read and show "not connected" on a machine whose quota is right there.
    if [ -n "$_cache_json" ]; then
      [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR" 2>/dev/null
      _tmp="$CACHE.$$.tmp"
      if printf '%s\n' "$_cache_json" >"$_tmp" 2>/dev/null; then
        mv "$_tmp" "$CACHE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
      fi
    fi
  fi
fi

# One line of text, written by the installer, so this costs a builtin instead of a jq.
# Falling back to the JSON keeps a bridge installed by an older version working until the
# next `usage-bridge.sh` run rewrites both.
_command=""
if [ -f "$ORIGINAL_COMMAND" ]; then
  IFS= read -r _command <"$ORIGINAL_COMMAND" || _command=""
elif [ -f "$ORIGINAL" ] && command -v jq >/dev/null 2>&1; then
  _command=$(jq -r '.command // empty' "$ORIGINAL" 2>/dev/null)
fi

# No original statusline: the user had none, so print nothing and keep it that way.
[ -n "$_command" ] || exit 0

# `exec` replaces this shell, and a replaced shell runs no EXIT trap — so the temporary
# stayed behind, one per render, for ever. Measured at 479 files in TMPDIR on the machine
# this was found on. Opening it first and unlinking it second hands the original its bytes
# through a file descriptor that outlives the name.
exec 3<"$STDIN_FILE"
rm -f "$STDIN_FILE"
exec /bin/sh -c "$_command" <&3
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
