#!/usr/bin/env python3
"""SessionStart hook for compactions: hands a session back the working state it saved before its context was compacted.

The orchestrator asks a session to write that state to ~/.claude/notchvoice/handoffs/<session_id>.md. This hook is
registered with the "compact" matcher and without async, so Claude waits for it and gets the state as context. Each
file is handed back once, then renamed to <session_id>.restored.md.
"""
import json
import os
import re
import sys

HANDOFF_DIR = os.path.join(os.path.expanduser("~"), ".claude", "notchvoice", "handoffs")
LIMIT = 20000


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    session = payload.get("session_id") if isinstance(payload, dict) else None
    if payload.get("source") != "compact" or not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", session):
        return
    path = os.path.join(HANDOFF_DIR, f"{session}.md")
    try:
        with open(path) as f:
            notes = f.read(LIMIT + 1)
    except OSError:
        return
    if not notes.strip():
        return
    if len(notes) > LIMIT:
        notes = notes[:LIMIT] + "\n\n[The rest of the saved state was cut off. The full file is " + path + ".]"
    context = "Your conversation was just compacted. Before that, you saved this working state; carry on from it:\n\n" + notes
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}))
    sys.stdout.flush()
    try:
        # Handed back once, so a later compaction doesn't bring back state the session has since moved past.
        os.replace(path, os.path.join(HANDOFF_DIR, f"{session}.restored.md"))
    except OSError:
        pass


if __name__ == "__main__":
    main()
