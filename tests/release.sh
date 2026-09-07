#!/bin/bash
# Tests that SessionEnd actually hands the pane back.
#
# Herdr drops a pane lifecycle call whose seq is not above the last one it
# recorded for that pane. SessionEnd reports idle with a seq and then releases
# without one, so the release is silently ignored and the agent row lingers in
# `herdr agent list` after muse has exited.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$REPO_DIR/tests/fixtures"
REPORTER="$REPO_DIR/hooks/herdr-muse.py"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== release tests =="
TMP="$(mktemp -d /tmp/herdr-muse-release.XXXXXX)"
export XDG_DATA_HOME="$TMP/data"
export STUB_LOG="$TMP/stub.log"
export STUB_SHELL_PID="$$"
export HERDR_MUSE_BIN="$REPO_DIR/tests/stub-herdr.sh"
chmod +x "$HERDR_MUSE_BIN"
: > "$STUB_LOG"

python3 "$REPORTER" < "$FIX/session_start.json"
python3 "$REPORTER" < "$FIX/session_end.json"

REL="$(grep -- "release-agent" "$STUB_LOG" || true)"
if [[ -z "$REL" ]]; then
  fail "SessionEnd issued no release at all"
elif grep -q -- "release-agent w9:p1 .*--seq [0-9]" "$STUB_LOG"; then
  pass "SessionEnd releases with a seq"
else
  fail "release carries no --seq, herdr will ignore it: $REL"
fi

# The release must outrank the idle report that precedes it, or herdr's
# monotonic check drops it.
IDLE_SEQ="$(grep -o -- "--state idle .*--seq [0-9]*" "$STUB_LOG" | tail -1 | awk '{print $NF}')"
REL_SEQ="$(grep -o -- "release-agent .*--seq [0-9]*" "$STUB_LOG" | tail -1 | awk '{print $NF}')"
if [[ -n "$IDLE_SEQ" && -n "$REL_SEQ" && "$REL_SEQ" -gt "$IDLE_SEQ" ]]; then
  pass "release seq outranks the final idle report ($IDLE_SEQ -> $REL_SEQ)"
else
  fail "release seq does not outrank final idle (idle=$IDLE_SEQ release=$REL_SEQ)"
fi

rm -rf "$TMP"
echo "release tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
