#!/usr/bin/env bash
# Holds the statusline bridge to a process budget, and proves it still does its job.
#
#   ./scripts/statusline-budget.sh
#
# The bridge is the one piece of Perch that runs on somebody else's schedule: Claude Code
# invokes it on every render, of every open session, for as long as the editor is open.
# That makes it the only place where a line of shell costs a process a second — and it grew
# to thirteen of them, five being jq, before anyone measured it.
#
# So the budget is a test rather than a comment. It fails on a regression the way a wrong
# answer would, because "it still works" is not the property that was hard to keep.
#
# It also checks the two things the budget could be met by breaking: the cache the app reads
# has to be written, and the original statusline's bytes have to come out unchanged.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

# What one render may start, not counting the shell it runs in or the original statusline it
# hands over to. Six is the shape it should have: `cat`, one `jq`, and a `mv`/`rm` pair for
# each of the two files it writes. Anything above that is a jq per question again.
BUDGET=6

HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT

mkdir -p "$HOME_DIR/bin" "$HOME_DIR/cache/rate-limits"

# The shim exactly as `usage-bridge.sh` writes it, extracted rather than reimplemented — a
# copy here would be a second thing to keep in step, and it is the shipped one that has to
# stay cheap.
awk '/^  cat >"\$BRIDGE" <<.BRIDGE_SCRIPT.$/{found=1;next} /^BRIDGE_SCRIPT$/{found=0} found' \
  "$PERCH_ROOT/scripts/usage-bridge.sh" >"$HOME_DIR/bin/perch-statusline"
[ -s "$HOME_DIR/bin/perch-statusline" ] ||
  fail "could not find the shim inside usage-bridge.sh — did the heredoc marker change?"
chmod +x "$HOME_DIR/bin/perch-statusline"

# A statusline whose output is a fixed string, so "did the original run, unchanged" is a
# string comparison rather than a judgement.
#
# Written in both shapes the shim knows: the one-line file it reads now, and the JSON a
# bridge installed by an older version reads through jq. Both, so that what fails below is
# the budget rather than the plumbing — a check that an old shim trips on before it ever
# reaches the count is a check that proves nothing about the count.
printf 'printf ORIGINAL-RAN\n' >"$HOME_DIR/statusline-original-command"
printf '{"type":"command","command":"printf ORIGINAL-RAN"}\n' >"$HOME_DIR/statusline-original.json"

PAYLOAD="$HOME_DIR/payload.json"
cat >"$PAYLOAD" <<'JSON'
{"hook_event_name":"Status","session_id":"budget-0001",
 "cwd":"/tmp/project","model":{"id":"claude-opus-5","display_name":"Opus 5"},
 "rate_limits":{"session":{"utilization":41,"resets_at":"2099-01-01T00:00:00Z"},
                "weekly":{"utilization":22,"resets_at":"2099-01-08T00:00:00Z"}},
 "rate_limits_available":true}
JSON

sh -n "$HOME_DIR/bin/perch-statusline" || fail "the shim is not valid POSIX shell"

# --- it still does its job -----------------------------------------------------------

output="$(PERCH_HOME="$HOME_DIR" "$HOME_DIR/bin/perch-statusline" <"$PAYLOAD")"
[ "$output" = "ORIGINAL-RAN" ] ||
  fail "the original statusline's output changed: got '$output'"
ok "the original statusline runs, and its output is untouched"

session_file="$HOME_DIR/cache/rate-limits/budget-0001.json"
[ -f "$session_file" ] || fail "no per-session quota file was written"
[ "$(jq -r '.rate_limits.session.utilization' "$session_file")" = "41" ] ||
  fail "the per-session quota file does not carry the reading"
ok "the per-session quota file is written, and carries the reading"

[ -f "$HOME_DIR/cache/rate-limits.json" ] || fail "no shared quota cache was written"
ok "the shared quota cache is written"

# --- and it stays cheap --------------------------------------------------------------

# A steady-state render, which is the one that happens thousands of times: both cache files
# already exist, so nothing here is paying for a first run.
trace="$(PERCH_HOME="$HOME_DIR" sh -x "$HOME_DIR/bin/perch-statusline" <"$PAYLOAD" 2>&1 >/dev/null || true)"
spawned="$(printf '%s\n' "$trace" |
  grep -cE '^\+* (jq|cat|tr|mkdir|mv|rm|date|dirname|sed|awk|grep|cut|head|tail)\b' || true)"
jqs="$(printf '%s\n' "$trace" | grep -cE '^\+* jq\b' || true)"

info "processes started per render: $spawned (budget $BUDGET), of which jq: $jqs"
[ "$spawned" -le "$BUDGET" ] ||
  fail "the bridge starts $spawned processes per render, over its budget of $BUDGET"
[ "$jqs" -le 1 ] ||
  fail "the bridge starts $jqs jq processes per render — everything it asks fits in one"
ok "within budget"

# --- and it takes its temporary away with it -----------------------------------------

# `exec` replaces the shell, and a replaced shell runs no EXIT trap, so the stdin capture
# used to survive every render — 583 of them found in one TMPDIR. The fix is to open the
# file and unlink it before handing it over, which nothing but a leak count can check.
leak_dir="$(mktemp -d)"
before="$(find "$leak_dir" -name 'perch-statusline-stdin.*' | wc -l | tr -d ' ')"
for _ in 1 2 3 4 5; do
  TMPDIR="$leak_dir" PERCH_HOME="$HOME_DIR" "$HOME_DIR/bin/perch-statusline" <"$PAYLOAD" >/dev/null
done
after="$(find "$leak_dir" -name 'perch-statusline-stdin.*' | wc -l | tr -d ' ')"
rm -rf "$leak_dir"
[ "$before" = "$after" ] ||
  fail "five renders left $((after - before)) stdin captures behind in TMPDIR"
ok "five renders, nothing left behind in TMPDIR"

ok "statusline bridge is within budget and behaves"
