#!/usr/bin/env python3
"""PreToolUse hook for AskUserQuestion: show the question in the NotchVoice notch and answer it from there.

While this hook waits, Claude Code doesn't show its own question box. The notch card has "Answer in Claude", which
hands the question back at once; so does NotchVoice not running, or no answer within ten minutes. Answering is
documented for PreToolUse: allow plus updatedInput with the original questions and an `answers` map of question text
to the chosen label (labels joined with ", " for multi-select, or the user's own text for "Other").
"""
import json
import os
import select
import socket
import sys
import tempfile
import time

DARWIN_USER_TEMP_DIR = 65537  # _CS_DARWIN_USER_TEMP_DIR in <unistd.h>
ANSWER_WINDOW = 600  # then hand the question back to Claude (the hook's own timeout is set above this)
LOG_FILE = os.path.join(os.path.expanduser("~"), ".claude", "notchvoice", "permissions.log")


def user_temp_dir():
    try:
        return os.confstr(DARWIN_USER_TEMP_DIR) or tempfile.gettempdir()
    except (OSError, ValueError):
        return tempfile.gettempdir()


SOCKET = os.path.join(user_temp_dir(), "notchvoice_question.sock")


def ask_notch(request, window=ANSWER_WINDOW):
    """Returns (answers or None, outcome)."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(SOCKET)
            connection.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            deadline = time.time() + window
            while not reply.endswith(b"\n"):
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None, "no answer in time"
                readable, _, _ = select.select([connection], [], [], min(remaining, 1.0))
                if readable:
                    chunk = connection.recv(65536)
                    if not chunk:
                        return None, "notch app went away"
                    reply += chunk
    except OSError:
        return None, "notch app not reachable"
    try:
        data = json.loads(reply)
    except ValueError:
        return None, "bad reply"
    answers = data.get("answers")
    if data.get("decision") == "answer" and isinstance(answers, dict) and answers:
        return answers, "answered in the notch"
    return None, "handed back to Claude"


def log_request(payload, outcome, started):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps({
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "session": payload.get("session_id"),
                "mode": payload.get("permission_mode"),
                "tool": "AskUserQuestion",
                "outcome": outcome,
                "seconds": round(time.time() - started, 1),
            }) + "\n")
    except OSError:
        pass


def main():
    started = time.time()
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    if payload.get("tool_name") != "AskUserQuestion":
        return
    tool_input = payload.get("tool_input") or {}
    questions = tool_input.get("questions")
    if not isinstance(questions, list) or not questions:
        return
    answers, outcome = ask_notch({
        "questions": questions,
        "session_id": payload.get("session_id"),
        "cwd": payload.get("cwd"),
    })
    log_request(payload, outcome, started)
    if not answers:
        return  # Claude shows its own question box
    updated = dict(tool_input)
    updated["answers"] = answers
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Answered in the NotchVoice notch",
        "updatedInput": updated,
    }}))


if __name__ == "__main__":
    main()
