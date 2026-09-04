#!/bin/bash
# Uninstall the Herdr reporter hooks for Muse Code.
#
# Usage: ./uninstall.sh [--restore-backup PATH]
#
# Removes Herdr hook entries (matched by herdr-muse description tag or by a
# herdr-muse.py command) from ~/.config/muse/settings.json and deletes the
# installed reporter. With --restore-backup, restores settings byte-identical
# from a backup created by install.sh instead.
set -euo pipefail

RESTORE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore-backup) RESTORE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--restore-backup PATH]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

MUSE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/muse"
SETTINGS="$MUSE_CONFIG_DIR/settings.json"
REPORTER="$MUSE_CONFIG_DIR/hooks/herdr-muse.py"

if [[ -n "$RESTORE" ]]; then
  [[ -f "$RESTORE" ]] || { echo "uninstall: backup not found: $RESTORE" >&2; exit 1; }
  cp "$RESTORE" "$SETTINGS"
  echo "uninstall: restored settings from $RESTORE"
fi

if [[ -f "$SETTINGS" ]]; then
  python3 - "$SETTINGS" <<'EOF'
import json, sys

settings_path = sys.argv[1]
with open(settings_path) as handle:
    settings = json.load(handle)

def is_ours(group):
    if not isinstance(group, dict):
        return False
    if isinstance(group.get("description"), str) and \
            group["description"].startswith("herdr-muse:"):
        return True
    hooks = group.get("hooks")
    if isinstance(hooks, list):
        for hook in hooks:
            if isinstance(hook, dict) and \
                    hook.get("command", "").endswith("herdr-muse.py"):
                return True
    return False

hooks = settings.get("hooks")
removed = 0
if isinstance(hooks, dict):
    for event in list(hooks.keys()):
        groups = hooks[event]
        if isinstance(groups, list):
            kept = [g for g in groups if not is_ours(g)]
            removed += len(groups) - len(kept)
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
    if not hooks:
        del settings["hooks"]
    with open(settings_path, "w") as handle:
        json.dump(settings, handle, indent=2)
        handle.write("\n")
print(f"uninstall: removed {removed} hook groups")
EOF
fi

if [[ -f "$REPORTER" ]]; then
  rm -f "$REPORTER"
  echo "uninstall: removed $REPORTER"
fi
echo "uninstall: done (start a new muse session for the change to take effect)"
