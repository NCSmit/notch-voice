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

SOCKET = os.path.join(tempfile.gettempdir(), "notchvoice.sock")
# These need a real answer in Claude's own UI, not a yes or no.
SKIPPED_TOOLS = {"AskUserQuestion", "ExitPlanMode"}
MAX_TEXT = 4000
KEY_FIELDS = ("command", "file_path", "notebook_path", "url", "query")
TAIL_BYTES = 512 * 1024


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


def ask_notch(request, transcript):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(SOCKET)
            connection.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n"):
                readable, _, _ = select.select([connection], [], [], 0.5)
                if readable:
                    chunk = connection.recv(4096)
                    if not chunk:
                        return None
                    reply += chunk
                elif transcript.answered_elsewhere():
                    return None
        return json.loads(reply).get("decision")
    except (OSError, ValueError):
        return None


def main():
    payload = json.load(sys.stdin)
    tool = payload.get("tool_name", "")
    if tool in SKIPPED_TOOLS:
        return
    tool_input = payload.get("tool_input") or {}
    transcript = Transcript(payload.get("transcript_path"), tool, tool_input)
    decision = ask_notch({
        "tool_name": tool,
        "tool_input": trimmed(tool_input),
        "cwd": payload.get("cwd"),
        "session_id": payload.get("session_id"),
    }, transcript)
    if decision == "allow":
        result = {"behavior": "allow"}
    elif decision == "deny":
        result = {"behavior": "deny", "message": "The user denied this from the notch."}
    else:
        return
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": result}}))


if __name__ == "__main__":
    main()
