#!/usr/bin/env bash
# Lets Perch focus the exact kitty window.
#
#   ./scripts/configure-kitty.sh
#   ./scripts/configure-kitty.sh --remove
#
# kitty refuses remote control unless it is turned on, so this adds two lines to
# kitty.conf inside a marked block. Nothing else in the file is touched, and --remove
# takes out exactly what was added.
#
# WezTerm needs none of this — `wezterm cli` works out of the box.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONF="${KITTY_CONFIG_DIRECTORY:-$HOME/.config/kitty}/kitty.conf"
BEGIN="# >>> perch >>>"
END="# <<< perch <<<"

if [ "${1:-}" = "--remove" ]; then
  [ -f "$CONF" ] || { ok "no kitty.conf — nothing to remove"; exit 0; }
  grep -q "$BEGIN" "$CONF" || { ok "Perch's block is not in kitty.conf"; exit 0; }
  cp "$CONF" "$CONF.perch-backup"
  # sed over the marked range only; everything outside it is copied through untouched.
  sed "/$BEGIN/,/$END/d" "$CONF.perch-backup" >"$CONF"
  ok "removed Perch's block from $CONF"
  info "backup at $CONF.perch-backup"
  warn "quit kitty entirely (Cmd-Q) — kitty.conf is read at startup"
  exit 0
fi

mkdir -p "$(dirname "$CONF")"
[ -f "$CONF" ] || : >"$CONF"

if grep -q "$BEGIN" "$CONF"; then
  ok "already configured"
  exit 0
fi

cp "$CONF" "$CONF.perch-backup"
cat >>"$CONF" <<CONFIG

$BEGIN
# Lets Perch focus the window a session is running in. Remove with:
#   ./scripts/configure-kitty.sh --remove
allow_remote_control yes
listen_on unix:/tmp/kitty
$END
CONFIG

ok "configured $CONF"
info "backup at $CONF.perch-backup"
# Reloading the config is not enough: allow_remote_control is read once, at startup.
warn "quit kitty entirely (Cmd-Q) and reopen it — a config reload will not do"
