#!/usr/bin/env bash
# Monitor and approve agent sessions running on another machine.
#
#   ./scripts/remote.sh add build-box deploy@10.0.0.5
#   ./scripts/remote.sh deploy build-box     # upload the hook, wire the remote's CLIs
#   ./scripts/remote.sh connect build-box    # open the tunnel (stays in the foreground)
#   ./scripts/remote.sh status
#   ./scripts/remote.sh remove build-box     # undo everything on the remote
#
# How it works: the remote's hooks talk to a fixed port on the remote's own loopback, and
# `connect` reverse-forwards that port to whatever port Perch is listening on right now.
# Perch's port and token change on every launch, so `connect` re-pushes the token each
# time — a stale token is the failure you would otherwise spend an evening on.
#
# Needs SSH public-key auth. Nothing here types a password.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOSTS="$PERCH_HOME/remotes.json"
HOOK_SRC="$PERCH_ROOT/scripts/perch-remote-hook.sh"
REMOTE_HOME=".perch-remote"
REMOTE_PORT="${PERCH_REMOTE_PORT:-17890}"

command -v jq >/dev/null 2>&1 || fail "jq is required"

hosts_read() {
  [ -f "$HOSTS" ] || echo '[]' >"$HOSTS"
  cat "$HOSTS"
}

host_target() {
  hosts_read | jq -r --arg a "$1" '.[] | select(.alias == $a) | .target' | head -1
}

host_options() {
  hosts_read | jq -r --arg a "$1" '.[] | select(.alias == $a) | .options // ""' | head -1
}

require_host() {
  local target
  target="$(host_target "$1")"
  [ -n "$target" ] || fail "unknown host: $1 (add it first)"
  echo "$target"
}

cmd_add() {
  local alias="${1:-}" target="${2:-}" options="${3:-}"
  [ -n "$alias" ] && [ -n "$target" ] || fail "usage: remote.sh add <alias> <user@host> [ssh-options]"
  mkdir -p "$PERCH_HOME"
  hosts_read | jq --arg a "$alias" --arg t "$target" --arg o "$options" \
    '[.[] | select(.alias != $a)] + [{alias: $a, target: $t, options: $o}]' >"$HOSTS.tmp"
  mv "$HOSTS.tmp" "$HOSTS"
  ok "added $alias → $target"
  info "next: ./scripts/remote.sh deploy $alias"
}

cmd_list() {
  local count
  count="$(hosts_read | jq 'length')"
  [ "$count" -gt 0 ] || { info "no remote hosts configured"; return 0; }
  hosts_read | jq -r '.[] | "  \(.alias)\t\(.target)\t\(.options)"'
}

# shellcheck disable=SC2029  # the remote command is built here on purpose
cmd_deploy() {
  local alias="${1:-}" target
  target="$(require_host "$alias")"
  local opts; opts="$(host_options "$alias")"

  [ -f "$HOOK_SRC" ] || fail "hook script not found: $HOOK_SRC"

  # shellcheck disable=SC2086
  ssh $opts "$target" "mkdir -p ~/$REMOTE_HOME && chmod 700 ~/$REMOTE_HOME" \
    || fail "could not reach $target over SSH"

  # Someone may have put the file there by hand already — see `remote.sh manual`, which
  # exists because corporate networks block scp far more often than they block ssh.
  # shellcheck disable=SC2086
  if ssh $opts "$target" "[ -s ~/$REMOTE_HOME/perch-remote-hook.sh ]" 2>/dev/null; then
    ok "hook already present — skipping the upload"
  else
    info "uploading the hook to ${target}…"
    # shellcheck disable=SC2086
    scp $opts -q "$HOOK_SRC" "$target:~/$REMOTE_HOME/perch-remote-hook.sh" \
      || fail "upload failed — many networks block scp while leaving ssh open.
   Run: ./scripts/remote.sh manual   then paste the file and re-run deploy."
  fi
  # shellcheck disable=SC2086
  ssh $opts "$target" "chmod 700 ~/$REMOTE_HOME/perch-remote-hook.sh"

  info "wiring the remote's Claude Code hooks…"
  # The remote may not have jq, so the settings file is rewritten with a here-doc-driven
  # python3 fallback when it is missing.
  # shellcheck disable=SC2086
  ssh $opts "$target" "PERCH_REMOTE_HOME=\$HOME/$REMOTE_HOME bash -s" <<'REMOTE'
set -euo pipefail
HOOK="$HOME/.perch-remote/perch-remote-hook.sh"
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.perch-backup"

python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, sys
path, hook = sys.argv[1], sys.argv[2]
with open(path) as f:
    try: root = json.load(f)
    except Exception: root = {}

events = {
    "PermissionRequest": 86400, "PreToolUse": 5, "PostToolUse": 5, "Notification": 5,
    "UserPromptSubmit": 5, "Stop": 5, "StopFailure": 5, "SubagentStart": 5,
    # SessionEnd is 3 because Claude Code clamps that event to 3s and warns about more.
    "SubagentStop": 5, "PreCompact": 5, "SessionStart": 5, "SessionEnd": 3,
}

hooks = root.setdefault("hooks", {})
for event, timeout in events.items():
    entries = [e for e in hooks.get(event, [])
               if not any("perch-remote-hook" in (h.get("command") or "")
                          for h in e.get("hooks", []))]
    entries.append({"hooks": [{"type": "command",
                               "command": f"{hook} {event} --source claude",
                               "timeout": timeout}]})
    hooks[event] = entries

with open(path, "w") as f:
    json.dump(root, f, indent=2)
PY
echo "  hooks written to $SETTINGS"
REMOTE

  ok "deployed to $alias"
  warn "restart any Claude Code session already open on the remote"
  info "next: ./scripts/remote.sh connect $alias"
}

cmd_connect() {
  local alias="${1:-}" target
  target="$(require_host "$alias")"
  local opts; opts="$(host_options "$alias")"

  local runtime="$PERCH_HOME/runtime.json"
  [ -f "$runtime" ] || fail "Perch is not running — start it first"
  local port token
  port="$(jq -r '.port' "$runtime")"
  token="$(jq -r '.token' "$runtime")"
  [ -n "$port" ] && [ -n "$token" ] || fail "could not read the runtime handshake"

  # Both change on every launch, so they are pushed at connect time rather than at deploy
  # time. Mode 600, because it is a bearer token.
  info "pushing the current token…"
  # shellcheck disable=SC2086,SC2029
  ssh $opts "$target" "umask 077; mkdir -p ~/$REMOTE_HOME; \
    printf 'PERCH_PORT=%s\nPERCH_TOKEN=%s\n' '$REMOTE_PORT' '$token' > ~/$REMOTE_HOME/config"

  ok "tunnel: remote 127.0.0.1:$REMOTE_PORT → this Mac's Perch on $port"
  info "leave this running; Ctrl-C closes the tunnel"
  # ExitOnForwardFailure so a port already taken fails loudly instead of connecting to
  # nothing. Keepalives so a sleeping laptop drops the tunnel rather than wedging it.
  # shellcheck disable=SC2086
  exec ssh $opts -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -R "$REMOTE_PORT:127.0.0.1:$port" "$target"
}

# A container has no SSH tunnel and no way for Perch to reach into it, so the flow is
# inverted: the container reaches the Mac directly through `host.docker.internal`, and the
# one-liner is something you paste inside it.
cmd_docker() {
  local runtime="$PERCH_HOME/runtime.json"
  [ -f "$runtime" ] || fail "Perch is not running — start it first"
  local port token
  port="$(jq -r '.port' "$runtime")"
  token="$(jq -r '.token' "$runtime")"

  info "paste this inside the container:"
  echo
  cat <<ONELINER
mkdir -p ~/.perch-remote && cat > ~/.perch-remote/perch-remote-hook.sh <<'HOOK' && \\
chmod 700 ~/.perch-remote/perch-remote-hook.sh && \\
printf 'PERCH_HOST=host.docker.internal\nPERCH_PORT=$port\nPERCH_TOKEN=$token\n' > ~/.perch-remote/config && \\
chmod 600 ~/.perch-remote/config
$(cat "$HOOK_SRC")
HOOK
ONELINER
  echo
  warn "the token changes every time Perch restarts — re-run this after a restart"
  info "then wire the container's hooks the same way deploy does, or copy ~/.claude/settings.json in"
  info "Podman: use host.containers.internal instead of host.docker.internal"
}

# Corporate networks routinely block scp — the sftp subsystem — while leaving ssh itself
# open, and some machines have neither. The hook is a text file, so it can travel by any
# channel at all; this prints it for copying by hand.
cmd_manual() {
  info "the hook is one text file. Paste it on the remote as ~/.perch-remote/perch-remote-hook.sh:"
  echo
  echo "mkdir -p ~/.perch-remote && chmod 700 ~/.perch-remote && cat > ~/.perch-remote/perch-remote-hook.sh <<'HOOK'"
  cat "$HOOK_SRC"
  echo "HOOK"
  echo "chmod 700 ~/.perch-remote/perch-remote-hook.sh"
  echo
  info "then run: ./scripts/remote.sh deploy <alias> — it detects the file and skips the upload"
}

# Relays the *remote's own* plan quota. Useful when Claude is signed in on the server
# rather than on this Mac — the two accounts have different budgets, and showing one in
# place of the other would be worse than showing neither.
cmd_usage() {
  local alias="${1:-}" target
  target="$(require_host "$alias")"
  local opts; opts="$(host_options "$alias")"

  info "wiring the remote's statusline to relay its quota…"
  # shellcheck disable=SC2086
  ssh $opts "$target" "PERCH_ALIAS='$alias' bash -s" <<'REMOTE'
set -euo pipefail
HOOK="$HOME/.perch-remote/perch-remote-hook.sh"
[ -x "$HOOK" ] || { echo "  hook not deployed — run deploy first" >&2; exit 1; }

BRIDGE="$HOME/.perch-remote/statusline"
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"

# Same shape as the Mac's bridge: read stdin once, relay, replay the identical bytes to
# whatever statusline was already there so its visible output is unchanged.
python3 - "$SETTINGS" "$BRIDGE" "${PERCH_ALIAS:-remote}" <<'PY'
import json, os, sys
settings, bridge, alias = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings) as f:
    try: root = json.load(f)
    except Exception: root = {}

current = (root.get("statusLine") or {}).get("command", "")
if current == bridge:
    print("  already relaying"); raise SystemExit(0)

os.makedirs(os.path.dirname(bridge), exist_ok=True)
with open(os.path.join(os.path.dirname(bridge), "statusline-original"), "w") as f:
    f.write(current)

with open(bridge, "w") as f:
    f.write(f"""#!/bin/sh
STDIN_FILE="${{TMPDIR:-/tmp}}/perch-remote-statusline.$$"
trap 'rm -f "$STDIN_FILE"' EXIT HUP INT TERM
cat > "$STDIN_FILE"
PERCH_RELAY_USAGE=1 PERCH_HOST_ALIAS={alias} \\
  "$HOME/.perch-remote/perch-remote-hook.sh" --usage < "$STDIN_FILE" >/dev/null 2>&1 || true
ORIGINAL=$(cat "$HOME/.perch-remote/statusline-original" 2>/dev/null)
[ -n "$ORIGINAL" ] || exit 0
exec /bin/sh -c "$ORIGINAL" < "$STDIN_FILE"
""")
os.chmod(bridge, 0o700)

root.setdefault("statusLine", {}).update({"type": "command", "command": bridge})
with open(settings, "w") as f:
    json.dump(root, f, indent=2)
print("  statusline now relays quota")
PY
REMOTE

  ok "quota relay wired on $alias"
  warn "restart the remote's Claude Code sessions — statusLine is read at session start"
  info "the quota shows up in Perch once the remote renders a statusline"
}

cmd_status() {
  local count
  count="$(hosts_read | jq 'length')"
  info "hosts          $count"
  cmd_list
  if [ -f "$PERCH_HOME/runtime.json" ]; then
    ok "Perch          listening on $(jq -r '.port' "$PERCH_HOME/runtime.json")"
  else
    warn "Perch          not running — connect would have nothing to forward to"
  fi
  if pgrep -f "ssh .*-R $REMOTE_PORT:127.0.0.1" >/dev/null 2>&1; then
    ok "tunnel         up"
  else
    info "tunnel         down"
  fi
}

cmd_remove() {
  local alias="${1:-}" target
  target="$(require_host "$alias")"
  local opts; opts="$(host_options "$alias")"

  info "removing Perch from ${target}…"
  # shellcheck disable=SC2086
  ssh $opts "$target" bash -s <<'REMOTE' || warn "remote cleanup failed — the host may be unreachable"
set -uo pipefail
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.perch-backup"
  python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    try: root = json.load(f)
    except Exception: sys.exit(0)
hooks = root.get("hooks", {})
for event in list(hooks):
    kept = [e for e in hooks[event]
            if not any("perch-remote-hook" in (h.get("command") or "")
                       for h in e.get("hooks", []))]
    if kept: hooks[event] = kept
    else: del hooks[event]
if not hooks: root.pop("hooks", None)
with open(path, "w") as f:
    json.dump(root, f, indent=2)
PY
fi
rm -rf "$HOME/.perch-remote"
echo "  removed"
REMOTE

  hosts_read | jq --arg a "$alias" '[.[] | select(.alias != $a)]' >"$HOSTS.tmp"
  mv "$HOSTS.tmp" "$HOSTS"
  ok "removed $alias"
}

case "${1:-status}" in
  add) shift; cmd_add "$@" ;;
  list) cmd_list ;;
  deploy) shift; cmd_deploy "$@" ;;
  connect) shift; cmd_connect "$@" ;;
  docker) cmd_docker ;;
  manual) cmd_manual ;;
  usage) shift; cmd_usage "$@" ;;
  status) cmd_status ;;
  remove) shift; cmd_remove "$@" ;;
  *) fail "usage: remote.sh [add|list|deploy|connect|usage|docker|manual|status|remove]" ;;
esac
