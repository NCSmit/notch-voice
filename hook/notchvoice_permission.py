#!/usr/bin/env python3
"""PermissionRequest hook: allow or deny Claude Code's permission requests from the NotchVoice notch.

Claude Code shows its own dialog at the same time, and whichever answer comes first wins. The request goes to the
NotchVoice app over a local socket. While it waits, the hook follows the session transcript and withdraws the request
from the notch once this tool call has a result, i.e. it was answered in Claude Code. Without the app, or with its
notch setting off, the hook exits without a decision.
"""
import json
import os
import select
import socket
import sys
import tempfile
import time

DARWIN_USER_TEMP_DIR = 65537  # _CS_DARWIN_USER_TEMP_DIR in <unistd.h>
# These need a real answer in Claude's own UI, not a yes or no.
SKIPPED_TOOLS = {"AskUserQuestion", "ExitPlanMode"}
MAX_TEXT = 4000
KEY_FIELDS = ("command", "file_path", "notebook_path", "url", "query")
TAIL_BYTES = 512 * 1024


def user_temp_dir():
    # The folder NSTemporaryDirectory() gives the app. TMPDIR can't be trusted for this, because tool servers started
    # by the Claude desktop app don't get it, and tempfile then falls back to /tmp.
    try:
        return os.confstr(DARWIN_USER_TEMP_DIR) or tempfile.gettempdir()
    except (OSError, ValueError):
        return tempfile.gettempdir()


SOCKET = os.path.join(user_temp_dir(), "notchvoice.sock")
# How long to keep trying to reach NotchVoice, which isn't there for a moment while it restarts.
CONNECT_GRACE = 6
# A card is sent again after NotchVoice restarts with it showing, but only a few times, in case the request itself is
# what keeps stopping the app.
RESENDS = 3
# One line per permission request and what happened to it, for finding out why a card didn't show. It holds the tool's
# name but never what it was asked to do.
LOG_FILE = os.path.join(os.path.expanduser("~"), ".claude", "notchvoice", "permissions.log")


def trimmed(value):
    if isinstance(value, str):
        return value if len(value) <= MAX_TEXT else value[:MAX_TEXT] + "…"
    if isinstance(value, dict):
        return {key: trimmed(item) for key, item in value.items()}
    if isinstance(value, list):
        return [trimmed(item) for item in value[:50]]
    return value


def blocks(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return []
    content = (entry.get("message") or {}).get("content")
    return [block for block in content if isinstance(block, dict)] if isinstance(content, list) else []


class Transcript:
    def __init__(self, path, tool, tool_input):
        self.path = path
        self.tool = tool
        self.tool_input = tool_input
        self.tool_use_id = None
        try:
            self.offset = max(0, os.path.getsize(path) - TAIL_BYTES)
        except (OSError, TypeError):
            self.path = None
            return
        uses, results = [], set()
        for block in self.new_blocks():
            if block.get("type") == "tool_use" and self.matches(block):
                uses.append(block.get("id"))
            elif block.get("type") == "tool_result":
                results.add(block.get("tool_use_id"))
        unanswered = [use for use in uses if use not in results]
        self.tool_use_id = unanswered[-1] if unanswered else None

    def new_blocks(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                data = f.read()
        except OSError:
            return []
        end = data.rfind(b"\n") + 1
        self.offset += end
        return [block for line in data[:end].splitlines() for block in blocks(line)]

    def matches(self, block):
        if block.get("name") != self.tool:
            return False
        given = block.get("input") or {}
        keys = [key for key in KEY_FIELDS if key in self.tool_input]
        return given == self.tool_input or (bool(keys) and all(given.get(key) == self.tool_input[key] for key in keys))

    def answered_elsewhere(self):
        if not self.path:
            return False
        for block in self.new_blocks():
            if block.get("type") == "tool_use" and self.tool_use_id is None and self.matches(block):
                self.tool_use_id = block.get("id")
            elif block.get("type") == "tool_result" and self.tool_use_id and block.get("tool_use_id") == self.tool_use_id:
                return True
        return False


class AppWentAway(Exception):
    """NotchVoice stopped without answering, because it quit or restarted while the card was showing."""


ANSWERED_IN_CLAUDE = object()


def ask_once(request, transcript):
    """Shows the request in the notch and waits for the answer, or for Claude's own prompt to be answered. Raises
    OSError when NotchVoice isn't running, AppWentAway when it stops while the card shows, and ValueError for a reply
    it can't read."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(SOCKET)
        try:
            connection.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n"):
                readable, _, _ = select.select([connection], [], [], 0.5)
                if readable:
                    chunk = connection.recv(4096)
                    if not chunk:
                        raise AppWentAway
                    reply += chunk
                elif transcript.answered_elsewhere():
                    return ANSWERED_IN_CLAUDE
        except OSError as error:
            raise AppWentAway from error
    answer = json.loads(reply)
    if not isinstance(answer, dict):
        raise ValueError("not an answer")
    return answer.get("decision")


def ask_notch(request, transcript):
    """Shows the request in the notch and waits for the answer. Returns (decision, outcome): the decision is "allow",
    "deny" or None, and the outcome says what happened, for the log. Each time NotchVoice can't be reached, the hook
    keeps trying for a few seconds, since the app may be restarting."""
    deadline = time.time() + CONNECT_GRACE
    resends = 0
    while True:
        try:
            decision = ask_once(request, transcript)
            if decision is ANSWERED_IN_CLAUDE:
                return None, "answered in Claude"
            return (decision if decision in ("allow", "deny") else None), f"notch: {decision}"
        except AppWentAway:
            if resends == RESENDS:
                return None, "notch app kept stopping"
            resends += 1
            deadline = time.time() + CONNECT_GRACE
        except OSError:
            pass
        except ValueError:
            return None, "bad reply"
        if transcript.answered_elsewhere():
            return None, "answered in Claude"
        if time.time() > deadline:
            return None, "notch app not reachable"
        time.sleep(0.5)


def log_request(payload, outcome, started):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 512 * 1024:
            os.replace(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps({
                "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "session": payload.get("session_id"),
                "mode": payload.get("permission_mode"),
                "tool": payload.get("tool_name"),
                "outcome": outcome,
                "seconds": round(time.time() - started, 1),
            }) + "\n")
    except OSError:
        pass


def main():
    started = time.time()
    payload = json.load(sys.stdin)
    tool = payload.get("tool_name", "")
    if tool in SKIPPED_TOOLS:
        log_request(payload, "skipped: answered in Claude's own UI", started)
        return
    tool_input = payload.get("tool_input") or {}
    transcript = Transcript(payload.get("transcript_path"), tool, tool_input)
    decision, outcome = ask_notch({
        "tool_name": tool,
        "tool_input": trimmed(tool_input),
        "cwd": payload.get("cwd"),
        "session_id": payload.get("session_id"),
    }, transcript)
    log_request(payload, outcome, started)
    if decision == "allow":
        result = {"behavior": "allow"}
    elif decision == "deny":
        result = {"behavior": "deny", "message": "The user denied this from the notch."}
    else:
        return
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": result}}))


if __name__ == "__main__":
    main()
