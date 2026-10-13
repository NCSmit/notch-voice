#!/usr/bin/env python3
"""Adds the NotchVoice speak tool to the Claude desktop app's config, or takes it out again. install.sh runs this.

The tool belongs in the config while ~/.claude/hooks/notchvoice_mcp.py is installed. The desktop app keeps its
config in memory and writes all of it back whenever its own settings change, so an edit made while the app is open
gets lost. When the app is open, a background copy of this script waits for it to quit and makes the edit again.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, "Library", "Application Support", "Claude", "claude_desktop_config.json")
SERVER = os.path.join(HOME, ".claude", "hooks", "notchvoice_mcp.py")
DONE = {
    "added": "Added the speak tool for chats in the Claude desktop app.",
    "removed": "Removed the speak tool from the Claude desktop app.",
}


def sync(config_path=CONFIG, server=SERVER):
    """Returns "added" or "removed", or None when the config already matches or the desktop app isn't installed."""
    if not os.path.isdir(os.path.dirname(config_path)):
        return None
    config = {}
    if os.path.exists(config_path):
        with open(config_path) as f:
            config = json.load(f)
    if not isinstance(config, dict) or not isinstance(config.get("mcpServers", {}), dict):
        raise ValueError("it isn't laid out as expected")
    servers = config.get("mcpServers", {})
    wanted = {"command": "/usr/bin/python3", "args": [server]} if os.path.exists(server) else None
    if servers.get("notchvoice") == wanted:
        return None
    if wanted:
        servers["notchvoice"] = wanted
        config["mcpServers"] = servers
    else:
        del servers["notchvoice"]
        if not servers:
            config.pop("mcpServers", None)
    if os.path.exists(config_path):
        shutil.copy2(config_path, config_path + ".bak")
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    return "added" if wanted else "removed"


def desktop_app_pid():
    try:
        processes = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    except OSError:
        return None
    for line in processes.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.endswith("Claude.app/Contents/MacOS/Claude"):
            return int(pid)
    return None


def wait_for_exit(pid):
    try:
        exits = select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT, select.KQ_NOTE_EXIT)
        select.kqueue().control([exits], 1, None)
    except OSError:
        time.sleep(1)


def main():
    if sys.argv[1:] == ["--after-quit"]:
        while (pid := desktop_app_pid()) is not None:
            wait_for_exit(pid)
        try:
            sync()
        except (OSError, ValueError):
            pass
        return
    try:
        change = sync()
    except (OSError, ValueError) as error:
        print(f"Skipped chats in the Claude desktop app: could not update {CONFIG} ({error}).", file=sys.stderr)
        return
    if not change:
        return
    if desktop_app_pid() is None:
        print(DONE[change])
        return
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--after-quit"],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"{DONE[change]} Quit the Claude desktop app and open it again, so it picks up the change.")


if __name__ == "__main__":
    main()
