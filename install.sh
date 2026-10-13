#!/bin/bash
# Installs the Claude Code hooks and the NotchVoice notch app. Run with --uninstall to remove them.
set -euo pipefail
cd "$(dirname "$0")"

HOOKS="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
APP="$HOME/Applications/NotchVoice.app"

if [[ "${1:-}" == "--uninstall" ]]; then
  pkill -x NotchVoice || true
  if [[ -x "$APP/Contents/MacOS/NotchVoice" ]]; then
    "$APP/Contents/MacOS/NotchVoice" --unregister-login-item || true
  fi
  rm -rf "$APP"
  python3 - "$SETTINGS" <<'EOF'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)
    hooks = settings.get("hooks", {})
    for event, script in (("Stop", "speak.py"), ("PermissionRequest", "notchvoice_permission.py"), ("UserPromptSubmit", "notchvoice_brief.py")):
        groups = []
        for group in hooks.get(event, []):
            group["hooks"] = [h for h in group.get("hooks", []) if script not in h.get("command", "")]
            if group["hooks"]:
                groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop("hooks", None)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
EOF
  rm -f "$HOOKS/speak.py" "$HOOKS/notchvoice_permission.py" "$HOOKS/notchvoice_brief.py" "$HOME/.claude/tts_off" "$HOME/.claude/tts_settings.json"
  echo "NotchVoice and its hooks are removed. Restart Claude Code."
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is missing. Install Xcode, or run: xcode-select --install"
  exit 1
fi

mkdir -p "$HOOKS"
for script in speak.py notchvoice_permission.py notchvoice_brief.py; do
  if [[ -f "$HOOKS/$script" ]] && ! cmp -s "hook/$script" "$HOOKS/$script"; then
    cp "$HOOKS/$script" "$HOOKS/$script.bak"
    echo "Saved your previous $script as $HOOKS/$script.bak"
  fi
  cp "hook/$script" "$HOOKS/$script"
  chmod +x "$HOOKS/$script"
done

python3 - "$SETTINGS" <<'EOF'
import json, os, shutil, sys

path = sys.argv[1]
settings = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            settings = json.load(f)
    except ValueError as error:
        sys.exit(f"Could not read {path} ({error}). Add the hooks from the README by hand.")
wanted = {
    "Stop": {"type": "command", "command": "python3 ~/.claude/hooks/speak.py", "async": True, "timeout": 300},
    "PermissionRequest": {"type": "command", "command": "python3 ~/.claude/hooks/notchvoice_permission.py", "timeout": 600},
    "UserPromptSubmit": {"type": "command", "command": "python3 ~/.claude/hooks/notchvoice_brief.py", "timeout": 10},
}
hooks = settings.setdefault("hooks", {})
added = []
for event, hook in wanted.items():
    script = hook["command"].rsplit("/", 1)[-1]
    groups = hooks.setdefault(event, [])
    if not any(script in h.get("command", "") for group in groups for h in group.get("hooks", [])):
        groups.append({"matcher": "*", "hooks": [hook]} if event == "PermissionRequest" else {"hooks": [hook]})
        added.append(event)
if added:
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak")
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"Added the {', '.join(added)} hook{'s' if len(added) > 1 else ''} to {path}")
EOF

./build.sh --install
echo "Done. Restart Claude Code, then hover over the notch."
