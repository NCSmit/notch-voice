# Contributing to NotchVoice

Thanks for helping out. NotchVoice is a small project, so focused pull requests are the easiest to review and merge.

## How the project fits together

- **`Sources/NotchVoice/`** is the macOS app, built with SwiftUI and AppKit in Swift 6. It draws the notch panel, the glow and the settings window.
- **`hook/`** holds the three Claude Code hooks. They are Python scripts that use only the standard library:
  - `speak.py` is the `Stop` hook. It reads Claude's replies aloud.
  - `notchvoice_permission.py` is the `PermissionRequest` hook. It sends permission requests to the notch.
  - `notchvoice_brief.py` is the `UserPromptSubmit` hook. It asks Claude to keep spoken replies short.
- **`hook/notchvoice_mcp.py`** is a small MCP server for chats in the Claude desktop app. Its `speak` tool runs `speak.py` with the text Claude passes in.
- **`hook/notchvoice_desktop.py`** adds that server to the desktop app's config for `install.sh`, or removes it. The desktop app rewrites its config while it's open, so when it's open the script makes the change again after the app quits.
- **`Tests/`** and **`hook/tests/`** hold the tests for the app and the hooks.

The app and the hooks never call each other directly. They share a few files in `~/.claude/`, plus a socket in `$TMPDIR` for permission requests. The [How it works](README.md#how-it-works) section of the README lists them. If you change one side of that contract, change the other side in the same pull request.

## Getting set up

You need macOS 14 or later, Xcode 16 or later, and Claude Code.

```bash
git clone https://github.com/NCSmit/notch-voice.git
cd notch-voice
swift build
```

- `./build.sh --install` builds the app, replaces the copy in `~/Applications` and restarts it.
- `./install.sh` does the same. It also copies the hooks into `~/.claude/hooks/`, registers them in `~/.claude/settings.json`, and adds the speak tool to the Claude desktop app's config. It keeps backups of anything it replaces. Restart Claude Code and the Claude desktop app afterwards, because both load these at startup.

## Running the tests

```bash
swift test
python3 -m unittest discover -s hook/tests
```

Both suites run automatically on every pull request.

## Trying changes by hand

Watch what the app is doing:

```bash
log stream --level info --predicate 'subsystem == "local.notchvoice"'
```

Hear a reply without waiting for Claude. This plays out loud and turns your music down while it speaks:

```bash
echo '{"last_assistant_message": "Hello from NotchVoice"}' | python3 hook/speak.py
```

Send a test permission request to the notch. The card appears, and the command prints whatever you click:

```bash
echo '{"tool_name": "Bash", "tool_input": {"command": "echo hi", "description": "Say hi"}}' | python3 hook/notchvoice_permission.py
```

## Code style

- **Swift:** the app uses Swift 6 strict concurrency, with UI state in `@MainActor` classes. Keep types small and names descriptive. Add a comment only to explain why something is done, not what it does.
- **Hooks:** use only the Python standard library. A hook must never break Claude Code. If something it needs is missing, it should exit quietly with no output. Keep hooks fast, because `notchvoice_brief.py` runs on every prompt.
- **Screenshots:** when you change the UI, update the matching images in `docs/`. Use 2x PNGs with 8-bit colour.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each pull request to one change.
3. In the description, say what changed and why in a sentence or two, and how you tested it. For UI changes, add a screenshot.
4. Make sure the app builds and both test suites pass.

## Reporting bugs

Open an issue using the bug report template. Please include:

- your macOS version and Mac model
- your Claude Code version, and where you run it (terminal, desktop app or IDE)
- your NotchVoice version, which is shown at the bottom of the settings window
