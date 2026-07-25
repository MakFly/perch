#!/usr/bin/env bash
# Installs Perch's hooks into a Claude Code settings file, or into Codex.
#
#   ./scripts/install-hooks.sh ~/some-project     # project-scoped (recommended)
#   ./scripts/install-hooks.sh --global           # ~/.claude/settings.json
#   ./scripts/install-hooks.sh --codex            # ~/.codex/hooks.json
#   ./scripts/install-hooks.sh --uninstall <project-dir>|--global|--codex
#
# Codex speaks the same hook vocabulary as Claude Code — same event names, same payload —
# so it needs a different file and a `--source codex` flag, not a second event model.
#
# Existing hooks are preserved: Perch entries are merged in, and any previous Perch
# entries are replaced rather than duplicated. Every site touched is recorded in
# ~/.perch/hook-sites.json so remove.sh knows where to clean up.
#
# The scopes are exclusive. Claude Code merges its global and project settings and runs
# every matching hook, so installing in both makes one event fire twice: two rows in the
# feed, and two blocked hooks for one permission. Perch drops the copies, but the second
# process still starts, so this refuses to create the overlap rather than papering over it
# — `--force` if you mean it anyway.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

FORCE=0
UNINSTALL=0
TARGET=""
for argument in "$@"; do
  case "$argument" in
    --force) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) TARGET="$argument" ;;
  esac
done
[ -n "$TARGET" ] ||
  fail "usage: install-hooks.sh [--uninstall] <project-dir>|--global|--codex [--force]"

# Both files put their hooks under the same `.hooks` key, with the same event names, so
# one jq program serves both.
SOURCE="claude"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"

if [ "$TARGET" = "--global" ]; then
  SETTINGS="$GLOBAL_SETTINGS"
elif [ "$TARGET" = "--codex" ]; then
  SETTINGS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
  SOURCE="codex"
else
  [ -d "$TARGET" ] || fail "not a directory: $TARGET"
  SETTINGS="$(cd "$TARGET" && pwd)/.claude/settings.json"
fi

SITES="$PERCH_HOME/hook-sites.json"

# Perch entries out, everything else untouched — the same program remove.sh uses, kept
# here so an install can undo exactly what it did.
STRIP_PERCH='
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

# Rewrites a settings file through jq, never leaving a truncated one behind.
rewrite_settings() {
  jq empty "$1" 2>/dev/null || fail "produced invalid JSON — original left untouched"
  mv "$1" "$SETTINGS"
}

if [ "$UNINSTALL" -eq 1 ]; then
  [ -f "$SETTINGS" ] || fail "no settings file at $SETTINGS"
  grep -q 'perch-hook' "$SETTINGS" 2>/dev/null || {
    ok "no Perch hooks in $SETTINGS — nothing to remove"
    exit 0
  }
  cp "$SETTINGS" "$SETTINGS.perch-backup"
  jq "$STRIP_PERCH" "$SETTINGS.perch-backup" >"$SETTINGS.tmp"
  rewrite_settings "$SETTINGS.tmp"
  # Drop it from the registry too, or the app keeps checking a site it no longer owns and
  # reports it as one that lost its hooks.
  if [ -f "$SITES" ]; then
    jq --arg path "$SETTINGS" 'map(select(. != $path))' "$SITES" >"$SITES.tmp" &&
      mv "$SITES.tmp" "$SITES"
  fi
  ok "Perch hooks removed from $SETTINGS"
  info "backup at $SETTINGS.perch-backup"
  warn "restart any open session there — hooks load at session start"
  exit 0
fi

# The overlap check, both ways. Only Claude Code has two scopes to collide.
if [ "$SOURCE" = "claude" ] && [ "$FORCE" -eq 0 ]; then
  if [ "$SETTINGS" != "$GLOBAL_SETTINGS" ] &&
    grep -q 'perch-hook' "$GLOBAL_SETTINGS" 2>/dev/null; then
    warn "Perch is already installed globally, in $GLOBAL_SETTINGS"
    info "that install already covers this project; adding a second one makes every event fire twice"
    fail "nothing changed — install anyway with --force"
  fi

  if [ "$SETTINGS" = "$GLOBAL_SETTINGS" ] && [ -f "$SITES" ]; then
    # Only Claude Code project files can collide with it — Codex keeps its hooks in one
    # global file, which nothing here doubles.
    # Every skip is an explicit `continue`: under `set -e`, a bare `[ -f … ] && …` that
    # fails ends the subshell, and the sites after it would go unreported — a guard that
    # quietly checks half the list is worse than no guard.
    OVERLAPPING="$(jq -r '.[]? // empty' "$SITES" | while IFS= read -r site; do
      [ "$site" != "$GLOBAL_SETTINGS" ] || continue
      [[ "$site" == */.claude/settings.json ]] || continue
      [ -f "$site" ] || continue
      grep -q 'perch-hook' "$site" 2>/dev/null || continue
      echo "$site"
    done)"
    if [ -n "$OVERLAPPING" ]; then
      warn "these projects already install Perch, and a global install would double them:"
      while IFS= read -r site; do info "    $site"; done <<<"$OVERLAPPING"
      info "remove one with: ./scripts/install-hooks.sh --uninstall <project-dir>"
      fail "nothing changed — install anyway with --force"
    fi
  fi
fi

HOOK_BIN="$PERCH_APP/Contents/Resources/perch-hook"
[ -x "$HOOK_BIN" ] || fail "hook binary not found — run apps/mac/Scripts/make-app.sh first"

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.perch-backup"

# Telemetry hooks are fire-and-forget with a short timeout. PermissionRequest is the
# only blocking one: it waits while you decide in the notch.
jq \
  --arg bin "$HOOK_BIN" \
  --arg source "$SOURCE" \
  '
  def perch_entry($event; $timeout):
    {hooks: [{type: "command", command: "\($bin) \($event) --source \($source)", timeout: $timeout}]};

  def strip_perch:
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
    else . end;

  strip_perch
  | .hooks //= {}
  # A day, so Claude Code never kills the hook out from under a decision. Perch owns the
  # deadline instead — see PermissionBroker — because only the app knows whether anyone is
  # still looking at the notch.
  | .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) + [perch_entry("PermissionRequest"; 86400)])
  | .hooks.PreToolUse        = ((.hooks.PreToolUse // [])        + [perch_entry("PreToolUse"; 5)])
  | .hooks.PostToolUse       = ((.hooks.PostToolUse // [])       + [perch_entry("PostToolUse"; 5)])
  # Without this, a tool that is denied or errors stays "running" in the feed forever.
  | .hooks.PostToolUseFailure = ((.hooks.PostToolUseFailure // []) + [perch_entry("PostToolUseFailure"; 5)])
  | .hooks.PermissionDenied  = ((.hooks.PermissionDenied // [])  + [perch_entry("PermissionDenied"; 5)])
  | .hooks.Notification      = ((.hooks.Notification // [])      + [perch_entry("Notification"; 5)])
  | .hooks.UserPromptSubmit  = ((.hooks.UserPromptSubmit // [])  + [perch_entry("UserPromptSubmit"; 5)])
  | .hooks.Stop              = ((.hooks.Stop // [])              + [perch_entry("Stop"; 5)])
  # A turn that ends in failure is still an ended turn; without it the notch keeps spinning.
  | .hooks.StopFailure       = ((.hooks.StopFailure // [])       + [perch_entry("StopFailure"; 5)])
  # Subagents: fan-out Task calls and Agent Teams both report through these.
  | .hooks.SubagentStart     = ((.hooks.SubagentStart // [])     + [perch_entry("SubagentStart"; 5)])
  | .hooks.SubagentStop      = ((.hooks.SubagentStop // [])      + [perch_entry("SubagentStop"; 5)])
  # Compaction can run for a while and looks like a hang without it.
  | .hooks.PreCompact        = ((.hooks.PreCompact // [])        + [perch_entry("PreCompact"; 5)])
  | .hooks.SessionStart      = ((.hooks.SessionStart // [])      + [perch_entry("SessionStart"; 5)])
  | .hooks.SessionEnd        = ((.hooks.SessionEnd // [])        + [perch_entry("SessionEnd"; 5)])
  ' "$SETTINGS.perch-backup" >"$SETTINGS.tmp"

rewrite_settings "$SETTINGS.tmp"

# Record the site so remove.sh can find it later.
mkdir -p "$PERCH_HOME"
[ -f "$SITES" ] || echo '[]' >"$SITES"
jq --arg path "$SETTINGS" '. + [$path] | unique' "$SITES" >"$SITES.tmp" && mv "$SITES.tmp" "$SITES"

ok "hooks installed in $SETTINGS"
info "backup at $SETTINGS.perch-backup"
# Claude Code reads hook settings when a session starts, so an already-open session will
# ignore these until it is restarted. Without this note the install looks broken.
if [ "$SOURCE" = "codex" ]; then
  warn "restart any open Codex session — hooks load at session start"
  # Codex asks before letting a third party run on its events. Perch cannot grant that
  # for you, and staying silent about it would look like the install simply failed.
  info "if Codex asks to trust these hooks, run /hooks in Codex and approve them"
else
  warn "restart any open Claude Code session in that project — hooks load at session start"
fi
info "remove with: ./scripts/remove.sh --yes --keep-db --keep-data"
