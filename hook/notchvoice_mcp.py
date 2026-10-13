#!/usr/bin/env python3
"""MCP server that lets regular chats in the Claude desktop app speak through NotchVoice.

It offers one tool, speak, which reads a short message aloud with the same voice, glow and music ducking as
Claude Code's spoken replies, because it runs speak.py. Claude Code reads its replies aloud with the Stop hook, so
the tool must stay out of it. When Claude Code starts this server itself, the server offers nothing. The desktop app
shares the servers it starts with its Code sessions too, so there the installer denies the tool in settings.json and
the instructions tell Claude Code to leave it alone.
"""
import json
import os
import subprocess
import sys

SPEAK_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "speak.py")
MUTE_FILE = os.path.join(os.path.expanduser("~"), ".claude", "tts_off")
IN_CLAUDE_CODE = bool(os.environ.get("CLAUDECODE"))

INSTRUCTIONS = (
    "The user listens to your replies through NotchVoice. In a chat, call the speak tool once at the end of every "
    "reply with a spoken version of your answer: one to three short, plain sentences with the main point, and no "
    "markdown, code or links. If you are Claude Code, never call it, because Claude Code already reads your final "
    "reply aloud."
)
SPEAK_TOOL = {
    "name": "speak",
    "title": "Speak aloud",
    "description": "Read a short message aloud to the user through NotchVoice on their Mac. Use one to three plain sentences.",
    "inputSchema": {
        "type": "object",
        "properties": {"text": {"type": "string", "description": "What to say, in plain spoken language."}},
        "required": ["text"],
    },
    "annotations": {"destructiveHint": False, "openWorldHint": False},
}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def speak(text):
    if os.path.exists(MUTE_FILE):
        return "Voice replies are off in NotchVoice, so nothing was spoken."
    process = subprocess.Popen(
        [sys.executable, SPEAK_HOOK], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        text=True, start_new_session=True,
    )
    process.stdin.write(json.dumps({"last_assistant_message": text}))
    process.stdin.close()
    return "Speaking."


def result_for(method, params):
    if method == "initialize":
        result = {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "notchvoice", "version": "1.4"},
        }
        if not IN_CLAUDE_CODE:
            result["instructions"] = INSTRUCTIONS
        return result
    if method == "tools/list":
        return {"tools": [] if IN_CLAUDE_CODE else [SPEAK_TOOL]}
    if method == "tools/call" and params.get("name") == "speak" and not IN_CLAUDE_CODE:
        text = str((params.get("arguments") or {}).get("text") or "").strip()
        if not text:
            return {"content": [{"type": "text", "text": "There was nothing to say."}], "isError": True}
        return {"content": [{"type": "text", "text": speak(text)}]}
    if method == "ping":
        return {}
    return None


def handle(message):
    if message.get("id") is None:
        return
    result = result_for(message.get("method"), message.get("params") or {})
    if result is None:
        send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": f"Unknown method or tool: {message.get('method')}"}})
    else:
        send({"jsonrpc": "2.0", "id": message["id"], "result": result})


def main():
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if isinstance(message, dict):
            handle(message)


if __name__ == "__main__":
    main()
