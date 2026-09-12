#!/bin/bash
# Tests for adopting sessions that never sent a SessionStart.
#
# `muse resume` restores a conversation without emitting SessionStart, and a
# session already running when the hooks were installed never sent one either.
# Both used to leave the pane permanently invisible to Herdr. These cases pin
# the adoption path and the guard that keeps subagents from stealing a pane.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$REPO_DIR/tests/fixtures"
REPORTER="$REPO_DIR/hooks/herdr-muse.py"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== resume adoption tests =="
TMP="$(mktemp -d /tmp/herdr-muse-resume.XXXXXX)"
export XDG_DATA_HOME="$TMP/data"
export STUB_LOG="$TMP/stub.log"
export STUB_SHELL_PID="$$"
export HERDR_MUSE_BIN="$REPO_DIR/tests/stub-herdr.sh"
chmod +x "$HERDR_MUSE_BIN"
: > "$STUB_LOG"

# 1. A resumed session's first event is UserPromptSubmit, never SessionStart.
python3 "$REPORTER" < "$FIX/user_prompt_submit.json"
if grep -q -- "--state working --agent-session-id 11111111-1111-4111-8111-111111111111" "$STUB_LOG"; then
  pass "UserPromptSubmit without SessionStart adopts the pane"
else
  fail "resumed session was not adopted"; echo "--- log:"; cat "$STUB_LOG"
fi

# 2. PreToolUse must adopt too: a resumed session can start with a tool call.
: > "$STUB_LOG"; rm -rf "$XDG_DATA_HOME"
python3 "$REPORTER" < "$FIX/pre_tool_use.json"
if grep -q -- "--state working" "$STUB_LOG"; then
  pass "PreToolUse without SessionStart adopts the pane"
else
  fail "PreToolUse did not adopt"
fi

# 3. Adoption must not steal a pane another session already owns. A subagent's
#    events carry an unknown session_id and must stay ignored.
: > "$STUB_LOG"; rm -rf "$XDG_DATA_HOME"
python3 "$REPORTER" < "$FIX/session_start.json"          # lead takes the pane
: > "$STUB_LOG"
sed 's/11111111-1111-4111-8111-111111111111/33333333-3333-4333-8333-333333333333/g' \
  "$FIX/pre_tool_use.json" > "$TMP/sub_tool.json"
python3 "$REPORTER" < "$TMP/sub_tool.json"
if [[ ! -s "$STUB_LOG" ]]; then
  pass "unknown session cannot steal an owned pane"
else
  fail "unknown session stole the pane"; cat "$STUB_LOG"
fi

# 4. Stop / SessionEnd must not adopt: they would report idle for a pane we
#    never tracked, and SessionEnd would immediately release it again.
: > "$STUB_LOG"; rm -rf "$XDG_DATA_HOME"
python3 "$REPORTER" < "$FIX/stop.json"
python3 "$REPORTER" < "$FIX/session_end.json"
if [[ ! -s "$STUB_LOG" ]]; then
  pass "Stop/SessionEnd do not adopt"
else
  fail "Stop/SessionEnd adopted a pane"; cat "$STUB_LOG"
fi

# 5. An adopted binding must keep incrementing seq like a normal one.
: > "$STUB_LOG"; rm -rf "$XDG_DATA_HOME"
python3 "$REPORTER" < "$FIX/user_prompt_submit.json"
python3 "$REPORTER" < "$FIX/pre_tool_use.json"
SEQS="$(grep -o -- "--seq [0-9]*" "$STUB_LOG" | awk '{print $2}')"
FIRST="$(echo "$SEQS" | head -1)"; SECOND="$(echo "$SEQS" | tail -1)"
if [[ -n "$FIRST" && -n "$SECOND" && "$SECOND" -eq $((FIRST+1)) ]]; then
  pass "adopted binding increments seq ($FIRST -> $SECOND)"
else
  fail "adopted seq did not increment ($FIRST -> $SECOND)"
fi

rm -rf "$TMP"
echo "resume tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
