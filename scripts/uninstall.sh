#!/usr/bin/env bash
# Removes Perch from this Mac, completely.
#
#   ./scripts/uninstall.sh                        # dry run — says what it would do
#   ./scripts/uninstall.sh --yes                  # do it
#   ./scripts/uninstall.sh --yes --keep-data      # keep the token history and settings
#   ./scripts/uninstall.sh --yes --purge-backups  # also delete the *.perch-backup files
#
# Standalone on purpose. `remove.sh` is the development cleanup — it also drops the
# Postgres database and the repository's build directories, which only exist if you
# cloned this. This one is what ships next to the app: no repo, no lib.sh, no database,
# no assumption beyond a shell. Once Perch is a DMG, this is the file someone runs after
# dragging the app to the Trash and discovering that dragging an app to the Trash has
# never removed anything an app installed.
#
# It never edits a settings file blind: every one is backed up first, the result is
# checked for being valid JSON, and a file that does not parse is left exactly as it was.
set -euo pipefail

APPLY=0
KEEP_DATA=0
PURGE_BACKUPS=0

for argument in "$@"; do
  case "$argument" in
  --yes | -y) APPLY=1 ;;
  --keep-data) KEEP_DATA=1 ;;
  --purge-backups) PURGE_BACKUPS=1 ;;
  -h | --help)
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf '\033[31m✗\033[0m unknown option: %s\n' "$argument" >&2
    exit 1
    ;;
  esac
done

info() { printf '\033[36m›\033[0m %s\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
fail() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

# Prefixes every line so a dry run reads unambiguously, and returns false so the caller
# skips the action itself.
act() {
  if [ "$APPLY" -eq 1 ]; then
    info "$1"
    return 0
  fi
  printf '\033[90m  would %s\033[0m\n' "$1"
  return 1
}

PERCH_HOME="${PERCH_HOME:-$HOME/.perch}"
PERCH_SUPPORT="$HOME/Library/Application Support/Perch"
BUNDLE_ID="tech.kweli.perch"
BRIDGE="$PERCH_HOME/bin/perch-statusline"
ORIGINAL_STATUSLINE="$PERCH_HOME/statusline-original.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the app said it was, written by Perch at every launch. Read now rather than at
# step 9, because step 8 deletes the file it is written in.
#
# The guesses below cover the two places people put an app; this covers everywhere else —
# a bundle on the Desktop, a development build, a copy that never moved out of ~/Downloads.
RECORDED_APP=""
if [ -f "$PERCH_HOME/app-path" ]; then
  RECORDED_APP="$(head -1 "$PERCH_HOME/app-path" 2>/dev/null || true)"
fi

if [ "$APPLY" -eq 0 ]; then
  warn "dry run — nothing will be changed. Re-run with --yes to apply."
fi
echo

# --- JSON, with whatever this machine has ----------------------------------------
#
# jq is not a given on a Mac that only installed a DMG, and neither is python3 — but one
# of the two is on any machine that runs a coding agent. Editing JSON with sed is the one
# option that is never taken: a settings file mangled by an uninstaller is a worse outcome
# than an uninstaller that says it cannot finish.

JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL="jq"
elif command -v python3 >/dev/null 2>&1; then
  JSON_TOOL="python3"
fi

PY_EDIT='
import json, sys

mode, path = sys.argv[1], sys.argv[2]
with open(path) as handle:
    root = json.load(handle)

if mode == "hooks":
    hooks = root.get("hooks") or {}
    cleaned = {}
    for event, matchers in hooks.items():
        kept = []
        for matcher in matchers:
            entries = [
                entry for entry in matcher.get("hooks", [])
                if "perch-hook" not in (entry.get("command") or "")
            ]
            if entries:
                matcher["hooks"] = entries
                kept.append(matcher)
        if kept:
            cleaned[event] = kept
    if cleaned:
        root["hooks"] = cleaned
    else:
        root.pop("hooks", None)
elif mode == "statusline":
    try:
        with open(sys.argv[3]) as handle:
            original = json.load(handle)
    except Exception:
        original = {}
    if original.get("command"):
        root["statusLine"] = original
    else:
        root.pop("statusLine", None)

with open(path + ".perch-tmp", "w") as handle:
    json.dump(root, handle, indent=2)
    handle.write("\n")
'

# Rewrites a settings file, or leaves it untouched. Never both.
edit_json() {
  local file="$1" mode="$2"
  local tmp="$file.perch-tmp"

  case "$JSON_TOOL" in
  jq)
    if [ "$mode" = "hooks" ]; then
      jq '
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
      ' "$file" >"$tmp"
    else
      if [ -s "$ORIGINAL_STATUSLINE" ] &&
        [ -n "$(jq -r '.command // empty' "$ORIGINAL_STATUSLINE" 2>/dev/null)" ]; then
        jq --slurpfile original "$ORIGINAL_STATUSLINE" \
          '.statusLine = $original[0]' "$file" >"$tmp"
      else
        jq 'del(.statusLine)' "$file" >"$tmp"
      fi
    fi
    jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    ;;
  python3)
    python3 -c "$PY_EDIT" "$mode" "$file" "$ORIGINAL_STATUSLINE" 2>/dev/null || {
      rm -f "$tmp"
      return 1
    }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    ;;
  *)
    return 1
    ;;
  esac

  cp "$file" "$file.perch-backup"
  mv "$tmp" "$file"
}

# --- 1. The running app ----------------------------------------------------------

if pgrep -x Perch >/dev/null 2>&1; then
  # Quitting releases every session Perch is holding a permission for. Killing it does
  # too — the hooks fail open — but asking politely first is free.
  if act "quit Perch (pid $(pgrep -x Perch | tr '\n' ' '))"; then
    osascript -e 'quit app "Perch"' >/dev/null 2>&1 || true
    sleep 1
    pkill -x Perch 2>/dev/null || true
  fi
else
  ok "Perch is not running"
fi

LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
if [ -f "$LAUNCH_AGENT" ]; then
  if act "unload and remove $LAUNCH_AGENT"; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
  fi
else
  ok "no launch agent installed"
fi

# --- 2. Hooks --------------------------------------------------------------------
#
# Read before anything is deleted: the registry of sites lives in ~/.perch, which this
# script is about to remove. Only entries whose command mentions perch-hook are dropped;
# everything else in the file, including hooks that predate Perch, is left alone.

hook_sites() {
  {
    if [ -f "$PERCH_HOME/hook-sites.json" ]; then
      if [ "$JSON_TOOL" = "jq" ]; then
        jq -r '.[]? // empty' "$PERCH_HOME/hook-sites.json" 2>/dev/null || true
      else
        python3 -c 'import json,sys
try:
    for path in json.load(open(sys.argv[1])): print(path)
except Exception: pass' "$PERCH_HOME/hook-sites.json" 2>/dev/null || true
      fi
    fi
    # The three that are always worth checking even with no registry left.
    echo "$HOME/.claude/settings.json"
    echo "$HOME/.claude/settings.local.json"
    echo "${CODEX_HOME:-$HOME/.codex}/hooks.json"
  } | sort -u
}

FOUND_HOOKS=0
while IFS= read -r settings; do
  [ -f "$settings" ] || continue
  grep -q 'perch-hook' "$settings" 2>/dev/null || continue
  FOUND_HOOKS=1
  if act "remove Perch hooks from $settings (backup: $settings.perch-backup)"; then
    if [ -z "$JSON_TOOL" ]; then
      warn "neither jq nor python3 is available — edit $settings by hand"
      warn "  delete every hook whose command contains perch-hook"
    elif edit_json "$settings" hooks; then
      ok "cleaned $settings"
    else
      warn "skipped $settings — the result was not valid JSON, original left in place"
    fi
  fi
done < <(hook_sites)

[ "$FOUND_HOOKS" -eq 0 ] && ok "no Perch hooks in any settings file"

# --- 3. Statusline bridge --------------------------------------------------------
#
# Also before the data goes: the user's own statusline command is remembered in
# ~/.perch, and without that file it cannot be put back.

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if grep -q 'perch-statusline' "$CLAUDE_SETTINGS" 2>/dev/null; then
  if act "restore the original statusLine and remove the quota bridge"; then
    if [ -z "$JSON_TOOL" ]; then
      warn "neither jq nor python3 is available — remove .statusLine from $CLAUDE_SETTINGS by hand"
    elif edit_json "$CLAUDE_SETTINGS" statusline; then
      rm -f "$BRIDGE"
      ok "statusLine restored"
    else
      warn "skipped the statusline — the result was not valid JSON, original left in place"
    fi
  fi
else
  ok "no quota bridge installed"
fi

# --- 4. Editor extensions --------------------------------------------------------
#
# Each editor runs its own extension host, so each got its own copy.

EXTENSIONS_FOUND=0
for dir in "$HOME"/.vscode "$HOME"/.vscode-insiders "$HOME"/.cursor "$HOME"/.windsurf; do
  for installed in "$dir"/extensions/kweli.perch-jump-*; do
    [ -d "$installed" ] || continue
    EXTENSIONS_FOUND=1
    act "delete $installed" && rm -rf "$installed"
  done
done
[ "$EXTENSIONS_FOUND" -eq 0 ] && ok "no Perch editor extension installed"

# --- 5. kitty ---------------------------------------------------------------------
#
# Two lines inside a marked block, so exactly those come out and a hand-written config
# around them survives.

KITTY_CONF="${KITTY_CONFIG_DIRECTORY:-$HOME/.config/kitty}/kitty.conf"
if grep -q '>>> perch >>>' "$KITTY_CONF" 2>/dev/null; then
  if act "remove Perch's block from $KITTY_CONF"; then
    cp "$KITTY_CONF" "$KITTY_CONF.perch-backup"
    awk '
      /# >>> perch >>>/ { skip = 1 }
      !skip { print }
      /# <<< perch <<</ { skip = 0 }
    ' "$KITTY_CONF.perch-backup" >"$KITTY_CONF.perch-tmp" &&
      mv "$KITTY_CONF.perch-tmp" "$KITTY_CONF"
    ok "kitty.conf cleaned"
  fi
else
  ok "no Perch block in kitty.conf"
fi

# --- 6. Remote hosts --------------------------------------------------------------
#
# Reported, never touched. Reaching into someone's build server from an uninstaller —
# without being asked, possibly without a network — is not a thing this script does.

REMOTES=""
if [ -f "$PERCH_HOME/remotes.json" ]; then
  if [ "$JSON_TOOL" = "jq" ]; then
    REMOTES="$(jq -r '.[]?.alias // .[]? // empty' "$PERCH_HOME/remotes.json" 2>/dev/null || true)"
  elif [ "$JSON_TOOL" = "python3" ]; then
    REMOTES="$(python3 -c 'import json,sys
try:
    for host in json.load(open(sys.argv[1])):
        print(host.get("alias", host) if isinstance(host, dict) else host)
except Exception: pass' "$PERCH_HOME/remotes.json" 2>/dev/null || true)"
  fi
fi

if [ -n "$REMOTES" ]; then
  warn "these hosts still have Perch's remote hook installed:"
  while IFS= read -r host; do [ -n "$host" ] && info "    $host"; done <<<"$REMOTES"
  info "clean each one with: ./scripts/remote.sh remove <alias>"
  info "or, on the host itself: restore ~/.claude/settings.json.perch-backup"
else
  ok "no remote hosts configured"
fi

# --- 7. Local data ----------------------------------------------------------------

if [ "$KEEP_DATA" -eq 1 ]; then
  warn "keeping $PERCH_HOME and $PERCH_SUPPORT (--keep-data)"
  # The bridge is dead either way: nothing points at it any more.
  [ -f "$BRIDGE" ] && { act "delete $BRIDGE" && rm -f "$BRIDGE"; }
else
  for path in "$PERCH_HOME" "$PERCH_SUPPORT"; do
    if [ -e "$path" ]; then
      act "delete $path" && rm -rf "$path"
    else
      ok "already absent: $path"
    fi
  done
fi

# --- 8. What macOS keeps on an app's behalf ---------------------------------------
#
# None of this is written by Perch — the frameworks do it — which is exactly why an app
# that is dragged to the Trash leaves it all behind.

for path in \
  "$HOME/Library/Caches/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
  "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
  "$HOME/Library/WebKit/$BUNDLE_ID"; do
  [ -e "$path" ] || continue
  act "delete $path" && rm -rf "$path"
done

if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
  act "forget the $BUNDLE_ID defaults domain" && defaults delete "$BUNDLE_ID" 2>/dev/null || true
fi

# Perch asks for permission to control terminals so a card can jump to one. Resetting it
# means a reinstall asks again, rather than inheriting a grant nobody remembers giving.
if act "reset the Automation permission for $BUNDLE_ID"; then
  tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 ||
    warn "could not reset Automation — remove Perch by hand in System Settings › Privacy"
fi

# --- 9. The app itself -------------------------------------------------------------

APP_FOUND=0
SEEN=""
for app in \
  "$RECORDED_APP" \
  "/Applications/Perch.app" \
  "$HOME/Applications/Perch.app" \
  "$SCRIPT_DIR/../apps/mac/build/Perch.app"; do
  [ -n "$app" ] || continue
  [ -d "$app" ] || continue
  # The recorded path is often one of the guesses below it; deleting it twice would report
  # the same bundle twice.
  case "$SEEN" in *"|$app|"*) continue ;; esac
  SEEN="$SEEN|$app|"
  APP_FOUND=1
  act "delete $app" && rm -rf "$app"
done
[ "$APP_FOUND" -eq 0 ] && ok "no Perch.app found in the usual places"

# --- 10. The backups this script and the installers left ---------------------------
#
# Kept by default. They are the only copy of what a settings file looked like before
# Perch touched it, and deleting them is the one step here that cannot be undone.

BACKUPS="$(
  {
    ls -1 "$HOME"/.claude/settings*.perch-backup 2>/dev/null || true
    ls -1 "$HOME"/.claude/settings*.perch-statusline-backup.* 2>/dev/null || true
    ls -1 "${CODEX_HOME:-$HOME/.codex}"/hooks.json.perch-backup 2>/dev/null || true
  } | sort -u
)"

if [ -n "$BACKUPS" ]; then
  if [ "$PURGE_BACKUPS" -eq 1 ]; then
    while IFS= read -r backup; do
      [ -n "$backup" ] || continue
      act "delete $backup" && rm -f "$backup"
    done <<<"$BACKUPS"
  else
    info "backups kept (--purge-backups to delete them):"
    while IFS= read -r backup; do [ -n "$backup" ] && info "    $backup"; done <<<"$BACKUPS"
  fi
else
  ok "no Perch backups left behind"
fi

echo
if [ "$APPLY" -eq 1 ]; then
  ok "Perch removed"
  # Hooks are read once, at session start. Until a session restarts it keeps calling a
  # binary that is no longer there — which is harmless, because every hook fails open,
  # but it is worth saying rather than leaving someone to wonder.
  warn "restart any open Claude Code or Codex session — hooks are read at session start"
else
  warn "dry run finished — re-run with --yes to apply"
fi
