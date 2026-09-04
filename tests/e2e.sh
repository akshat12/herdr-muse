#!/bin/bash
# End-to-end tests for herdr-muse.
#
# Phase 1 (synthetic): reporter mapping logic against a stub herdr binary.
#   No Herdr server, no muse session needed. Safe anywhere.
# Phase 2 (live): real install + real `muse exec` in a throwaway Herdr pane.
#   Requires HERDR_ENV=1 and mutates ~/.config/muse/settings.json temporarily
#   (backed up and restored byte-identical). Pass --live to enable.
# Phase 3 (plugin): `herdr plugin link` validation. Needs herdr; runs in --live.
#
# Usage: ./tests/e2e.sh [--live]
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$REPO_DIR/tests/fixtures"
REPORTER="$REPO_DIR/hooks/herdr-muse.py"
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_log_contains() { # $1=log $2=expected-substring $3=label
  if grep -qF -- "$2" "$1"; then pass "$3"; else
    fail "$3 (missing: $2)"; echo "--- log:"; cat "$1"
  fi
}

run_reporter() { # $1=fixture : feeds stdin, HERDR_MUSE_BIN + XDG_DATA_HOME from env
  python3 "$REPORTER" < "$FIX/$1.json"
}

echo "== Phase 1: synthetic reporter tests =="
E2E_TMP="$(mktemp -d /tmp/herdr-muse-e2e.XXXXXX)"
export XDG_DATA_HOME="$E2E_TMP/data"
export STUB_LOG="$E2E_TMP/stub.log"
export STUB_SHELL_PID="$$"
export HERDR_MUSE_BIN="$REPO_DIR/tests/stub-herdr.sh"
chmod +x "$HERDR_MUSE_BIN"
: > "$STUB_LOG"

run_reporter session_start
assert_log_contains "$STUB_LOG" "report-agent w9:p1 --source custom:muse --agent muse --state idle --agent-session-id 11111111-1111-4111-8111-111111111111 --seq 1" "SessionStart binds pane, reports idle seq 1"

run_reporter user_prompt_submit
assert_log_contains "$STUB_LOG" "--state working --agent-session-id 11111111-1111-4111-8111-111111111111 --seq 2" "UserPromptSubmit reports working seq 2"

run_reporter pre_tool_use
assert_log_contains "$STUB_LOG" "--state working --agent-session-id 11111111-1111-4111-8111-111111111111 --seq 3" "PreToolUse reports working seq 3"

run_reporter permission_request
assert_log_contains "$STUB_LOG" "--state blocked --agent-session-id 11111111-1111-4111-8111-111111111111 --seq 4" "PermissionRequest reports blocked seq 4"

echo '{"nope": true}' | python3 "$REPORTER"
BEFORE_NSID="$(wc -l < "$STUB_LOG")"
if [[ "$(wc -l < "$STUB_LOG")" == "$BEFORE_NSID" ]]; then pass "payload without session_id ignored"; else
  fail "payload without session_id caused herdr calls"; fi

echo 'not json{{{' | python3 "$REPORTER"
if [[ "$(wc -l < "$STUB_LOG")" == "$BEFORE_NSID" ]]; then pass "malformed stdin ignored"; else
  fail "malformed stdin caused herdr calls"; fi

run_reporter stop
assert_log_contains "$STUB_LOG" "--state idle --agent-session-id 11111111-1111-4111-8111-111111111111 --seq 5" "Stop reports idle seq 5"

run_reporter session_end
assert_log_contains "$STUB_LOG" "release-agent w9:p1 --source custom:muse --agent muse" "SessionEnd releases authority"
if python3 -c "import json; d=json.load(open('$XDG_DATA_HOME/herdr-muse/bindings.json')); assert d=={}, d"; then
  pass "binding removed after SessionEnd"
else fail "binding not removed after SessionEnd"; fi

# Stale-binding handling with a fresh session.
sed 's/11111111-1111-4111-8111-111111111111/55555555-5555-4555-8555-555555555555/g' \
  "$FIX/session_start.json" > "$E2E_TMP/start555.json"
python3 "$REPORTER" < "$E2E_TMP/start555.json"
assert_log_contains "$STUB_LOG" "--state idle --agent-session-id 55555555-5555-4555-8555-555555555555 --seq 1" "rebind scenario binds 555"
export STUB_FOREGROUND_NAME="muse-bin-test"
BEFORE="$(wc -l < "$STUB_LOG")"
run_reporter subagent_start
if [[ "$(wc -l < "$STUB_LOG")" == "$BEFORE" ]]; then
  pass "bound pane refuses second SessionStart while muse foreground present"
else fail "bound pane refuses second SessionStart while muse foreground present"; fi
export STUB_FOREGROUND_NAME=""
run_reporter second_start
assert_log_contains "$STUB_LOG" "--state idle --agent-session-id 44444444-4444-4444-8444-444444444444 --seq 1" "stale binding rebinds when no muse foreground"
unset STUB_FOREGROUND_NAME
BEFORE_EVICT="$(wc -l < "$STUB_LOG")"
sed 's/11111111-1111-4111-8111-111111111111/55555555-5555-4555-8555-555555555555/g' \
  "$FIX/stop.json" > "$E2E_TMP/stop555.json"
python3 "$REPORTER" < "$E2E_TMP/stop555.json"
if [[ "$(wc -l < "$STUB_LOG")" == "$BEFORE_EVICT" ]]; then pass "evicted session events ignored"; else
  fail "evicted session events ignored"; fi
sed 's/11111111-1111-4111-8111-111111111111/44444444-4444-4444-8444-444444444444/g' \
  "$FIX/session_end.json" > "$E2E_TMP/end444.json"
python3 "$REPORTER" < "$E2E_TMP/end444.json"
assert_log_contains "$STUB_LOG" "--agent-session-id 44444444-4444-4444-8444-444444444444 --seq 2" "rebound session ends with continuing seq"
if python3 -c "import json; d=json.load(open('$XDG_DATA_HOME/herdr-muse/bindings.json')); assert d=={}, d"; then
  pass "rebound binding removed after SessionEnd"
else fail "rebound binding removed after SessionEnd"; fi

BEFORE="$(wc -l < "$STUB_LOG")"
HERDR_MUSE_BIN="" run_reporter session_start
if [[ "$(wc -l < "$STUB_LOG")" == "$BEFORE" ]]; then pass "missing herdr binary exits silently"; else
  fail "missing herdr binary caused calls"; fi

echo "Phase 1: $PASS passed, $FAIL failed"

LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

if [[ "$LIVE" != 1 ]]; then
  echo "== Phase 2+3 skipped (pass --live to run against real Herdr + muse) =="
  [[ "$FAIL" == 0 ]] && exit 0 || exit 1
fi

echo "== Phase 2: live install + state transitions =="
[[ "${HERDR_ENV:-}" == 1 ]] || { echo "live tests need HERDR_ENV=1"; exit 2; }
MUSE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/muse"
SETTINGS="$MUSE_CONFIG_DIR/settings.json"
WORKDIR="/tmp/herdr-muse-e2e-work"
mkdir -p "$WORKDIR"
REAL_STATE_DIR="$HOME/.local/share/herdr-muse"
BINDINGS="$REAL_STATE_DIR/bindings.json"

unset XDG_DATA_HOME HERDR_MUSE_BIN STUB_LOG STUB_SHELL_PID

# Start from pristine settings (removes any earlier probe hooks).
cp /tmp/muse-settings-backup.json "$SETTINGS"
cp "$SETTINGS" "$E2E_TMP/settings.pristine.json"

THROWAWAY=""
cleanup_live() {
  "$REPO_DIR/uninstall.sh" >/dev/null 2>&1 || true
  if [[ -n "${INSTALL_BACKUP:-}" && -f "$INSTALL_BACKUP" ]]; then
    "$REPO_DIR/uninstall.sh" --restore-backup "$INSTALL_BACKUP" >/dev/null 2>&1 || true
  fi
  cp "$E2E_TMP/settings.pristine.json" "$SETTINGS"
  if [[ -n "$THROWAWAY" ]]; then
    herdr pane close "$THROWAWAY" >/dev/null 2>&1 || true
  fi
}
trap cleanup_live EXIT

"$REPO_DIR/install.sh" --yes
INSTALL_BACKUP="$(ls -t "$MUSE_CONFIG_DIR"/settings.json.pre-herdr-muse-* | head -n 1)"
[[ -x "$MUSE_CONFIG_DIR/hooks/herdr-muse.py" ]] \
  && pass "reporter installed" || fail "reporter installed"
python3 -c "import json; d=json.load(open('$SETTINGS')); assert any('herdr-muse' in str(g) for groups in d['hooks'].values() for g in groups)"
pass "settings contain herdr-muse hooks"

THROWAWAY="$(herdr pane split --current --direction right --cwd "$WORKDIR" --no-focus \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['pane']['pane_id'])")"
echo "  throwaway pane: $THROWAWAY"
rm -f "$BINDINGS"

herdr pane run "$THROWAWAY" "muse exec --provider echo 'e2e hello'" >/dev/null

pane_status() {
  herdr pane get "$THROWAWAY" 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)['result']
    pane = d.get('pane', d)
    print(pane.get('agent_status', 'unknown'))
except Exception:
    print('unknown')
"
}

SEEN=""
for _ in $(seq 1 100); do
  S="$(pane_status)"
  [[ "$SEEN" != *"$S"* ]] && SEEN="$SEEN $S"
  [[ "$S" == "idle" && "$SEEN" == *"working"* ]] && break
  sleep 0.2
done
echo "  states seen:$SEEN"
[[ "$SEEN" == *"working"* ]] && pass "live pane showed working" || fail "live pane showed working"
[[ "$(pane_status)" == "idle" ]] && pass "live pane settled idle" || fail "live pane settled idle"

if [[ ! -f "$BINDINGS" ]] || python3 -c "import json; assert json.load(open('$BINDINGS'))=={}"; then
  pass "binding released after SessionEnd"
else fail "binding released after SessionEnd"; fi

herdr pane wait-output "$THROWAWAY" --match "e2e hello" --timeout 15000 >/dev/null \
  && pass "exec completed in pane" || fail "exec completed in pane"

"$REPO_DIR/uninstall.sh" >/dev/null
python3 -c "
import json
now = json.load(open('$SETTINGS'))
before = json.load(open('$E2E_TMP/settings.pristine.json'))
assert now == before, 'settings differ after uninstall'
assert 'herdr-muse' not in json.dumps(now), 'herdr-muse remnants'
" && pass "uninstall restores settings content" || fail "uninstall restores settings content"
[[ ! -f "$MUSE_CONFIG_DIR/hooks/herdr-muse.py" ]] \
  && pass "reporter removed" || fail "reporter removed"

# Post-uninstall: hooks gone, exec still works, no new bindings.
rm -f "$BINDINGS"
herdr pane run "$THROWAWAY" "muse exec --provider echo 'post uninstall'" >/dev/null
herdr pane wait-output "$THROWAWAY" --match "post uninstall" --timeout 20000 >/dev/null \
  && pass "exec works after uninstall" || fail "exec works after uninstall"
if [[ ! -f "$BINDINGS" ]]; then pass "no bindings created after uninstall";
else fail "no bindings created after uninstall"; fi

echo "== Phase 3: plugin link validation =="
herdr plugin link "$REPO_DIR" >/dev/null \
  && pass "plugin link accepts manifest" || fail "plugin link accepts manifest"
herdr plugin action list 2>/dev/null | grep -q "herdr-muse" \
  && pass "plugin actions listed" || fail "plugin actions listed"
herdr plugin unlink herdr-muse >/dev/null \
  && pass "plugin unlink works" || fail "plugin unlink works"

trap - EXIT
cleanup_live
if cmp -s "$E2E_TMP/settings.pristine.json" "$SETTINGS"; then
  pass "settings byte-identical after e2e"
else fail "settings byte-identical after e2e"; fi

echo "TOTAL: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]] && exit 0 || exit 1
