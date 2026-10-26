#!/usr/bin/env python3
"""UserPromptSubmit hook: while NotchVoice voice replies are on, remind Claude that its final reply is read aloud.

Claude gets this note with every prompt, so every session keeps its spoken replies short. It adds nothing while
voice replies are muted (~/.claude/tts_off exists) or when "brief" is false in ~/.claude/tts_settings.json. While
another session is the orchestrator, this one isn't heard, so it gets no note either.
"""
import json
import os
import sys

try:
    from notchvoice_sessions import orchestrator
except ImportError:  # installed without the sessions hook, so there is no orchestrator either
    def orchestrator():
        return None

MUTE_FILE = os.path.join(os.path.expanduser("~"), ".claude", "tts_off")
SETTINGS_FILE = os.path.join(os.path.expanduser("~"), ".claude", "tts_settings.json")
REMINDER = (
    "Voice replies are on, so your final message for this prompt is read aloud to the user. "
    "Keep it short: two to four plain sentences giving the high-level outcome. "
    "Leave out long lists, tables, code and file paths unless the user asks for them, and offer more detail instead of including it."
)


def wants_short_replies():
    try:
        with open(SETTINGS_FILE) as f:
            return json.load(f).get("brief", True) is not False
    except (OSError, ValueError, AttributeError):
        return True


def is_quiet_worker(payload):
    session = payload.get("session_id") if isinstance(payload, dict) else None
    if not session:
        return False
    boss = orchestrator()
    return bool(boss) and session != boss


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    if os.path.exists(MUTE_FILE) or not wants_short_replies() or is_quiet_worker(payload):
        return
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": REMINDER}}))


if __name__ == "__main__":
    main()
