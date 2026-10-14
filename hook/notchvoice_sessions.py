#!/usr/bin/env python3
"""Session hook: keeps a small status file per Claude Code session, so the notch can list what each one is doing.

Registered (async) for SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Stop and SessionEnd.
Each event rewrites ~/.claude/notchvoice/sessions/<session_id>.json with:
  state     "working", "waiting" (asking for permission), "idle" (finished its reply) or "ended"
  title     the session's first prompt, shortened
  activity  what it is doing right now, or the start of its last reply once it is idle
  project   the folder it runs in; cwd and transcript_path are kept too, for tools that want the full picture
  updated   when the event happened, in seconds since 1970
Async hooks can finish out of order, so an event never overwrites a newer one.

SessionStart is registered without async: after a compaction it hands the session back the working state it saved
to ~/.claude/notchvoice/handoffs/<session_id>.md, so nothing the orchestrator asked it to keep is lost.
"""
import json
import os
import re
import sys
import time

SESSIONS_DIR = os.path.join(os.path.expanduser("~"), ".claude", "notchvoice", "sessions")
# The orchestrator asks a session to save its working state here before it compacts; it is handed back afterwards.
HANDOFF_DIR = os.path.join(os.path.expanduser("~"), ".claude", "notchvoice", "handoffs")
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
    "PermissionDenied": "working",  # auto mode blocked an action; the session carries on
}
# Auto-mode blocks, one small JSON file each, shown briefly in the notch.
NOTICES_DIR = os.path.join(os.path.expanduser("~"), ".claude", "notchvoice", "notices")


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


def updated_status(previous, payload, now):
    event = payload.get("hook_event_name", "")
    status = dict(previous)
    status["state"] = STATES[event]
    status["updated"] = now
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
    elif event in ("PreToolUse", "PermissionRequest"):
        activity = activity_for(payload.get("tool_name", ""), payload.get("tool_input"))
        status["activity"] = shorten(("Needs you: " if event == "PermissionRequest" else "") + activity, ACTIVITY_LENGTH)
    elif event == "PostToolUse":
        status["activity"] = "Thinking"
    elif event == "PermissionDenied":
        status["activity"] = shorten("Blocked by auto mode: " + activity_for(payload.get("tool_name", ""), payload.get("tool_input")), ACTIVITY_LENGTH)
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
        if previous.get("updated", 0) > now or (previous.get("state") == "ended" and payload["hook_event_name"] != "SessionStart"):
            return
        write(path, updated_status(previous, payload, now))
    except OSError:
        pass
    if payload["hook_event_name"] == "SessionStart" and payload.get("source") == "compact":
        restore_handoff(session)
    if payload["hook_event_name"] == "PermissionDenied":
        write_notice(payload, session, now)


def write_notice(payload, session, now):
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    detail = tool_input.get("command") or tool_input.get("file_path") or tool_input.get("url") or ""
    notice = {
        "session_id": session,
        "project": os.path.basename((payload.get("cwd") or "").rstrip("/")),
        "title": activity_for(payload.get("tool_name", ""), tool_input),
        "detail": shorten(str(detail), 160),
        "reason": shorten(str(payload.get("reason") or ""), 160),
        "at": now,
    }
    try:
        os.makedirs(NOTICES_DIR, exist_ok=True)
        write(os.path.join(NOTICES_DIR, f"{int(now * 1000)}-{session}.json"), notice)
    except OSError:
        pass


def restore_handoff(session):
    try:
        with open(os.path.join(HANDOFF_DIR, f"{session}.md")) as f:
            notes = f.read(20000)
    except OSError:
        return
    if notes.strip():
        context = "Your conversation was just compacted. Before that, you saved this working state; carry on from it:\n\n" + notes
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}))


if __name__ == "__main__":
    main()
