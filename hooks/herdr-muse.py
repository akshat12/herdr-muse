#!/usr/bin/env python3
"""Herdr reporter for Muse Code lifecycle hooks.

Installed as a Muse `command` hook (SessionStart, UserPromptSubmit,
PreToolUse, PermissionRequest, Stop, SessionEnd). Reads the hook payload
from stdin and reports pane state to the local Herdr server with source
`custom:muse`.

Design notes:
  - Muse hooks run with a cleared environment: HERDR_ENV, HERDR_PANE_ID and
    HERDR_BIN_PATH are NOT visible here. The target pane is resolved by
    matching this process's own ancestor PIDs against each pane's shell PID
    and foreground PIDs from `herdr pane process-info`.
  - The first SessionStart wins per pane. Later events carrying an unknown
    session_id (subagents, background observers) are ignored so child turns
    can never flip the lead pane's state.
  - This script must never break the agent: every failure path exits 0 and
    prints nothing to stdout (hook stdout can influence agent behavior).
"""

import json
import os
import shutil
import subprocess
import sys

SOURCE = "custom:muse"
AGENT_LABEL = "muse"
STATE_DIR = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
    "herdr-muse",
)
BINDINGS_PATH = os.path.join(STATE_DIR, "bindings.json")


def find_herdr():
    override = os.environ.get("HERDR_MUSE_BIN")
    if override is not None:
        # Explicit override: empty string disables reporting (used by tests).
        return override if override and os.access(override, os.X_OK) else None
    found = shutil.which("herdr")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"):
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def herdr_json(binary, *args):
    try:
        proc = subprocess.run(
            [binary, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None


def herdr_call(binary, *args):
    try:
        proc = subprocess.run(
            [binary, *args],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def ancestor_pids():
    """Return the set of this process's ancestor PIDs (walk /proc or ps)."""
    pids = set()
    try:
        pid = os.getppid()
        seen = 0
        while pid > 1 and seen < 64:
            pids.add(pid)
            try:
                with open(f"/proc/{pid}/stat") as handle:
                    parts = handle.read().rsplit(")", 1)
                    ppid = int(parts[1].split()[1])
            except (OSError, ValueError, IndexError):
                ppid = ps_ppid(pid)
            if ppid <= 0 or ppid == pid:
                break
            pid = ppid
            seen += 1
    except OSError:
        pass
    return pids


def ps_ppid(pid):
    try:
        proc = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        return int(proc.stdout.decode().strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


def load_bindings():
    try:
        with open(BINDINGS_PATH) as handle:
            data = json.load(handle)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_bindings(bindings):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = BINDINGS_PATH + ".tmp"
        with open(tmp, "w") as handle:
            json.dump(bindings, handle, indent=2)
        os.replace(tmp, BINDINGS_PATH)
    except OSError:
        pass


def iter_panes(binary):
    snapshot = herdr_json(binary, "workspace", "list")
    if not snapshot:
        return
    try:
        workspaces = snapshot["result"]["workspaces"]
    except (KeyError, TypeError):
        return
    for workspace in workspaces:
        wid = workspace.get("workspace_id")
        if not wid:
            continue
        listing = herdr_json(binary, "pane", "list", "--workspace", wid)
        if not listing:
            continue
        try:
            panes = listing["result"]["panes"]
        except (KeyError, TypeError):
            continue
        for pane in panes:
            if isinstance(pane, dict) and pane.get("pane_id"):
                yield pane


def resolve_pane(binary, ancestors):
    """Find the pane hosting this process via shell/foreground PID match."""
    fallback = None
    try:
        hook_cwd = os.path.realpath(os.environ.get("PWD", ""))
    except OSError:
        hook_cwd = ""
    for pane in iter_panes(binary):
        pane_id = pane["pane_id"]
        info = herdr_json(binary, "pane", "process-info", "--pane", pane_id)
        try:
            proc_info = info["result"]["process_info"]
        except (KeyError, TypeError):
            continue
        candidates = set()
        shell_pid = proc_info.get("shell_pid")
        if isinstance(shell_pid, int):
            candidates.add(shell_pid)
        for foreground in proc_info.get("foreground_processes", []) or []:
            pid = foreground.get("pid") if isinstance(foreground, dict) else None
            if isinstance(pid, int):
                candidates.add(pid)
        if ancestors & candidates:
            return pane_id
        if fallback is None and hook_cwd:
            for key in ("cwd", "foreground_cwd"):
                try:
                    if os.path.realpath(pane.get(key) or "") == hook_cwd:
                        fallback = pane_id
                except OSError:
                    continue
    return fallback


def pane_has_muse(binary, pane_id):
    """True when the pane still runs a muse foreground process."""
    info = herdr_json(binary, "pane", "process-info", pane_id)
    try:
        processes = info["result"]["process_info"].get("foreground_processes", [])
    except (KeyError, TypeError):
        return True
    for proc in processes or []:
        if not isinstance(proc, dict):
            continue
        for key in ("name", "argv0", "cmdline"):
            value = proc.get(key)
            if isinstance(value, str) and "muse" in value.lower():
                return True
    return False


def report(binary, pane_id, state, session_id, seq, message=None):
    cmd = [
        "pane", "report-agent", pane_id,
        "--source", SOURCE,
        "--agent", AGENT_LABEL,
        "--state", state,
        "--agent-session-id", session_id,
        "--seq", str(seq),
    ]
    if message:
        cmd += ["--message", message[:500]]
    return herdr_call(binary, *cmd)


def release(binary, pane_id):
    return herdr_call(
        binary, "pane", "release-agent", pane_id,
        "--source", SOURCE, "--agent", AGENT_LABEL,
    )


def permission_message(payload):
    for key in ("question", "prompt", "message", "title"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    tool = payload.get("tool_name") or payload.get("toolName")
    if isinstance(tool, str) and tool:
        return f"approval requested: {tool}"
    return "approval requested"


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    event = payload.get("hook_event_name", "")
    session_id = payload.get("session_id", "")
    if not event or not session_id:
        return 0

    binary = find_herdr()
    if binary is None:
        return 0

    bindings = load_bindings()
    binding = bindings.get(session_id)

    if event == "SessionStart":
        if binding and binding.get("pane_id"):
            return 0
        pane_id = resolve_pane(binary, ancestor_pids())
        if pane_id is None:
            return 0
        for known_session, known in list(bindings.items()):
            if known.get("pane_id") == pane_id and known_session != session_id:
                if pane_has_muse(binary, pane_id):
                    return 0
                del bindings[known_session]
        bindings[session_id] = {"pane_id": pane_id, "seq": 1}
        save_bindings(bindings)
        report(binary, pane_id, "idle", session_id, 1)
        return 0

    if binding is None or not binding.get("pane_id"):
        return 0
    pane_id = binding["pane_id"]
    seq = int(binding.get("seq", 0)) + 1

    if event in ("UserPromptSubmit", "PreToolUse"):
        binding["seq"] = seq
        save_bindings(bindings)
        report(binary, pane_id, "working", session_id, seq)
    elif event == "PermissionRequest":
        binding["seq"] = seq
        save_bindings(bindings)
        report(binary, pane_id, "blocked", session_id, seq,
               permission_message(payload))
    elif event == "Stop":
        binding["seq"] = seq
        save_bindings(bindings)
        report(binary, pane_id, "idle", session_id, seq)
    elif event == "SessionEnd":
        del bindings[session_id]
        save_bindings(bindings)
        report(binary, pane_id, "idle", session_id, seq)
        release(binary, pane_id)
    return 0


if __name__ == "__main__":
    main()
