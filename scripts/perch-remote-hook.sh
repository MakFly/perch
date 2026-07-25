#!/usr/bin/env bash
# Perch's hook for a remote host.
#
#   perch-remote-hook.sh <EventName> [--source claude]
#
# Runs on the server, next to the agent. Forwards the payload down an SSH reverse tunnel
# to Perch on your Mac and prints whatever Perch says to print.
#
# Deliberately dependency-free: no jq, no curl, no compiled binary to cross-compile and
# keep in step. It uses bash's own /dev/tcp, and falls back to nc where that is disabled.
# The one thing it does not do is parse JSON — the Mac sends back the exact bytes for
# stdout, so the schema lives in one tested place instead of being reimplemented in sed.
#
# Every failure path exits 0 with no output. A server that cannot reach your Mac — VPN
# dropped, laptop asleep, tunnel down — must behave exactly as if this hook did not exist.
set -uo pipefail

CONFIG="${PERCH_REMOTE_HOME:-$HOME/.perch-remote}/config"
[ -r "$CONFIG" ] || exit 0
# shellcheck disable=SC1090
. "$CONFIG"

PORT="${PERCH_PORT:-17890}"
# Loopback for a reverse SSH tunnel; `host.docker.internal` from inside a container, which
# has no tunnel and reaches the Mac directly.
HOST="${PERCH_HOST:-127.0.0.1}"
TOKEN="${PERCH_TOKEN:-}"
[ -n "$TOKEN" ] || exit 0

EVENT="${1:-Unknown}"
SOURCE="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --source) shift; SOURCE="${1:-claude}" ;;
  esac
  shift || break
done

PAYLOAD="$(cat)"
[ -n "$PAYLOAD" ] || PAYLOAD='{}'

# `--usage` mode: this invocation is the remote's statusline, not a hook. Relay the plan
# quota down the same tunnel and get out of the way — the statusline's own output is
# produced by the wrapper that called us, not here.
if [ "$EVENT" = "--usage" ] || [ "${PERCH_RELAY_USAGE:-}" = "1" ]; then
  HOSTNAME_LABEL="${PERCH_HOST_ALIAS:-$(hostname -s 2>/dev/null || echo remote)}"
  # The payload is embedded as a JSON *string*, so the quotes inside it must be escaped.
  ESCAPED=$(printf '%s' "$PAYLOAD" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n')
  LINE=$(printf '{"v":1,"token":"%s","event":"__usage","wantsDecision":false,"payload":{"cwd":"%s","message":"%s"}}' \
    "$TOKEN" "$HOSTNAME_LABEL" "$ESCAPED")
  if { exec 3<>"/dev/tcp/$HOST/$PORT"; } 2>/dev/null; then
    printf '%s\n' "$LINE" >&3 2>/dev/null
    IFS= read -r -t 2 _ <&3 2>/dev/null
    { exec 3<&-; } 2>/dev/null
    { exec 3>&-; } 2>/dev/null
  fi
  exit 0
fi

# Permission requests block; telemetry must never stall a turn.
case "$EVENT" in
  PermissionRequest) WANTS=true; TIMEOUT="${PERCH_DECISION_TIMEOUT:-86400}" ;;
  *) WANTS=false; TIMEOUT=2 ;;
esac

# The payload is already JSON, so it is embedded verbatim rather than re-encoded — which
# is also why no jq is needed to build the frame.
LINE=$(printf '{"v":1,"token":"%s","event":"%s","wantsDecision":%s,"rawOutput":true,"agent":"%s","payload":%s}' \
  "$TOKEN" "$EVENT" "$WANTS" "$SOURCE" "$PAYLOAD")

reply=""

# The braces matter: bash reports a failed /dev/tcp redirection from the shell itself, so
# redirecting inside `exec` does not silence it. A tunnel that is simply down must not
# print anything into the agent's log.
if { exec 3<>"/dev/tcp/$HOST/$PORT"; } 2>/dev/null; then
  printf '%s\n' "$LINE" >&3 2>/dev/null
  IFS= read -r -t "$TIMEOUT" reply <&3 2>/dev/null
  { exec 3<&-; } 2>/dev/null
  { exec 3>&-; } 2>/dev/null
elif command -v nc >/dev/null 2>&1; then
  # `-q 1` so nc closes after the answer instead of waiting out the timeout.
  reply=$(printf '%s\n' "$LINE" | nc -w "$TIMEOUT" -q 1 "$HOST" "$PORT" 2>/dev/null | head -n 1)
else
  exit 0
fi

[ -n "$reply" ] || exit 0

# Only Perch knows the token, so this rejects anything else that grabbed the port — which
# on a shared server matters more than it does on a laptop.
seen=$(printf '%s' "$reply" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')
[ "$seen" = "$TOKEN" ] || exit 0

# The finished stdout comes back base64-encoded. Its alphabet contains no quote, so this
# match cannot run past its own field — which a greedy match over escaped JSON does, and
# that is not a thing to get subtly wrong on someone's build server.
encoded=$(printf '%s' "$reply" | sed -n 's/.*"outputB64":"\([A-Za-z0-9+/=]*\)".*/\1/p')
[ -n "$encoded" ] || exit 0

printf '%s' "$encoded" | base64 -d 2>/dev/null || printf '%s' "$encoded" | base64 --decode 2>/dev/null
exit 0
