#!/usr/bin/env python3
"""Session hook: keeps a small status file per Claude Code session, so the menu bar can list what each one is doing.

Registered (async) for SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Stop and SessionEnd.
Each event rewrites ~/.claude/notchvoice/sessions/<session_id>.json with:
  state     "working", "waiting" (needs an answer from you), "idle" (finished its reply) or "ended"
  title     the session's first prompt, shortened
  activity  what it is doing right now, or the start of its last reply once it is idle
  project   the folder it runs in; cwd and transcript_path are kept too, for tools that want the full picture
  updated   when the event happened, and started when the first one did, in seconds since 1970
  pid       the Claude Code process, and process its name, so the app can tell when the session has closed (pid is
            null when ps couldn't find it, and the app then goes by age)
  app       the bundle id of the app the session runs in, and tty its terminal, so the app can bring it forward
Async hooks can finish out of order, so an event never overwrites a newer one.

It also decides which session is the orchestrator, for speak.py, the brief hook and the orchestrator's helper.
"""
import json
import os
import re
import subprocess
import sys
import time

NOTCHVOICE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "notchvoice")
SESSIONS_DIR = os.path.join(NOTCHVOICE_DIR, "sessions")
# {"session_id": ...} of the session that ran /orchestrator. While that session is open, only its replies are spoken.
ORCHESTRATOR_FILE = os.path.join(NOTCHVOICE_DIR, "orchestrator.json")
TITLE_LENGTH = 60
ACTIVITY_LENGTH = 90
STATES = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "PermissionRequest": "waiting",
    "Stop": "idle",
    "SessionEnd": "ended",
}
# Tools that stop and wait for an answer, with what to show while they wait.
WAITING_TOOLS = {"AskUserQuestion": "Needs you: a question", "ExitPlanMode": "Needs you: a plan to approve"}
SHELLS = {"sh", "bash", "zsh", "dash", "fish"}
# Without a process to check, a session counts as open for this long after its last event, as in the app.
IDLE_LIFETIME = 15 * 60
WORKING_LIFETIME = 2 * 60 * 60


def shorten(text, limit):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def first_sentence(text):
    text = re.sub(r"```.*?```", " ", text or "", flags=re.S)
    text = re.sub(r"[*_`#>]", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    match = re.match(r"(.+?[.!?])(\s|$)", text)
    return match.group(1) if match else text


def file_name(tool_input):
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or tool_input.get("path") or ""
    return os.path.basename(path.rstrip("/")) if isinstance(path, str) else ""


def activity_for(tool, tool_input):
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    name = file_name(tool_input)
    if tool == "Bash":
        return "Running " + (tool_input.get("description") or tool_input.get("command") or "a command")
    if tool in ("Edit", "MultiEdit", "Write", "NotebookEdit"):
        return f"Editing {name}" if name else "Editing a file"
    if tool == "Read":
        return f"Reading {name}" if name else "Reading a file"
    if tool in ("Grep", "Glob"):
        return "Searching the code"
    if tool in ("WebFetch", "WebSearch"):
        return "Searching the web"
    if tool in ("Agent", "Task"):
        return "Running an agent: " + (tool_input.get("description") or "")
    if tool.startswith("mcp__"):
        parts = [part for part in tool.split("__") if part]
        return "Using " + (parts[-1] if parts else tool).replace("_", " ")
    return f"Using {tool}" if tool else "Working"


def process_info(pid):
    """The parent pid, terminal and name of a process, from ps."""
    try:
        result = subprocess.run(["ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return None
    fields = result.stdout.strip().split(None, 2)
    if len(fields) != 3 or not fields[0].isdigit():
        return None
    return int(fields[0]), fields[1], os.path.basename(fields[2])


def claude_process():
    """The Claude Code process that ran this hook. A shell between the two is skipped."""
    pid = os.getppid()
    for _ in range(2):
        info = process_info(pid)
        if info is None:
            return {}
        parent, tty, name = info
        if name.lstrip("-") not in SHELLS:
            found = {"pid": pid, "process": name}
            if re.fullmatch(r"ttys?\d+", tty):
                found["tty"] = "/dev/" + tty
            return found
        pid = parent
    return {}


def is_open(status, now=None, check_name=True):
    """Whether a status file belongs to a session that is still open, decided the same way as the app's menu.
    Checking the process name guards against a reused pid, but costs a ps call, so frequent callers can skip it."""
    if not isinstance(status, dict) or status.get("state") not in ("working", "waiting", "idle"):
        return False
    pid, process = status.get("pid"), status.get("process")
    if isinstance(pid, int) and isinstance(process, str):
        try:
            os.kill(pid, 0)
        except PermissionError:
            pass
        except OSError:
            return False
        if not check_name:
            return True
        info = process_info(pid)
        return info is not None and info[2] == process
    try:
        age = (now or time.time()) - float(status.get("updated") or 0)
    except (TypeError, ValueError):
        return False
    return age < (IDLE_LIFETIME if status.get("state") == "idle" else WORKING_LIFETIME)


def orchestrator(check_name=True):
    """The session id of the orchestrator while it is open, or None when every session speaks."""
    session = read(ORCHESTRATOR_FILE).get("session_id")
    if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", session):
        return None
    return session if is_open(read(os.path.join(SESSIONS_DIR, f"{session}.json")), check_name=check_name) else None


def read(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write(path, data):
    temp = f"{path}.{os.getpid()}.tmp"
    with open(temp, "w") as f:
        json.dump(data, f)
    os.replace(temp, path)


def updated_status(previous, payload, now, process=None):
    event = payload.get("hook_event_name", "")
    status = dict(previous)
    status["state"] = STATES[event]
    if process is not None:
        for key in ("pid", "process", "tty", "app"):
            status.pop(key, None)
        status.update(process or {"pid": None})
        app = os.environ.get("__CFBundleIdentifier")
        if app:
            status["app"] = app
    status["updated"] = now
    status.setdefault("started", now)
    for key in ("session_id", "cwd", "transcript_path"):
        if payload.get(key):
            status[key] = payload[key]
    if payload.get("cwd"):
        status["project"] = os.path.basename(payload["cwd"].rstrip("/")) or payload["cwd"]
    if event == "UserPromptSubmit":
        prompt = payload.get("prompt") or ""
        if not status.get("title") and prompt.strip():
            status["title"] = shorten(prompt, TITLE_LENGTH)
        status["activity"] = "Thinking"
    elif event in ("PreToolUse", "PermissionRequest") and payload.get("tool_name") in WAITING_TOOLS:
        status["state"] = "waiting"
        status["activity"] = WAITING_TOOLS[payload["tool_name"]]
    elif event in ("PreToolUse", "PermissionRequest"):
        activity = activity_for(payload.get("tool_name", ""), payload.get("tool_input"))
        status["activity"] = shorten(("Needs you: " if event == "PermissionRequest" else "") + activity, ACTIVITY_LENGTH)
    elif event == "PostToolUse":
        status["activity"] = "Thinking"
    elif event == "Stop":
        summary = first_sentence(payload.get("last_assistant_message") or "")
        status["activity"] = shorten(summary, ACTIVITY_LENGTH) if summary else "Done"
    elif event == "SessionStart":
        status.setdefault("activity", "Ready")
    return status


def main():
    now = time.time()
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(payload, dict) or payload.get("hook_event_name") not in STATES:
        return
    session = payload.get("session_id")
    if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", session):
        return
    try:
        os.makedirs(SESSIONS_DIR, exist_ok=True)
        path = os.path.join(SESSIONS_DIR, f"{session}.json")
        previous = read(path)
        event = payload["hook_event_name"]
        if previous.get("updated", 0) > now or (previous.get("state") == "ended" and event != "SessionStart"):
            return
        # Looked up once per process, even when ps finds nothing: a resumed session runs in a new one, and starts with
        # SessionStart.
        process = claude_process() if event == "SessionStart" or "pid" not in previous else None
        write(path, updated_status(previous, payload, now, process))
    except OSError:
        pass


if __name__ == "__main__":
    main()
