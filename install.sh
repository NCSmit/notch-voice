#!/bin/bash
# Installs the Claude Code voice hook and the NotchVoice notch app. Run with --uninstall to remove both.
set -euo pipefail
cd "$(dirname "$0")"

HOOK="$HOME/.claude/hooks/speak.py"
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
    groups = []
    for group in hooks.get("Stop", []):
        group["hooks"] = [h for h in group.get("hooks", []) if "speak.py" not in h.get("command", "")]
        if group["hooks"]:
            groups.append(group)
    if groups:
        hooks["Stop"] = groups
    else:
        hooks.pop("Stop", None)
    if not hooks:
        settings.pop("hooks", None)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
EOF
  rm -f "$HOOK" "$HOME/.claude/tts_off" "$HOME/.claude/tts_voice"
  echo "NotchVoice and the voice hook are removed. Restart Claude Code."
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is missing. Install Xcode, or run: xcode-select --install"
  exit 1
fi

mkdir -p "$HOME/.claude/hooks"
if [[ -f "$HOOK" ]] && ! cmp -s hook/speak.py "$HOOK"; then
  cp "$HOOK" "$HOOK.bak"
  echo "Saved your previous speak.py as $HOOK.bak"
fi
cp hook/speak.py "$HOOK"
chmod +x "$HOOK"

python3 - "$SETTINGS" <<'EOF'
import json, os, shutil, sys

path = sys.argv[1]
settings = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            settings = json.load(f)
    except ValueError as error:
        sys.exit(f"Could not read {path} ({error}). Add a Stop hook running 'python3 ~/.claude/hooks/speak.py' by hand.")
stop = settings.setdefault("hooks", {}).setdefault("Stop", [])
if not any("speak.py" in h.get("command", "") for group in stop for h in group.get("hooks", [])):
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak")
    stop.append({"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/speak.py", "async": True, "timeout": 300}]})
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"Added the voice hook to {path}")
EOF

./build.sh --install
echo "Done. Restart Claude Code, then hover over the notch."
