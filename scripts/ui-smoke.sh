#!/usr/bin/env bash
# Exercises the notch's hover behaviour against the running app.
#
# The notch is the one part of Perch that unit tests cannot reach: it depends on a real
# display and a real cursor. This drives the cursor with CGWarpMouseCursorPosition (which
# needs no permission, unlike synthetic clicks) and reads the resulting state back out of
# `Perch --status`.
#
#   ./scripts/ui-smoke.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PERCH="$PERCH_APP/Contents/MacOS/Perch"
[ -x "$PERCH" ] || fail "app not built — run apps/mac/Scripts/make-app.sh"
pgrep -x Perch >/dev/null || fail "Perch is not running — open $PERCH_APP"

HELPER="${TMPDIR:-/tmp}/perch-cursor"
if [ ! -x "$HELPER" ]; then
  info "building cursor helper"
  cat >"${TMPDIR:-/tmp}/perch-cursor.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else { exit(1) }
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
usleep(50_000)
// A warp alone does not always emit a mouse-moved event; nudge a pixel so tracking fires.
CGWarpMouseCursorPosition(CGPoint(x: x + 1, y: y))
SWIFT
  swiftc -O "${TMPDIR:-/tmp}/perch-cursor.swift" -o "$HELPER"
fi

# Read the cutout's centre out of the app itself rather than hard-coding a display.
GEOMETRY="$($PERCH --diagnose)"
NOTCH_X="$(echo "$GEOMETRY" | awk '/notchRect/ {gsub("x=","",$2); print $2}' | head -1)"
NOTCH_W="$(echo "$GEOMETRY" | awk '/notchRect/ {gsub("w=","",$4); print $4}' | head -1)"
CENTER_X="$(python3 -c "print(int(float('$NOTCH_X') + float('$NOTCH_W') / 2))")"

state() { $PERCH --status | awk '/^state/ {print $2}'; }

# Polls rather than reading once.
#
# `CGWarpMouseCursorPosition` teleports without emitting an event, so the helper nudges a
# pixel to make tracking fire — and if that nudge lands while the window is still resizing,
# AppKit can report a hover exit, which starts a 220ms collapse. Reading the state through
# a subprocess takes longer than that, so a single read caught the panel mid-flicker maybe
# one run in three. Waiting for the expected state still fails when it never arrives, which
# is the regression this test exists to catch.
expect() {
  local want="$1" label="$2" got=""
  for _ in 1 2 3 4 5 6 7 8; do
    got="$(state)"
    [ "$got" = "$want" ] && break
    sleep 0.25
  done

  if [ "$got" = "$want" ]; then
    ok "$label → $got"
  else
    printf '\033[31m✗\033[0m %s → expected %s, got %s\n' "$label" "$want" "$got" >&2
    FAILED=1
  fi
}

FAILED=0
CURSOR_RESTORE_X=600
CURSOR_RESTORE_Y=700

info "notch centre at x=$CENTER_X"

# Settle before asserting anything. The panel may be expanded from a previous run, or
# holding a card from whatever was injected before this ran — either makes the very first
# assertion fail for a reason that has nothing to do with hover. This waits for idle
# instead of assuming it, which is what made the test flaky.
"$HELPER" "$CURSOR_RESTORE_X" "$CURSOR_RESTORE_Y"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(state)" = "idle" ] && break
  sleep 0.5
done
[ "$(state)" = "idle" ] || warn "did not settle to idle — something is still on screen"

# The sequence is attempted a few times, and one clean pass is the result.
#
# Not to make a failing test pass: `CGWarpMouseCursorPosition` teleports the cursor
# *without emitting an event*, and AppKit only re-evaluates hover when some event arrives.
# Posting a real synthetic move needs Accessibility permission, which Perch is built never
# to require — so from a terminal without it, whether the app notices a warp is genuinely
# a coin flip. Measured here: about three runs in five.
#
# So a single miss proves nothing, while "never works across N attempts" is exactly the
# regression this test exists to catch, and is still reported.
sequence() {
  FAILED=0
  "$HELPER" "$CURSOR_RESTORE_X" "$CURSOR_RESTORE_Y"; sleep 0.4
  expect idle "cursor away from the notch"

  "$HELPER" "$CENTER_X" 16; sleep 0.4
  expect peek "cursor over the notch"

  # Inside the peek panel: it must stay open rather than flicker.
  "$HELPER" "$CENTER_X" 90; sleep 0.4
  expect peek "cursor inside the panel"

  "$HELPER" "$CENTER_X" 300; sleep 0.6
  expect idle "cursor left the panel"

  return "$FAILED"
}

ATTEMPTS=0
until sequence; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge 3 ]; then break; fi
  warn "a cursor warp went unnoticed — retrying ($ATTEMPTS/3)"
  echo
done

"$HELPER" "$CURSOR_RESTORE_X" "$CURSOR_RESTORE_Y"

echo
if [ "$FAILED" -eq 0 ]; then
  [ "$ATTEMPTS" -eq 0 ] \
    && ok "notch hover behaves correctly" \
    || ok "notch hover behaves correctly (after $ATTEMPTS retried warp(s))"
else
  fail "notch hover regressed"
fi
