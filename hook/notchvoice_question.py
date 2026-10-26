#!/usr/bin/env python3
"""PreToolUse hook for AskUserQuestion: shows Claude's question in the NotchVoice notch and answers it from there.

While this hook waits, Claude Code doesn't show its own question box. The card's "Answer in Claude" hands the question
back at once, and so do NotchVoice not running, its setting being off, or no answer within ten minutes. Answering is
documented for PreToolUse: "allow", plus updatedInput with the original questions and an `answers` map from each
question's text to the chosen label (labels joined with ", " when several are chosen, or the user's own words).
"""
import json
import os
import select
import socket
import sys
import time

from notchvoice_permission import log_request, user_temp_dir

# Then the question goes back to Claude. The hook's own timeout in install.sh is set above this.
ANSWER_WINDOW = 600
SOCKET = os.path.join(user_temp_dir(), "notchvoice_question.sock")


def ask_notch(request, window=ANSWER_WINDOW):
    """Shows the questions in the notch and waits. Returns (answers or None, outcome), the outcome for the log."""
    deadline = time.time() + window
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(SOCKET)
            connection.sendall((json.dumps(request) + "\n").encode())
            reply = b""
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
        answer = json.loads(reply)
    except ValueError:
        return None, "bad reply"
    answers = answer.get("answers") if isinstance(answer, dict) and answer.get("decision") == "answer" else None
    if isinstance(answers, dict) and answers and all(isinstance(text, str) for text in answers.values()):
        return answers, "answered in the notch"
    return None, "handed back to Claude"


def main():
    started = time.time()
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    tool_input = payload.get("tool_input")
    questions = tool_input.get("questions") if isinstance(tool_input, dict) else None
    if payload.get("tool_name") != "AskUserQuestion" or not isinstance(questions, list) or not questions:
        return
    answers, outcome = ask_notch({"questions": questions, "session_id": payload.get("session_id"), "cwd": payload.get("cwd")})
    log_request(payload, outcome, started)
    if not answers:
        return  # Claude shows its own question box
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Answered in the NotchVoice notch",
        "updatedInput": dict(tool_input, answers=answers),
    }}))


if __name__ == "__main__":
    main()
