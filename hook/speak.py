#!/usr/bin/env python3
"""Stop hook: read Claude's last reply aloud with macOS `say` (fully offline).

Settings come from ~/.claude/tts_settings.json, which the NotchVoice notch app writes:
  voice  a voice for `say -v`, else $CLAUDE_TTS_VOICE, else the system Spoken Content voice
  rate   words per minute, else $CLAUDE_TTS_RATE, else the voice's own rate
  duck   how loud Spotify / Music stay while speaking, as a fraction of their volume, else $CLAUDE_TTS_DUCK, else 0.5
Mute: touch ~/.claude/tts_off   Unmute: rm ~/.claude/tts_off   (NotchVoice samples set NOTCHVOICE_SAMPLE=1 and play anyway)
"""
import contextlib
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

try:
    from notchvoice_sessions import orchestrator
except ImportError:  # installed without the sessions hook, so there is no orchestrator either
    def orchestrator(check_name=True):
        return None

HOME = os.path.expanduser("~")
MUTE_FILE = os.path.join(HOME, ".claude", "tts_off")
SETTINGS_FILE = os.path.join(HOME, ".claude", "tts_settings.json")
DARWIN_USER_TEMP_DIR = 65537  # _CS_DARWIN_USER_TEMP_DIR in <unistd.h>
MUSIC_APPS = ["Spotify", "Music"]


def user_temp_dir():
    # The folder NSTemporaryDirectory() gives the app. TMPDIR can't be trusted for this, because tool servers started
    # by the Claude desktop app don't get it, and tempfile then falls back to /tmp.
    try:
        return os.confstr(DARWIN_USER_TEMP_DIR) or tempfile.gettempdir()
    except (OSError, ValueError):
        return tempfile.gettempdir()


# "<hook pid> <say pid>" of the reply currently speaking (or getting ready to).
OWNER_FILE = os.path.join(user_temp_dir(), "claude_tts_owner")
DUCK_FILE = os.path.join(user_temp_dir(), "claude_tts_duck.json")
# "<hook pid> <session_id>" of the reply currently speaking, so the menu bar can mark that session. The app only trusts
# it while the hook pid matches the owner file.
SESSION_FILE = os.path.join(user_temp_dir(), "claude_tts_session")
# NotchVoice keeps this file fresh while you dictate with a dictation app. One that stops being refreshed, because the
# app quit, counts as gone after DICTATION_FRESH seconds, so a reply can't stay held or paused.
DICTATION_FILE = os.path.join(user_temp_dir(), "notchvoice_dictating")
DICTATION_FRESH = 5
# Replies take turns, oldest first. Each hook that is waiting or speaking holds a lock on its own ticket here, so a
# ticket left by a hook that was killed is recognised. Voice samples from the settings window go ahead of replies.
QUEUE_DIR = os.path.join(user_temp_dir(), "claude_tts_queue")
# The Stop hook is given 600 s. A reply that hasn't started by WAIT_LIMIT, waiting its turn or for dictation to end, is
# dropped as stale. One still paused at DEADLINE is dropped too, so `say` is never left stopped when the hook is ended.
WAIT_LIMIT = 280
DEADLINE = 580
# NotchVoice's "skip every reply" writes the time, in nanoseconds since 1970, before which queued replies stay quiet.
SKIP_FILE = os.path.join(user_temp_dir(), "notchvoice_skip_before")
# A reply that is only this mark has nothing to say, so the orchestrator can end a quiet turn without being read aloud.
SILENT_MARK = "\u2014"


def is_tool_result_only(content):
    return isinstance(content, list) and content and all(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    )


def last_reply_from_transcript(path):
    try:
        with open(path) as f:
            entries = [json.loads(line) for line in f if line.strip()]
    except (OSError, json.JSONDecodeError):
        return ""
    chunks = []
    for entry in reversed(entries):
        msg = entry.get("message") or {}
        if entry.get("type") == "user" and not is_tool_result_only(msg.get("content")):
            break
        if entry.get("type") != "assistant":
            continue
        for block in reversed(msg.get("content") or []):
            if isinstance(block, dict) and block.get("type") == "text":
                chunks.append(block.get("text", ""))
    return "\n\n".join(reversed(chunks))


def clean(text):
    text = re.sub(r"```.*?```", " (code block omitted) ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)  # markdown links -> label
    text = re.sub(r"https?://\S+", "link", text)
    text = re.sub(r"^\s*[#>|]+\s*", "", text, flags=re.M)
    text = re.sub(r"^\s*[-*]\s+", "", text, flags=re.M)
    text = re.sub(r"[*_~]{1,3}", "", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def load_settings():
    try:
        with open(SETTINGS_FILE) as f:
            settings = json.load(f)
    except (OSError, ValueError):
        return {}
    return settings if isinstance(settings, dict) else {}


def silenced(payload):
    """While a session is the orchestrator, only its replies are read aloud. Samples and desktop chats carry no
    session, so they always speak."""
    session = payload.get("session_id")
    if not session:
        return False
    boss = orchestrator()
    return bool(boss) and session != boss


def music_level(settings):
    level = settings.get("duck", os.environ.get("CLAUDE_TTS_DUCK", "0.5"))
    try:
        return min(max(float(level), 0.0), 1.0)
    except (TypeError, ValueError):
        return 0.5


def read_owner():
    try:
        with open(OWNER_FILE) as f:
            return [int(pid) for pid in f.read().split()]
    except (OSError, ValueError):
        return []


def write_owner(*pids):
    with open(OWNER_FILE, "w") as f:
        f.write(" ".join(str(pid) for pid in pids))


def is_owner():
    owner = read_owner()
    return bool(owner) and owner[0] == os.getpid()


def stop(pid):
    # A paused `say` only acts on SIGTERM once it is continued.
    for sig in (signal.SIGTERM, signal.SIGCONT):
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def take_over():
    """Stop the reply speaking, at any stage, and claim the voice. Only voice samples do this; replies take turns."""
    for pid in read_owner():
        if pid != os.getpid():
            stop(pid)
    write_owner(os.getpid())


@contextlib.contextmanager
def claiming():
    """Held while a hook checks that its turn has come and claims the voice, and while a voice sample joins the queue
    and stops the reply speaking, so neither can slip in between the other's two steps."""
    os.makedirs(QUEUE_DIR, exist_ok=True)
    fd = os.open(os.path.join(QUEUE_DIR, ".claim"), os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def take_ticket(sample):
    """Joins the queue, and returns the ticket's path and the open file that keeps it locked until this hook ends."""
    os.makedirs(QUEUE_DIR, exist_ok=True)
    name = f"{'a' if sample else 'b'}-{time.time_ns():020d}-{os.getpid()}"
    temp = os.path.join(QUEUE_DIR, f".{name}")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    # Locked before it can be seen, so no other hook takes it for one left behind.
    path = os.path.join(QUEUE_DIR, name)
    os.rename(temp, path)
    return path, fd


def leave_queue(ticket):
    path, fd = ticket
    try:
        os.remove(path)
    except OSError:
        pass
    os.close(fd)


def is_held(path):
    """Whether the hook that took this ticket is still alive. One that was killed lost its lock, and its ticket goes."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    finally:
        os.close(fd)
    try:
        os.remove(path)
    except OSError:
        pass
    return False


def others_in_queue(ticket, ahead_only=False):
    mine = os.path.basename(ticket[0])
    try:
        names = sorted(name for name in os.listdir(QUEUE_DIR) if not name.startswith("."))
    except OSError:
        return []
    return [name for name in names
            if name != mine and (name < mine or not ahead_only) and is_held(os.path.join(QUEUE_DIR, name))]


def skipped(ticket):
    """Whether the user skipped every reply after this one joined the queue."""
    try:
        with open(SKIP_FILE) as f:
            before = int(f.read().strip())
        return int(os.path.basename(ticket[0]).split("-")[1]) <= before
    except (OSError, ValueError, IndexError):
        return False


def wait_for_turn(ticket, started):
    while others_in_queue(ticket, ahead_only=True):
        if time.time() - started > WAIT_LIMIT:
            return False
        time.sleep(0.2)
    return True


def user_is_dictating():
    # A voice sample is played on request from the settings window, so it never waits.
    if os.environ.get("NOTCHVOICE_SAMPLE"):
        return False
    try:
        return time.time() - os.path.getmtime(DICTATION_FILE) < DICTATION_FRESH
    except OSError:
        return False


def wait_while_dictating(started):
    """Never start talking over the user. False when a voice sample took over or the wait ran out."""
    while user_is_dictating():
        if not is_owner() or time.time() - started > WAIT_LIMIT:
            return False
        time.sleep(0.2)
    return is_owner()


def play(proc, text, started):
    """Feeds the reply to `say`, pausing it while the user dictates and resuming where it was."""
    paused = False
    pending = text
    while True:
        try:
            proc.communicate(pending, timeout=0.2)
            return
        except subprocess.TimeoutExpired:
            pending = None
        if paused and time.time() - started > DEADLINE:
            stop(proc.pid)
            proc.wait()
            return
        dictating = user_is_dictating()
        if dictating != paused:
            os.kill(proc.pid, signal.SIGSTOP if dictating else signal.SIGCONT)
            paused = dictating


def write_session(session_id):
    if not isinstance(session_id, str) or not session_id:
        return
    temp = f"{SESSION_FILE}.{os.getpid()}"
    try:
        with open(temp, "w") as f:
            f.write(f"{os.getpid()} {session_id}")
        os.replace(temp, SESSION_FILE)
    except OSError:
        pass


def clear_session():
    try:
        with open(SESSION_FILE) as f:
            if f.read().split()[:1] == [str(os.getpid())]:
                os.remove(SESSION_FILE)
    except OSError:
        pass


def osascript(script):
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return result.stdout.strip()


def app_volume(app):
    # "is running" never launches the app.
    out = osascript(f'if application "{app}" is running then tell application "{app}" to get sound volume')
    return int(out) if out.isdigit() else None


def set_app_volume(app, volume):
    osascript(f'if application "{app}" is running then tell application "{app}" to set sound volume to {volume}')


def duck_music(factor):
    # Keep the first saved volumes while replies follow one another, so the restore uses the real level.
    if os.path.exists(DUCK_FILE):
        return
    original = {app: v for app in MUSIC_APPS if (v := app_volume(app)) is not None}
    with open(DUCK_FILE, "w") as f:
        json.dump(original, f)
    for app, volume in original.items():
        set_app_volume(app, round(volume * factor))


def restore_music():
    try:
        with open(DUCK_FILE) as f:
            original = json.load(f)
        os.remove(DUCK_FILE)
    except (OSError, ValueError):
        return
    for app, volume in original.items():
        set_app_volume(app, volume)


def main():
    sample = bool(os.environ.get("NOTCHVOICE_SAMPLE"))
    if os.path.exists(MUTE_FILE) and not sample:
        return
    payload = json.load(sys.stdin)
    text = payload.get("last_assistant_message") or last_reply_from_transcript(
        payload.get("transcript_path", "")
    )
    text = clean(text or "")
    if not text or text == SILENT_MARK:
        return

    settings = load_settings()
    if silenced(payload):
        return
    cmd = ["say"]
    voice = settings.get("voice") or os.environ.get("CLAUDE_TTS_VOICE")
    if voice:
        cmd += ["-v", str(voice)]
    rate = settings.get("rate") or os.environ.get("CLAUDE_TTS_RATE")
    if rate:
        cmd += ["-r", str(rate)]

    started = time.time()
    # Stopped by a voice sample, or by Claude Code at the hook's timeout: leave the queue on the way out.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    with claiming():
        ticket = take_ticket(sample)
        if sample:
            take_over()
    proc = None
    try:
        while True:
            if not wait_for_turn(ticket, started):
                return
            with claiming():
                # A voice sample may have joined ahead since the check.
                if not others_in_queue(ticket, ahead_only=True):
                    write_owner(os.getpid())
                    break
        # Voice replies may have been switched off, or another session made the orchestrator, while this one waited.
        if not sample and (os.path.exists(MUTE_FILE) or silenced(payload)):
            return
        write_session(payload.get("session_id"))
        if not wait_while_dictating(started) or skipped(ticket):
            return
        duck_music(music_level(settings))
        if not is_owner() or skipped(ticket):
            return  # A voice sample took over, or the user skipped every reply while the music turned down.
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, text=True)
        write_owner(os.getpid(), proc.pid)
        play(proc, text, started)
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if proc and proc.poll() is None:
            stop(proc.pid)
        leave_queue(ticket)
        if is_owner():
            try:
                os.remove(OWNER_FILE)
            except OSError:
                pass
            clear_session()
        # The music stays down between replies, and comes back after the last one in the queue.
        if not others_in_queue(ticket):
            restore_music()

if __name__ == "__main__":
    main()
