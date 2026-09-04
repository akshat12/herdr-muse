#!/bin/bash
# Test stub for the herdr CLI. Logs mutating calls, emulates read calls.
# Env: STUB_LOG (append log), STUB_SHELL_PID (pane shell pid to match).
set -euo pipefail

log() { echo "$*" >> "${STUB_LOG:?}"; }

case "${1:-}" in
  workspace)
    echo '{"id":"cli:workspace:list","result":{"workspaces":[{"workspace_id":"w9","label":"e2e","tab_count":1,"pane_count":1,"active_tab_id":"w9:t1","agent_status":"unknown","focused":false,"number":9}]}}'
    ;;
  pane)
    case "${2:-}" in
      list)
        echo '{"id":"cli:pane:list","result":{"type":"pane_list","panes":[{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","cwd":"/tmp/herdr-muse-e2e-work","foreground_cwd":"/tmp/herdr-muse-e2e-work","focused":false,"agent_status":"unknown"}]}}'
        ;;
      process-info)
        if [[ -n "${STUB_FOREGROUND_NAME:-}" ]]; then
          FG="[{\"pid\":99999,\"name\":\"${STUB_FOREGROUND_NAME}\",\"argv0\":\"${STUB_FOREGROUND_NAME}\",\"cmdline\":\"${STUB_FOREGROUND_NAME}\"}]"
        else
          FG="[]"
        fi
        echo "{\"id\":\"cli:pane:process_info\",\"result\":{\"process_info\":{\"pane_id\":\"w9:p1\",\"shell_pid\":${STUB_SHELL_PID:?},\"foreground_process_group_id\":${STUB_SHELL_PID},\"foreground_processes\":$FG},\"type\":\"pane_process_info\"}}"
        ;;
      report-agent|release-agent)
        log "herdr $*"
        echo '{"id":"cli:pane:ok","result":{"type":"ok"}}'
        ;;
      *)
        echo '{"error":{"code":"stub_unknown","message":"stub"}}' >&2; exit 1 ;;
    esac
    ;;
  *)
    echo '{"error":{"code":"stub_unknown","message":"stub"}}' >&2; exit 1 ;;
esac
