#!/bin/bash
# Install the Herdr reporter hooks for Muse Code.
#
# Usage: ./install.sh [--yes] [--hook-dir DIR]
#
# Writes hooks/herdr-muse.py into the Muse user hooks directory and merges
# Herdr hook entries into ~/.config/muse/settings.json (backed up first).
# Safe to re-run: entries are matched by hook id and replaced in place.
set -euo pipefail

YES=0
HOOK_DIR=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --hook-dir) HOOK_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--yes] [--hook-dir DIR]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

MUSE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/muse"
SETTINGS="$MUSE_CONFIG_DIR/settings.json"
HOOK_DIR="${HOOK_DIR:-$MUSE_CONFIG_DIR/hooks}"
REPORTER="$HOOK_DIR/herdr-muse.py"

command -v python3 >/dev/null 2>&1 \
  || { echo "install: python3 is required" >&2; exit 1; }
[[ -d "$MUSE_CONFIG_DIR" ]] \
  || { echo "install: $MUSE_CONFIG_DIR does not exist (run muse once first)" >&2; exit 1; }
[[ -f "$SETTINGS" ]] \
  || { echo "install: $SETTINGS does not exist (run muse once first)" >&2; exit 1; }
command -v herdr >/dev/null 2>&1 \
  || echo "install: warning: herdr not on PATH; reports will no-op until it is" >&2

mkdir -p "$HOOK_DIR"
cp "$SCRIPT_DIR/hooks/herdr-muse.py" "$REPORTER"
chmod +x "$REPORTER"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$SETTINGS.pre-herdr-muse-$STAMP"
cp "$SETTINGS" "$BACKUP"

REPORTER="$REPORTER" BACKUP_CHECK="$BACKUP" python3 - "$SETTINGS" <<'EOF'
import json, os, sys

settings_path = sys.argv[1]
with open(settings_path) as handle:
    raw = handle.read()
try:
    settings = json.loads(raw)
except ValueError as exc:
    print(f"install: {settings_path} is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

reporter = os.environ["REPORTER"]
entries = [
    ("herdr-muse-session-start", "SessionStart"),
    ("herdr-muse-prompt", "UserPromptSubmit"),
    ("herdr-muse-pre-tool", "PreToolUse"),
    ("herdr-muse-permission", "PermissionRequest"),
    ("herdr-muse-stop", "Stop"),
    ("herdr-muse-session-end", "SessionEnd"),
]

hooks = settings.get("hooks")
if hooks is None:
    hooks = {}
if isinstance(hooks, list):
    print("install: settings 'hooks' is an array; expected an object keyed by event.",
          file=sys.stderr)
    print("install: refusing to modify; restore from backup if needed.", file=sys.stderr)
    sys.exit(1)
if not isinstance(hooks, dict):
    print("install: settings 'hooks' has an unexpected type; refusing to modify.",
          file=sys.stderr)
    sys.exit(1)

for hook_id, event in entries:
    group = [{
        "matcher": "",
        "hooks": [{"type": "command", "command": reporter}],
    }]
    hooks[event] = [
        g for g in hooks.get(event, [])
        if not (isinstance(g, dict) and any(
            isinstance(h, dict) and h.get("command", "").endswith("herdr-muse.py")
            for h in (g.get("hooks", []) if isinstance(g.get("hooks"), list) else [])
        ))
    ] + group

settings["hooks"] = hooks
with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print(f"install: merged {len(entries)} hook events; backup at {os.environ['BACKUP_CHECK']}")
EOF

echo "install: reporter at $REPORTER"
if [[ "$YES" != 1 ]]; then
  echo "install: start a new muse session for hooks to load."
fi
