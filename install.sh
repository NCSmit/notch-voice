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
    session_events = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd")
    entries = [("Stop", "speak.py"), ("PermissionRequest", "notchvoice_permission.py"), ("UserPromptSubmit", "notchvoice_brief.py")]
    entries += [(event, "notchvoice_sessions.py") for event in session_events]
    for event, script in entries:
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
    permissions = settings.get("permissions", {})
    if "mcp__notchvoice__speak" in permissions.get("deny", []):
        permissions["deny"].remove("mcp__notchvoice__speak")
        if not permissions["deny"]:
            permissions.pop("deny")
        if not permissions:
            settings.pop("permissions")
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
EOF
  rm -f "$HOOKS/speak.py" "$HOOKS/notchvoice_permission.py" "$HOOKS/notchvoice_brief.py" "$HOOKS/notchvoice_mcp.py" "$HOOKS/notchvoice_sessions.py" "$HOME/.claude/tts_off" "$HOME/.claude/tts_settings.json"
  rm -rf "$HOME/.claude/notchvoice/sessions" "$HOME/.claude/skills/orchestrator"
  rm -f "$HOME/.claude/notchvoice/orchestrator.json"
  rmdir "$HOME/.claude/notchvoice" 2>/dev/null || true
  python3 hook/notchvoice_desktop.py
  echo "NotchVoice and its hooks are removed. Restart Claude Code."
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is missing. Install Xcode, or run: xcode-select --install"
  exit 1
fi

mkdir -p "$HOOKS"
for script in speak.py notchvoice_permission.py notchvoice_brief.py notchvoice_mcp.py notchvoice_sessions.py; do
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
sessions_hook = {"type": "command", "command": "python3 ~/.claude/hooks/notchvoice_sessions.py", "async": True, "timeout": 10}
wanted = [
    ("Stop", {"type": "command", "command": "python3 ~/.claude/hooks/speak.py", "async": True, "timeout": 300}),
    ("PermissionRequest", {"type": "command", "command": "python3 ~/.claude/hooks/notchvoice_permission.py", "timeout": 600}),
    ("UserPromptSubmit", {"type": "command", "command": "python3 ~/.claude/hooks/notchvoice_brief.py", "timeout": 10}),
] + [(event, sessions_hook) for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd")]
# SessionStart runs in the foreground so it can hand a compacted session back its saved working state.
wanted.append(("SessionStart", {k: v for k, v in sessions_hook.items() if k != "async"}))
tool_events = {"PreToolUse", "PostToolUse", "PermissionRequest"}
hooks = settings.setdefault("hooks", {})
added = []
for event, hook in wanted:
    script = hook["command"].rsplit("/", 1)[-1]
    groups = hooks.setdefault(event, [])
    existing = [h for group in groups for h in group.get("hooks", []) if script in h.get("command", "")]
    for h in existing:
        if h != hook:  # an older install registered it differently
            h.clear()
            h.update(hook)
            if event not in added:
                added.append(event)
    if not existing:
        groups.append({"matcher": "*", "hooks": [dict(hook)]} if event in tool_events else {"hooks": [dict(hook)]})
        if event not in added:
            added.append(event)
deny = settings.setdefault("permissions", {}).setdefault("deny", [])
blocked = "mcp__notchvoice__speak" not in deny
if blocked:
    deny.append("mcp__notchvoice__speak")
if added or blocked:
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak")
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
if added:
    print(f"Added the {', '.join(added)} hook{'s' if len(added) > 1 else ''} to {path}")
if blocked:
    print("Denied the desktop speak tool in Claude Code, which reads its replies aloud with the Stop hook.")
EOF

mkdir -p "$HOME/.claude/skills/orchestrator"
cp orchestrator/SKILL.md orchestrator/snapshot.py "$HOME/.claude/skills/orchestrator/"
echo "Installed the /orchestrator command for Claude Code."

./build.sh --install
python3 hook/notchvoice_desktop.py
echo "Done. Restart Claude Code, then hover over the notch."
