import argparse
import importlib.util
import io
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HOOKS = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HOOKS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# speak.py, the brief hook and the snapshot helper import the sessions hook, so they all share this one module and
# its patched folders.
sessions = load("notchvoice_sessions")
sys.modules["notchvoice_sessions"] = sessions
speak = load("speak")
brief = load("notchvoice_brief")
permission = load("notchvoice_permission")
mcp = load("notchvoice_mcp")
desktop = load("notchvoice_desktop")
snapshot = load("notchvoice_snapshot")
handoff = load("notchvoice_handoff")


def run_main(module, payload):
    output = io.StringIO()
    with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), redirect_stdout(output):
        module.main()
    return output.getvalue()


def tool_use(tool_id, command):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {"command": command}}]}}


def tool_result(tool_id):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tool_id, "content": "ok"}]}}


class SpeakTests(unittest.TestCase):
    def test_clean_turns_markdown_into_plain_speech(self):
        text = "## Done\nSee [the guide](https://example.com/guide) and `install.sh`.\n```bash\nrm -rf build\n```\n- **one**"
        spoken = speak.clean(text)
        self.assertIn("code block omitted", spoken)
        self.assertIn("the guide", spoken)
        self.assertIn("install.sh", spoken)
        for markup in ("rm -rf", "https://", "##", "**", "`", "["):
            self.assertNotIn(markup, spoken)

    def test_music_level_prefers_settings_then_environment_then_half(self):
        self.assertEqual(speak.music_level({"duck": 0.2}), 0.2)
        self.assertEqual(speak.music_level({"duck": 3}), 1.0)
        self.assertEqual(speak.music_level({"duck": "loud"}), 0.5)
        with mock.patch.dict(os.environ, {"CLAUDE_TTS_DUCK": "0.3"}):
            self.assertEqual(speak.music_level({}), 0.3)
        with mock.patch.dict(os.environ):
            os.environ.pop("CLAUDE_TTS_DUCK", None)
            self.assertEqual(speak.music_level({}), 0.5)

    def test_load_settings_tolerates_missing_and_broken_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tts_settings.json"
            with mock.patch.object(speak, "SETTINGS_FILE", str(path)):
                self.assertEqual(speak.load_settings(), {})
                path.write_text("not json")
                self.assertEqual(speak.load_settings(), {})
                path.write_text('{"voice": "Samantha", "rate": 200}')
                self.assertEqual(speak.load_settings(), {"voice": "Samantha", "rate": 200})

    def test_shares_its_files_with_the_app_whatever_tmpdir_says(self):
        app_folder = Path(os.confstr(speak.DARWIN_USER_TEMP_DIR))
        for tmpdir in (None, "/tmp/elsewhere"):
            with mock.patch.dict(os.environ):
                os.environ.pop("TMPDIR", None)
                if tmpdir:
                    os.environ["TMPDIR"] = tmpdir
                fresh_speak, fresh_permission = load("speak"), load("notchvoice_permission")
            self.assertEqual(Path(fresh_speak.OWNER_FILE).parent, app_folder)
            self.assertEqual(Path(fresh_permission.SOCKET).parent, app_folder)


    def test_the_speaking_session_is_tagged_with_the_hook_and_only_it_clears_it(self):
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.object(speak, "SESSION_FILE", os.path.join(folder, "claude_tts_session")):
            speak.write_session("abc-123")
            with open(speak.SESSION_FILE) as f:
                self.assertEqual(f.read(), f"{os.getpid()} abc-123")
            with mock.patch.object(speak.os, "getpid", return_value=1):
                speak.clear_session()
            self.assertTrue(os.path.exists(speak.SESSION_FILE))
            speak.clear_session()
            self.assertFalse(os.path.exists(speak.SESSION_FILE))
            speak.write_session(None)
            self.assertEqual(os.listdir(folder), [])

class BriefTests(unittest.TestCase):
    def run_hook(self, settings=None, muted=False):
        with tempfile.TemporaryDirectory() as folder:
            settings_file = Path(folder) / "tts_settings.json"
            mute_file = Path(folder) / "tts_off"
            if settings is not None:
                settings_file.write_text(settings)
            if muted:
                mute_file.touch()
            with mock.patch.object(brief, "SETTINGS_FILE", str(settings_file)), mock.patch.object(brief, "MUTE_FILE", str(mute_file)):
                return run_main(brief, {"prompt": "hello"})

    def test_reminds_claude_by_default(self):
        output = json.loads(self.run_hook())["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "UserPromptSubmit")
        self.assertIn("read aloud", output["additionalContext"])

    def test_adds_nothing_while_voice_replies_are_muted(self):
        self.assertEqual(self.run_hook(muted=True), "")

    def test_adds_nothing_when_short_replies_are_turned_off(self):
        self.assertEqual(self.run_hook(settings='{"brief": false}'), "")

    def test_a_broken_settings_file_keeps_the_reminder(self):
        self.assertNotEqual(self.run_hook(settings="not json"), "")


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.folder.name, "transcript.jsonl")
        Path(self.path).touch()

    def tearDown(self):
        self.folder.cleanup()

    def write(self, *entries):
        with open(self.path, "a") as f:
            for entry in entries:
                f.write(json.dumps(entry) + "\n")

    def test_notices_when_the_pending_call_gets_a_result(self):
        self.write(tool_use("t1", "make"))
        transcript = permission.Transcript(self.path, "Bash", {"command": "make"})
        self.assertEqual(transcript.tool_use_id, "t1")
        self.assertFalse(transcript.answered_elsewhere())
        self.write(tool_result("t1"))
        self.assertTrue(transcript.answered_elsewhere())

    def test_ignores_an_earlier_identical_call_that_was_already_answered(self):
        self.write(tool_use("old", "make"), tool_result("old"), tool_use("new", "make"))
        transcript = permission.Transcript(self.path, "Bash", {"command": "make"})
        self.assertEqual(transcript.tool_use_id, "new")
        self.assertFalse(transcript.answered_elsewhere())

    def test_picks_up_a_call_written_after_the_hook_started(self):
        self.write(tool_use("old", "make"), tool_result("old"))
        transcript = permission.Transcript(self.path, "Bash", {"command": "make"})
        self.assertIsNone(transcript.tool_use_id)
        self.write(tool_use("new", "make"))
        self.assertFalse(transcript.answered_elsewhere())
        self.assertEqual(transcript.tool_use_id, "new")
        self.write(tool_result("new"))
        self.assertTrue(transcript.answered_elsewhere())

    def test_a_missing_transcript_never_counts_as_answered(self):
        self.assertFalse(permission.Transcript(None, "Bash", {"command": "make"}).answered_elsewhere())


class PermissionHookTests(unittest.TestCase):
    def test_without_the_app_there_is_no_decision(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(permission, "SOCKET", os.path.join(folder, "missing.sock")):
            self.assertIsNone(permission.ask_notch({"tool_name": "Bash"}, permission.Transcript(None, "Bash", {})))

    def test_returns_the_answer_given_in_the_notch(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as folder:
            path = os.path.join(folder, "notch.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)

            def answer():
                connection, _ = server.accept()
                connection.makefile().readline()
                connection.sendall(b'{"decision":"allow"}\n')
                connection.close()

            thread = threading.Thread(target=answer)
            thread.start()
            with mock.patch.object(permission, "SOCKET", path):
                decision = permission.ask_notch({"tool_name": "Bash"}, permission.Transcript(None, "Bash", {}))
            thread.join()
            server.close()
            self.assertEqual(decision, "allow")

    def test_prints_allow_and_deny_decisions_for_claude_code(self):
        for decision, behavior in (("allow", "allow"), ("deny", "deny")):
            with mock.patch.object(permission, "ask_notch", return_value=decision):
                output = json.loads(run_main(permission, {"tool_name": "Bash", "tool_input": {"command": "ls"}}))
            self.assertEqual(output["hookSpecificOutput"]["hookEventName"], "PermissionRequest")
            self.assertEqual(output["hookSpecificOutput"]["decision"]["behavior"], behavior)

    def test_a_dismissed_request_leaves_the_decision_to_claude_code(self):
        with mock.patch.object(permission, "ask_notch", return_value="ask"):
            self.assertEqual(run_main(permission, {"tool_name": "Bash", "tool_input": {"command": "ls"}}), "")

    def test_questions_and_plan_approvals_never_reach_the_notch(self):
        for tool in ("AskUserQuestion", "ExitPlanMode"):
            with mock.patch.object(permission, "ask_notch") as ask_notch:
                self.assertEqual(run_main(permission, {"tool_name": tool}), "")
            ask_notch.assert_not_called()

    def test_long_inputs_are_trimmed_before_they_are_sent(self):
        value = permission.trimmed({"content": "x" * 5000, "items": list(range(100))})
        self.assertEqual(len(value["content"]), permission.MAX_TEXT + 1)
        self.assertEqual(len(value["items"]), 50)


class SpeakToolTests(unittest.TestCase):
    def test_regular_chats_get_the_speak_tool_and_instructions(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", False):
            started = mcp.result_for("initialize", {"protocolVersion": "2025-03-26"})
            self.assertEqual(started["protocolVersion"], "2025-03-26")
            self.assertIn("speak tool", started["instructions"])
            self.assertIn("If you are Claude Code, never call it", started["instructions"])
            self.assertEqual([tool["name"] for tool in mcp.result_for("tools/list", {})["tools"]], ["speak"])

    def test_claude_code_gets_nothing_because_its_stop_hook_already_speaks(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", True):
            self.assertNotIn("instructions", mcp.result_for("initialize", {}))
            self.assertEqual(mcp.result_for("tools/list", {}), {"tools": []})
            self.assertIsNone(mcp.result_for("tools/call", {"name": "speak", "arguments": {"text": "hi"}}))

    def test_speak_passes_the_text_on(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", False), mock.patch.object(mcp, "speak", return_value="Speaking.") as speak_call:
            result = mcp.result_for("tools/call", {"name": "speak", "arguments": {"text": "  Hello  "}})
        speak_call.assert_called_once_with("Hello")
        self.assertEqual(result["content"][0]["text"], "Speaking.")

    def test_speaking_nothing_is_an_error(self):
        with mock.patch.object(mcp, "IN_CLAUDE_CODE", False):
            self.assertTrue(mcp.result_for("tools/call", {"name": "speak", "arguments": {}})["isError"])

    def test_nothing_is_spoken_while_voice_replies_are_muted(self):
        with tempfile.TemporaryDirectory() as folder:
            mute_file = Path(folder) / "tts_off"
            mute_file.touch()
            with mock.patch.object(mcp, "MUTE_FILE", str(mute_file)), mock.patch.object(mcp.subprocess, "Popen") as popen:
                self.assertIn("off", mcp.speak("hi"))
            popen.assert_not_called()

    def test_notifications_get_no_reply_and_unknown_requests_get_an_error(self):
        output = io.StringIO()
        with redirect_stdout(output):
            mcp.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
            mcp.handle({"jsonrpc": "2.0", "id": 7, "method": "resources/list"})
        replies = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["error"]["code"], -32601)


class DesktopConfigTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.config = Path(folder.name) / "claude_desktop_config.json"
        self.server = Path(folder.name) / "notchvoice_mcp.py"
        self.server.touch()
        self.config.write_text(json.dumps({"preferences": {"theme": "dark"}, "mcpServers": {"other": {"command": "other"}}}))

    def sync(self):
        return desktop.sync(str(self.config), str(self.server))

    def read(self):
        return json.loads(self.config.read_text())

    def test_adds_the_speak_tool_and_keeps_everything_else(self):
        self.assertEqual(self.sync(), "added")
        config = self.read()
        self.assertEqual(config["mcpServers"]["notchvoice"], {"command": "/usr/bin/python3", "args": [str(self.server)]})
        self.assertEqual(config["mcpServers"]["other"], {"command": "other"})
        self.assertEqual(config["preferences"], {"theme": "dark"})
        self.assertNotIn("notchvoice", json.loads(Path(f"{self.config}.bak").read_text())["mcpServers"])

    def test_takes_the_speak_tool_out_once_it_is_uninstalled(self):
        self.sync()
        self.server.unlink()
        self.assertEqual(self.sync(), "removed")
        self.assertEqual(self.read()["mcpServers"], {"other": {"command": "other"}})

    def test_leaves_a_config_that_already_matches_untouched(self):
        self.sync()
        written = self.config.read_text()
        self.assertIsNone(self.sync())
        self.assertEqual(self.config.read_text(), written)

    def test_never_overwrites_a_config_it_cannot_read(self):
        self.config.write_text("{ not json")
        with self.assertRaises(ValueError):
            self.sync()
        self.assertEqual(self.config.read_text(), "{ not json")

    def test_does_nothing_without_the_desktop_app(self):
        missing = self.config.parent / "Claude" / "claude_desktop_config.json"
        self.assertIsNone(desktop.sync(str(missing), str(self.server)))
        self.assertFalse(missing.parent.exists())

    def test_finds_the_desktop_app_but_not_claude_code(self):
        processes = (
            "  101 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper\n"
            "  102 /Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude\n"
        )
        with mock.patch.object(desktop.subprocess, "run", return_value=mock.Mock(stdout=processes)):
            self.assertIsNone(desktop.desktop_app_pid())
        with mock.patch.object(desktop.subprocess, "run", return_value=mock.Mock(stdout=processes + "  100 /Applications/Claude.app/Contents/MacOS/Claude\n")):
            self.assertEqual(desktop.desktop_app_pid(), 100)

    def test_while_the_app_is_open_the_edit_is_made_again_after_it_quits(self):
        with mock.patch.object(sys, "argv", ["notchvoice_desktop.py"]), mock.patch.object(desktop, "sync", return_value="added"), \
                mock.patch.object(desktop, "desktop_app_pid", return_value=100), mock.patch.object(desktop.subprocess, "Popen") as popen, \
                redirect_stdout(io.StringIO()) as output:
            desktop.main()
        self.assertEqual(popen.call_args.args[0][-1], "--after-quit")
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertIn("Quit the Claude desktop app", output.getvalue())

        with mock.patch.object(sys, "argv", ["notchvoice_desktop.py", "--after-quit"]), \
                mock.patch.object(desktop, "desktop_app_pid", side_effect=[100, 200, None]), \
                mock.patch.object(desktop, "wait_for_exit") as wait, mock.patch.object(desktop, "sync") as sync:
            desktop.main()
        self.assertEqual([call.args[0] for call in wait.call_args_list], [100, 200])
        sync.assert_called_once_with()

    def test_waiting_ends_as_soon_as_the_app_quits(self):
        app = subprocess.Popen(["sleep", "0.3"])
        started = time.monotonic()
        desktop.wait_for_exit(app.pid)
        self.assertLess(time.monotonic() - started, 0.9)
        app.wait()



class SessionTests(unittest.TestCase):
    CLAUDE = {"pid": 4242, "process": "claude", "tty": "/dev/ttys003"}

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for patcher in (
            mock.patch.object(sessions, "SESSIONS_DIR", self.dir.name),
            mock.patch.object(sessions, "claude_process", return_value=dict(self.CLAUDE)),
            mock.patch.dict(os.environ, {"__CFBundleIdentifier": "com.apple.Terminal"}),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def send(self, event, **fields):
        run_main(sessions, {"hook_event_name": event, "session_id": "abc-123", "cwd": "/Users/someone/demo", **fields})
        with open(os.path.join(self.dir.name, "abc-123.json")) as f:
            return json.load(f)

    def test_follows_a_session_from_prompt_to_reply(self):
        status = self.send("UserPromptSubmit", prompt="Fix   the login\nbug please")
        self.assertEqual((status["state"], status["title"], status["project"]), ("working", "Fix the login bug please", "demo"))
        status = self.send("PreToolUse", tool_name="Edit", tool_input={"file_path": "/Users/someone/demo/login.py"})
        self.assertEqual(status["activity"], "Editing login.py")
        status = self.send("PermissionRequest", tool_name="Bash", tool_input={"command": "npm test", "description": "Run the tests"})
        self.assertEqual((status["state"], status["activity"]), ("waiting", "Needs you: Running Run the tests"))
        status = self.send("Stop", last_assistant_message="**Fixed** the bug. Tests pass now.")
        self.assertEqual((status["state"], status["activity"]), ("idle", "Fixed the bug."))
        status = self.send("UserPromptSubmit", prompt="Now ship it")
        self.assertEqual(status["title"], "Fix the login bug please")

    def test_questions_and_plans_wait_for_you(self):
        status = self.send("PreToolUse", tool_name="AskUserQuestion", tool_input={"questions": []})
        self.assertEqual((status["state"], status["activity"]), ("waiting", "Needs you: a question"))
        status = self.send("PermissionRequest", tool_name="ExitPlanMode", tool_input={"plan": "..."})
        self.assertEqual((status["state"], status["activity"]), ("waiting", "Needs you: a plan to approve"))
        self.assertEqual(self.send("PostToolUse", tool_name="ExitPlanMode")["state"], "working")

    def test_remembers_where_the_session_runs(self):
        status = self.send("SessionStart", source="startup")
        self.assertEqual(
            (status["pid"], status["process"], status["tty"], status["app"]),
            (4242, "claude", "/dev/ttys003", "com.apple.Terminal"),
        )

    def test_looks_up_the_process_once_and_again_when_resumed(self):
        self.send("SessionStart", source="startup")
        self.send("PreToolUse", tool_name="Read", tool_input={})
        self.send("Stop", last_assistant_message="Done.")
        self.assertEqual(sessions.claude_process.call_count, 1)
        sessions.claude_process.return_value = {"pid": 5151, "process": "claude"}
        with mock.patch.dict(os.environ, {"__CFBundleIdentifier": "com.googlecode.iterm2"}):
            status = self.send("SessionStart", source="resume")
        self.assertEqual((status["pid"], status["app"]), (5151, "com.googlecode.iterm2"))
        self.assertNotIn("tty", status)

    def test_a_session_that_started_before_the_hook_is_looked_up_on_its_next_event(self):
        self.assertEqual(self.send("PreToolUse", tool_name="Read", tool_input={})["pid"], 4242)

    def test_a_process_ps_cannot_find_is_not_looked_up_again(self):
        sessions.claude_process.return_value = {}
        self.assertIsNone(self.send("SessionStart", source="startup")["pid"])
        self.send("PreToolUse", tool_name="Read", tool_input={})
        self.assertEqual(sessions.claude_process.call_count, 1)

    def test_notes_added_before_the_prompt_are_left_out_of_the_title(self):
        status = self.send("UserPromptSubmit", prompt="<system-reminder>Started by another session</system-reminder>")
        self.assertNotIn("title", status)
        status = self.send("UserPromptSubmit", prompt="<system-reminder>Linked</system-reminder>\n\nMigrate the forms page")
        self.assertEqual(status["title"], "Migrate the forms page")
        self.assertEqual(sessions.without_notes("<Button> renders twice"), "<Button> renders twice")

    def test_keeps_when_the_session_started(self):
        with mock.patch.object(sessions.time, "time", return_value=100.0):
            self.send("SessionStart", source="startup")
        with mock.patch.object(sessions.time, "time", return_value=200.0):
            status = self.send("UserPromptSubmit", prompt="Hello")
        self.assertEqual((status["started"], status["updated"]), (100.0, 200.0))

    def test_an_older_event_never_overwrites_a_newer_one(self):
        self.send("Stop", last_assistant_message="Done.")
        with mock.patch.object(sessions.time, "time", return_value=1.0):
            status = self.send("PreToolUse", tool_name="Read", tool_input={})
        self.assertEqual(status["state"], "idle")

    def test_an_ended_session_stays_ended_until_it_is_resumed(self):
        self.send("SessionEnd")
        self.assertEqual(self.send("PostToolUse", tool_name="Read")["state"], "ended")
        self.assertEqual(self.send("SessionStart")["state"], "idle")

    def test_ignores_unknown_events_and_unsafe_session_ids(self):
        run_main(sessions, {"hook_event_name": "Notification", "session_id": "abc"})
        run_main(sessions, {"hook_event_name": "Stop", "session_id": "../evil"})
        run_main(sessions, {"hook_event_name": "Stop"})
        self.assertEqual(os.listdir(self.dir.name), [])

    def test_long_titles_and_mcp_tools_are_shortened(self):
        status = self.send("UserPromptSubmit", prompt="x" * 200)
        self.assertEqual(len(status["title"]), sessions.TITLE_LENGTH)
        status = self.send("PreToolUse", tool_name="mcp__tracker__save_issue", tool_input={})
        self.assertEqual(status["activity"], "Using save issue")


class ClaudeProcessTests(unittest.TestCase):
    def ps(self, table):
        def run(args, **kwargs):
            return mock.Mock(stdout=table.get(int(args[-1]), ""))
        return mock.patch.object(sessions.subprocess, "run", side_effect=run)

    def test_finds_claude_and_its_terminal_past_a_shell(self):
        table = {
            100: "  90 ttys003   /bin/zsh\n",
            90: "  80 ttys003   /Users/me/.local/share/claude/versions/2.1.197\n",
        }
        with mock.patch.object(sessions.os, "getppid", return_value=100), self.ps(table):
            self.assertEqual(sessions.claude_process(), {"pid": 90, "process": "2.1.197", "tty": "/dev/ttys003"})

    def test_a_session_without_a_terminal_has_no_tty(self):
        table = {100: "  80 ??       /Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude\n"}
        with mock.patch.object(sessions.os, "getppid", return_value=100), self.ps(table):
            self.assertEqual(sessions.claude_process(), {"pid": 100, "process": "claude"})

    def test_gives_up_quietly_when_ps_finds_nothing(self):
        with mock.patch.object(sessions.os, "getppid", return_value=100), self.ps({}):
            self.assertEqual(sessions.claude_process(), {})
        with mock.patch.object(sessions.subprocess, "run", side_effect=OSError):
            self.assertEqual(sessions.claude_process(), {})


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        root = self.dir.name
        os.makedirs(os.path.join(root, "sessions"))
        for module, name, value in ((sessions, "NOTCHVOICE_DIR", root), (sessions, "SESSIONS_DIR", os.path.join(root, "sessions")),
                                    (sessions, "ORCHESTRATOR_FILE", os.path.join(root, "orchestrator.json")),
                                    (handoff, "HANDOFF_DIR", os.path.join(root, "handoffs"))):
            patcher = mock.patch.object(module, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.alive = {"state": "idle", "pid": os.getpid(), "process": sessions.process_info(os.getpid())[2], "updated": time.time()}

    def status(self, session, data):
        with open(os.path.join(sessions.SESSIONS_DIR, f"{session}.json"), "w") as f:
            json.dump(data, f)

    def claim(self, session):
        with open(sessions.ORCHESTRATOR_FILE, "w") as f:
            json.dump({"session_id": session}, f)

    def finished_pid(self):
        process = subprocess.Popen(["true"])
        process.wait()
        return process.pid

    def test_every_session_speaks_until_one_claims_it(self):
        self.status("boss", self.alive)
        self.assertFalse(speak.silenced({"session_id": "worker"}))
        self.claim("boss")
        self.assertTrue(speak.silenced({"session_id": "worker"}))
        self.assertFalse(speak.silenced({"session_id": "boss"}))

    def test_samples_and_desktop_chats_always_speak(self):
        self.status("boss", self.alive)
        self.claim("boss")
        self.assertFalse(speak.silenced({}))

    def test_a_closed_or_ended_orchestrator_hands_the_voice_back(self):
        self.claim("boss")
        self.status("boss", dict(self.alive, pid=self.finished_pid()))
        self.assertIsNone(sessions.orchestrator())
        self.assertIsNone(sessions.orchestrator(check_name=False))
        self.status("boss", dict(self.alive, state="ended"))
        self.assertIsNone(sessions.orchestrator())
        self.status("boss", dict(self.alive, process="not-claude"))
        self.assertIsNone(sessions.orchestrator())
        self.assertEqual(sessions.orchestrator(check_name=False), "boss")
        os.remove(os.path.join(sessions.SESSIONS_DIR, "boss.json"))
        self.assertIsNone(sessions.orchestrator())

    def test_without_a_process_the_orchestrator_counts_as_open_for_a_while(self):
        self.claim("boss")
        self.status("boss", {"state": "working", "pid": None, "updated": time.time() - 60})
        self.assertEqual(sessions.orchestrator(), "boss")
        self.status("boss", {"state": "idle", "pid": None, "updated": time.time() - sessions.IDLE_LIFETIME - 1})
        self.assertIsNone(sessions.orchestrator())

    def test_an_unsafe_session_id_is_ignored(self):
        self.status("boss", self.alive)
        self.claim("../boss")
        self.assertIsNone(sessions.orchestrator())

    def test_only_the_orchestrator_is_reminded_to_keep_replies_short(self):
        self.status("boss", self.alive)
        self.claim("boss")
        with mock.patch.object(brief, "MUTE_FILE", os.path.join(self.dir.name, "missing")), \
                mock.patch.object(brief, "SETTINGS_FILE", os.path.join(self.dir.name, "missing.json")):
            self.assertEqual(run_main(brief, {"session_id": "worker"}), "")
            self.assertIn("read aloud", run_main(brief, {"session_id": "boss"}))

    def test_a_compacted_session_gets_its_saved_state_back_once(self):
        os.makedirs(handoff.HANDOFF_DIR)
        with open(os.path.join(handoff.HANDOFF_DIR, "abc.md"), "w") as f:
            f.write("## Goal\nShip the session list")
        self.assertEqual(run_main(handoff, {"hook_event_name": "SessionStart", "source": "startup", "session_id": "abc"}), "")
        output = run_main(handoff, {"hook_event_name": "SessionStart", "source": "compact", "session_id": "abc"})
        self.assertIn("Ship the session list", json.loads(output)["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(run_main(handoff, {"hook_event_name": "SessionStart", "source": "compact", "session_id": "abc"}), "")
        self.assertEqual(os.listdir(handoff.HANDOFF_DIR), ["abc.restored.md"])

    def test_a_long_handoff_is_cut_with_a_pointer_and_unsafe_ids_are_ignored(self):
        os.makedirs(handoff.HANDOFF_DIR)
        with open(os.path.join(handoff.HANDOFF_DIR, "abc.md"), "w") as f:
            f.write("x" * (handoff.LIMIT + 50))
        self.assertEqual(run_main(handoff, {"source": "compact", "session_id": "../abc"}), "")
        context = json.loads(run_main(handoff, {"source": "compact", "session_id": "abc"}))["hookSpecificOutput"]["additionalContext"]
        self.assertIn("cut off", context)
        self.assertLess(len(context), handoff.LIMIT + 400)

    def test_claim_and_release(self):
        self.status("boss", self.alive)
        self.status("other", self.alive)
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "boss"}), redirect_stdout(io.StringIO()) as out:
            snapshot.claim(mock.Mock(session=""))
        self.assertEqual(json.loads(out.getvalue())["orchestrator"], "boss")
        self.assertEqual(sessions.orchestrator(), "boss")
        with redirect_stdout(io.StringIO()) as out:
            snapshot.claim(mock.Mock(session="other"))
        self.assertEqual(json.loads(out.getvalue())["replaced"], "boss")
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": "boss"}), redirect_stdout(io.StringIO()) as out:
            snapshot.release(mock.Mock(session=""))
        self.assertEqual(out.getvalue().strip(), "this session is not the orchestrator")
        with redirect_stdout(io.StringIO()):
            snapshot.release(mock.Mock(session="other"))
        self.assertFalse(os.path.exists(sessions.ORCHESTRATOR_FILE))
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": ""}), self.assertRaises(SystemExit):
            snapshot.claim(mock.Mock(session=""))


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.object(sessions, "SESSIONS_DIR", self.dir.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_redacts_secrets_but_keeps_paths_ids_and_short_answers(self):
        kept = [
            "/Users/someone/code/notch-voice/hook/notchvoice_sessions.py",
            "session 8308086f-5419-4c79-837c-741ec42473be is done",
            "merged as 6db44bbabcdef0123456789abcdef0123456789a",
            "https://github.com/NCSmit/notch-voice/pull/1",
            "1", "pr2", "yes please",
            "Sources/NotchVoice/SessionStore.swift and apps/web/src/app/v2/page.tsx",
        ]
        for text in kept:
            self.assertEqual(snapshot.redact(text), text)
        for text in ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "token=abc123", "Hunter2024!",
                     "aGVsbG8gd29ybGQgdGhpcyBpcyBhIHNlY3JldCB0b2tlbg==",
                     "aGVs/bG8gd29ybGQgdGhpcyBpcyBhIHNlY3JldCB0b2tlbg+/x==",
                     "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"):
            self.assertIn("[redacted]", snapshot.redact(text))

    def test_transcript_times_are_utc_all_year(self):
        self.assertEqual(snapshot.parse_time("2026-07-01T12:00:00.000Z"), 1782907200)
        self.assertEqual(snapshot.parse_time("2026-01-01T12:00:00Z"), 1767268800)
        self.assertIsNone(snapshot.parse_time(None))

    def transcript(self, entries):
        path = os.path.join(self.dir.name, "t.jsonl")
        with open(path, "w") as f:
            f.write("\n".join(json.dumps(e) for e in entries) + "\n")
        return path

    def test_lists_open_sessions_and_spots_an_interrupt(self):
        transcript = self.transcript([
            {"type": "user", "timestamp": "2026-10-26T10:00:00Z", "message": {"content": "Fix the login bug"}},
            {"type": "assistant", "timestamp": "2026-10-26T10:00:05Z",
             "message": {"model": "claude-opus-5-5", "content": [{"type": "text", "text": "Looking at it."}]}},
            {"type": "user", "timestamp": "2026-10-26T10:01:00Z", "message": {"content": "[Request interrupted by user]"}},
        ])
        statuses = {
            "busy": {"state": "working", "title": "Fix the login bug", "updated": 1793008830.0, "transcript_path": transcript,
                     "cwd": self.dir.name},
            "me": {"state": "idle", "updated": time.time()},
            "gone": {"state": "ended", "updated": time.time()},
        }
        for session, status in statuses.items():
            with open(os.path.join(self.dir.name, f"{session}.json"), "w") as f:
                json.dump(status, f)
        with mock.patch.object(sessions, "is_open", side_effect=lambda status, now=None, check_name=True: status["state"] != "ended"), \
                mock.patch.object(snapshot, "pull_request", return_value={"number": 7, "state": "open", "checks": {}}), \
                redirect_stdout(io.StringIO()) as out:
            snapshot.sessions(argparse.Namespace(skip="me"))
        records = json.loads(out.getvalue())
        self.assertEqual([r["session_id"] for r in records], ["busy"])
        self.assertEqual((records[0]["state"], records[0]["activity"], records[0]["interrupted"]), ("idle", "Interrupted", True))
        self.assertEqual(records[0]["recent_prompts"], ["Fix the login bug"])
        self.assertEqual(records[0]["model"], "claude-opus-5-5")
        self.assertEqual(records[0]["pr"]["number"], 7)

    def test_wakes_when_a_session_finishes_or_needs_you_but_not_when_one_opens(self):
        before = {"a": {"state": "working"}}
        self.assertEqual(snapshot.changes(before, {"a": {"state": "working"}, "new": {"state": "idle"}}), [])
        self.assertEqual([e["session_id"] for e in snapshot.changes(before, {"a": {"state": "idle"}})], ["a"])
        self.assertEqual([e["state"] for e in snapshot.changes({}, {"new": {"state": "waiting"}})], ["waiting"])

    def test_wait_reports_what_changed_or_times_out(self):
        rounds = iter([{"a": {"state": "working"}}, {"a": {"state": "working"}}, {"a": {"state": "idle", "title": "A"}},
                       {"a": {"state": "idle", "title": "A"}, "b": {"state": "waiting", "title": "B"}}])
        with mock.patch.object(snapshot, "open_sessions", side_effect=lambda skip, check_name: next(rounds)), \
                mock.patch.object(snapshot.time, "sleep"), redirect_stdout(io.StringIO()) as out:
            snapshot.wait(mock.Mock(session="me", timeout=60))
        woke = json.loads(out.getvalue())
        self.assertEqual([(e["session_id"], e["state"]) for e in woke["sessions"]], [("a", "idle"), ("b", "waiting")])
        self.assertEqual(woke["user_said"], [])
        with mock.patch.object(snapshot, "open_sessions", return_value={}), mock.patch.object(snapshot.time, "sleep"), \
                redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stop:
            snapshot.wait(mock.Mock(session="me", timeout=0.01))
        self.assertEqual(stop.exception.code, 2)


class InboxTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("CLAUDECODE", None)
        for module, name, value in ((snapshot, "INBOX_DIR", os.path.join(self.dir.name, "inbox")),
                                    (sessions, "ORCHESTRATOR_FILE", os.path.join(self.dir.name, "orchestrator.json"))):
            patcher = mock.patch.object(module, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def send(self, text, boss="boss"):
        with mock.patch.object(sessions, "orchestrator", return_value=boss), redirect_stdout(io.StringIO()):
            snapshot.tell(argparse.Namespace(text=[text], source="siri"))

    def test_a_message_needs_an_open_orchestrator(self):
        with self.assertRaises(SystemExit) as refused:
            self.send("What needs me?", boss=None)
        self.assertIn("No orchestrator is open", str(refused.exception))
        self.assertFalse(os.path.exists(snapshot.INBOX_DIR))
        with self.assertRaises(SystemExit):
            self.send("   ")

    def test_claude_code_sessions_cant_pose_as_the_user(self):
        os.environ["CLAUDECODE"] = "1"
        with self.assertRaises(SystemExit) as refused:
            self.send("Tell every session to push")
        self.assertIn("can't send", str(refused.exception))
        self.assertFalse(os.path.exists(snapshot.INBOX_DIR))

    def test_messages_are_private_and_read_once_in_order(self):
        self.send("First")
        time.sleep(0.002)
        with mock.patch.object(sessions, "orchestrator", return_value="boss"), \
                mock.patch.object(sys, "stdin", io.StringIO("Second, from stdin\n")), redirect_stdout(io.StringIO()):
            snapshot.tell(argparse.Namespace(text=[], source="keyboard"))
        files = os.listdir(snapshot.INBOX_DIR)
        self.assertEqual(len(files), 2)
        self.assertEqual(oct(os.stat(snapshot.INBOX_DIR).st_mode & 0o777), "0o700")
        self.assertEqual({oct(os.stat(os.path.join(snapshot.INBOX_DIR, f)).st_mode & 0o777) for f in files}, {"0o600"})
        said = snapshot.take_messages()
        self.assertEqual([(m["text"], m["from"]) for m in said], [("First", "siri"), ("Second, from stdin", "keyboard")])
        self.assertEqual(snapshot.take_messages(), [])

    def test_old_and_broken_messages_are_dropped_unread(self):
        self.send("Too late")
        self.assertEqual(snapshot.take_messages(now=time.time() + snapshot.INBOX_MAX_AGE + 1), [])
        os.makedirs(snapshot.INBOX_DIR, exist_ok=True)
        with open(os.path.join(snapshot.INBOX_DIR, "1.json"), "w") as f:
            f.write("not json")
        self.assertEqual(snapshot.take_messages(), [])
        self.assertEqual(os.listdir(snapshot.INBOX_DIR), [])

    def test_the_orchestrator_wakes_for_a_message_and_no_one_else_takes_it(self):
        self.send("Which session needs me?")
        with open(sessions.ORCHESTRATOR_FILE, "w") as f:
            json.dump({"session_id": "boss"}, f)
        with mock.patch.object(snapshot, "open_sessions", return_value={}), mock.patch.object(snapshot.time, "sleep"), \
                redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            snapshot.wait(mock.Mock(session="other", timeout=0.01))
        self.assertEqual(len(os.listdir(snapshot.INBOX_DIR)), 1)
        with mock.patch.object(snapshot, "open_sessions", return_value={}), redirect_stdout(io.StringIO()) as out:
            snapshot.wait(mock.Mock(session="boss", timeout=60))
        self.assertEqual([m["text"] for m in json.loads(out.getvalue())["user_said"]], ["Which session needs me?"])


class PullRequestTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for name, sub in (("SESSIONS_DIR", "sessions"), ("REGISTRY_DIR", "registry")):
            os.makedirs(os.path.join(self.dir.name, sub))
            patcher = mock.patch.object(sessions, name, os.path.join(self.dir.name, sub))
            patcher.start()
            self.addCleanup(patcher.stop)

    def write(self, sub, name, data):
        path = os.path.join(self.dir.name, sub, name)
        with open(path, "w") as f:
            f.write(data if isinstance(data, str) else json.dumps(data))
        return path

    def test_reads_the_name_and_desktop_id_from_claude_codes_registry(self):
        self.write("registry", "42.json", {"sessionId": "abc", "name": " Notch review ", "nameSource": "user",
                                           "hostSessionId": "local_447c04a4-b726-4ce0-9e31-77062bf86260"})
        self.assertEqual(sessions.registry("abc", {"pid": 42}),
                         {"name": "Notch review", "desktop_session_id": "local_447c04a4-b726-4ce0-9e31-77062bf86260"})

    def test_ignores_derived_names_other_sessions_and_odd_ids(self):
        self.write("registry", "42.json", {"sessionId": "abc", "name": "orch-7a", "nameSource": "derived", "hostSessionId": "../x"})
        self.assertEqual(sessions.registry("abc", {"pid": 42}), {})
        self.assertEqual(sessions.registry("other", {"pid": 42}), {})
        self.assertEqual(sessions.registry("abc", {"pid": None}), {})
        self.assertEqual(sessions.registry("abc", {"pid": 7}), {})

    def test_counts_checks_like_the_desktop_app(self):
        rollup = [
            {"name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"},
            {"name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"},
            {"name": "Cursor Bugbot", "status": "IN_PROGRESS", "conclusion": ""},
            {"name": "deploy", "status": "COMPLETED", "conclusion": "SKIPPED"},
            {"context": "ci/legacy", "state": "ERROR"},
            {"name": "CI", "status": "COMPLETED", "conclusion": "ACTION_REQUIRED"},
        ]
        self.assertEqual(snapshot.check_counts(rollup),
                         {"passing": 1, "failing": 2, "pending": 2, "skipped": 1, "failingChecks": ["lint", "ci/legacy"]})

    def test_finds_the_pr_a_session_opened(self):
        transcript = self.write("sessions", "t.jsonl", "\n".join(json.dumps(e) for e in [
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "a", "name": "Bash", "input": {"command": "gh pr view 3"}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "a", "content": "https://github.com/o/r/pull/3"}]}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": "gh pr create --fill"}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "b",
                                                      "content": [{"type": "text", "text": "https://github.com/o/r/pull/12\n"}]}]}},
        ] + [{"type": "assistant", "message": {"content": [{"type": "text", "text": "x" * 1000}]}}] * 4000))
        self.assertEqual(snapshot.opened_pr(transcript), "https://github.com/o/r/pull/12")
        mcp = self.write("sessions", "m.jsonl", "\n".join(json.dumps(e) for e in [
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "c", "name": "mcp__github__create_pull_request", "input": {}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "c", "content": "Created https://github.com/o/r/pull/30"}]}},
        ]))
        self.assertEqual(snapshot.opened_pr(mcp), "https://github.com/o/r/pull/30")
        self.assertIsNone(snapshot.opened_pr(os.path.join(self.dir.name, "missing.jsonl")))

    def test_asks_gh_and_shapes_the_answer(self):
        answer = {"number": 12, "title": "Fix it", "url": "https://github.com/o/r/pull/12", "state": "OPEN", "isDraft": False,
                  "headRefName": "fix", "baseRefName": "main", "reviewDecision": "", "mergeStateStatus": "BLOCKED",
                  "statusCheckRollup": [{"name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"}]}
        with mock.patch.object(snapshot, "gh_path", return_value="/usr/bin/gh"), \
                mock.patch.object(snapshot.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=json.dumps(answer))) as run:
            pr = snapshot.pull_request(("url", "https://github.com/o/r/pull/12"))
        self.assertEqual(run.call_args.args[0][:4], ["/usr/bin/gh", "pr", "view", "https://github.com/o/r/pull/12"])
        self.assertEqual((pr["number"], pr["state"], pr["reviewDecision"], pr["checks"]["failingChecks"]), (12, "open", None, ["lint"]))
        with mock.patch.object(snapshot, "gh_path", return_value="/usr/bin/gh"), \
                mock.patch.object(snapshot.subprocess, "run", return_value=mock.Mock(returncode=1, stdout="")):
            self.assertIsNone(snapshot.pull_request(("folder", self.dir.name)))
        with mock.patch.object(snapshot, "gh_path", return_value=None):
            self.assertIsNone(snapshot.pull_request(("folder", self.dir.name)))

    def test_lists_prs_for_sessions_outside_the_desktop_app(self):
        alive = {"state": "idle", "updated": time.time(), "pid": 42, "process": "claude"}
        folder = self.dir.name
        self.write("sessions", "term.json", dict(alive, cwd=folder, title="Terminal work"))
        self.write("sessions", "twin.json", dict(alive, cwd=folder, title="Same folder", pid=43))
        self.write("sessions", "desk.json", dict(alive, cwd=folder, pid=44))
        self.write("registry", "44.json", {"sessionId": "desk", "name": "Desktop work", "hostSessionId": "local_ab12"})
        merged = {"number": 9, "state": "merged", "checks": {}}
        with mock.patch.object(sessions, "is_open", return_value=True), \
                mock.patch.object(snapshot, "pull_request", return_value=dict(merged, state="open")) as lookup, \
                redirect_stdout(io.StringIO()) as out:
            snapshot.prs(argparse.Namespace(skip="me", all=False))
        records = json.loads(out.getvalue())
        self.assertEqual(sorted(r["session_id"] for r in records), ["term", "twin"])
        self.assertEqual(lookup.call_count, 1)
        self.assertEqual({r["pr_from"] for r in records}, {"the folder's branch"})
        with mock.patch.object(sessions, "is_open", return_value=True), \
                mock.patch.object(snapshot, "pull_request", return_value=merged), redirect_stdout(io.StringIO()) as out:
            snapshot.prs(argparse.Namespace(skip="me", all=True))
        records = {r["session_id"]: r for r in json.loads(out.getvalue())}
        self.assertEqual(records["desk"]["name"], "Desktop work")
        self.assertIsNone(records["term"]["pr"])
        self.write("sessions", "nowhere.json", dict(alive, pid=45))
        with mock.patch.object(sessions, "is_open", return_value=True), \
                mock.patch.object(snapshot, "pull_request", return_value=None), redirect_stdout(io.StringIO()) as out:
            snapshot.prs(argparse.Namespace(skip="me", all=False))
        self.assertIsNone({r["session_id"]: r for r in json.loads(out.getvalue())}["nowhere"]["pr_from"])


class DictationTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.flag = os.path.join(self.dir.name, "notchvoice_dictating")
        for name, value in (("DICTATION_FILE", self.flag), ("OWNER_FILE", os.path.join(self.dir.name, "owner"))):
            patcher = mock.patch.object(speak, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def dictate(self, on=True, age=0):
        if on:
            Path(self.flag).touch()
            os.utime(self.flag, (time.time() - age, time.time() - age))
        elif os.path.exists(self.flag):
            os.remove(self.flag)

    def test_a_flag_counts_only_while_the_app_keeps_it_fresh(self):
        self.assertFalse(speak.user_is_dictating())
        self.dictate()
        self.assertTrue(speak.user_is_dictating())
        self.dictate(age=speak.DICTATION_FRESH + 1)
        self.assertFalse(speak.user_is_dictating())

    def test_a_voice_sample_never_waits(self):
        self.dictate()
        with mock.patch.dict(os.environ, {"NOTCHVOICE_SAMPLE": "1"}):
            self.assertFalse(speak.user_is_dictating())

    def test_a_reply_waits_for_dictation_to_end_but_not_forever(self):
        speak.write_owner(os.getpid())
        self.assertTrue(speak.wait_while_dictating(time.time()))
        self.dictate()
        self.assertFalse(speak.wait_while_dictating(time.time() - speak.WAIT_LIMIT - 1))
        speak.write_owner(1)
        self.assertFalse(speak.wait_while_dictating(time.time()))
        with mock.patch.object(speak.time, "sleep", side_effect=lambda _: self.dictate(False)):
            speak.write_owner(os.getpid())
            self.assertTrue(speak.wait_while_dictating(time.time()))

    class FakeSay:
        pid = 4242

        def __init__(self, rounds, on_round):
            self.rounds, self.on_round, self.calls = rounds, on_round, 0

        def communicate(self, text=None, timeout=None):
            self.on_round(self.calls)
            self.calls += 1
            if self.calls < self.rounds:
                raise subprocess.TimeoutExpired("say", timeout)

        def wait(self):
            return 0

    def test_speech_pauses_while_the_user_dictates_and_resumes_after(self):
        say = self.FakeSay(6, lambda n: self.dictate(2 <= n <= 3))
        with mock.patch.object(speak.os, "kill") as kill:
            speak.play(say, "Hello", time.time())
        self.assertEqual([c.args for c in kill.call_args_list], [(4242, signal.SIGSTOP), (4242, signal.SIGCONT)])

    def test_a_reply_paused_too_long_is_dropped_instead_of_left_stopped(self):
        say = self.FakeSay(99, lambda n: self.dictate())
        with mock.patch.object(speak.os, "kill") as kill:
            speak.play(say, "Hello", time.time() - speak.DEADLINE - 1)
        self.assertEqual([c.args for c in kill.call_args_list],
                         [(4242, signal.SIGSTOP), (4242, signal.SIGTERM), (4242, signal.SIGCONT)])

    def test_taking_over_wakes_a_paused_reply_so_it_can_stop(self):
        speak.write_owner(111, 222)
        with mock.patch.object(speak.os, "kill") as kill:
            speak.take_over()
        self.assertEqual([c.args for c in kill.call_args_list],
                         [(111, signal.SIGTERM), (111, signal.SIGCONT), (222, signal.SIGTERM), (222, signal.SIGCONT)])


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.object(speak, "QUEUE_DIR", self.dir.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    def take(self, sample=False):
        ticket = speak.take_ticket(sample)
        self.addCleanup(lambda: os.path.exists(ticket[0]) and speak.leave_queue(ticket))
        return ticket

    def test_replies_take_turns_oldest_first(self):
        first, second = self.take(), self.take()
        self.assertEqual(speak.others_in_queue(first, ahead_only=True), [])
        self.assertEqual(speak.others_in_queue(second, ahead_only=True), [os.path.basename(first[0])])
        threading.Timer(0.4, speak.leave_queue, [first]).start()
        started = time.time()
        self.assertTrue(speak.wait_for_turn(second, started))
        self.assertGreaterEqual(time.time() - started, 0.3)

    def test_a_voice_sample_goes_ahead_of_waiting_replies(self):
        reply = self.take()
        sample = self.take(sample=True)
        self.assertEqual(speak.others_in_queue(sample, ahead_only=True), [])
        self.assertEqual(speak.others_in_queue(reply, ahead_only=True), [os.path.basename(sample[0])])

    def test_a_ticket_left_by_a_killed_hook_is_skipped_and_cleared(self):
        left = os.path.join(self.dir.name, f"b-{1:020d}-999999")
        Path(left).touch()
        mine = self.take()
        self.assertEqual(speak.others_in_queue(mine), [])
        self.assertFalse(os.path.exists(left))

    def test_waiting_too_long_gives_up(self):
        ahead, mine = self.take(), self.take()
        self.assertFalse(speak.wait_for_turn(mine, time.time() - speak.WAIT_LIMIT - 1))
        self.assertTrue(os.path.exists(ahead[0]))

    def hook(self, reply, sample=False):
        """Runs the real hook in its own process, with its shared files here and a silent `say` that logs its turns."""
        bin_dir = os.path.join(self.dir.name, "bin")
        if not os.path.isdir(bin_dir):
            os.makedirs(bin_dir)
            with open(os.path.join(bin_dir, "say"), "w") as f:
                f.write(f"#!/bin/sh\nread text\necho \"start $text\" >> {self.log}\nsleep 0.6\necho \"end $text\" >> {self.log}\n")
            os.chmod(os.path.join(bin_dir, "say"), 0o755)
        run = (f"import sys, os; sys.path.insert(0, {str(HOOKS)!r}); import speak; d = {self.dir.name!r}; "
               "speak.QUEUE_DIR = os.path.join(d, 'queue'); speak.OWNER_FILE = os.path.join(d, 'owner'); "
               "speak.SESSION_FILE = os.path.join(d, 'session'); speak.DUCK_FILE = os.path.join(d, 'duck'); "
               "speak.DICTATION_FILE = os.path.join(d, 'dictating'); speak.MUSIC_APPS = []; "
               "speak.MUTE_FILE = os.path.join(d, 'off'); speak.main()")
        env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"], HOME=self.dir.name)
        env.pop("NOTCHVOICE_SAMPLE", None)
        if sample:
            env["NOTCHVOICE_SAMPLE"] = "1"
        hook = subprocess.Popen([sys.executable, "-c", run], stdin=subprocess.PIPE, env=env, text=True)
        hook.stdin.write(json.dumps({"last_assistant_message": reply}))
        hook.stdin.close()
        self.addCleanup(lambda: hook.poll() is None and hook.kill())
        return hook

    def spoken(self, *hooks):
        for hook in hooks:
            self.assertEqual(hook.wait(timeout=10), 0)
        with open(self.log) as f:
            return f.read().split()

    @property
    def log(self):
        return os.path.join(self.dir.name, "say.log")

    def test_two_hooks_never_speak_at_once_and_the_music_comes_back_once(self):
        hooks = []
        for reply in ("one", "two", "three"):
            hooks.append(self.hook(reply))
            time.sleep(0.1)
        self.assertEqual(self.spoken(*hooks), ["start", "one", "end", "one", "start", "two", "end", "two", "start", "three", "end", "three"])
        self.assertEqual([n for n in os.listdir(os.path.join(self.dir.name, "queue")) if not n.startswith(".")], [])
        self.assertFalse(os.path.exists(os.path.join(self.dir.name, "owner")))

    def test_a_voice_sample_stops_the_reply_speaking_and_goes_before_the_rest(self):
        one = self.hook("one")
        time.sleep(0.15)
        two = self.hook("two")
        time.sleep(0.15)
        sample = self.hook("sample", sample=True)
        self.assertEqual(self.spoken(one, two, sample), ["start", "one", "start", "sample", "end", "sample", "start", "two", "end", "two"])

    def test_a_reply_waiting_its_turn_stays_quiet_once_voice_replies_are_off(self):
        one = self.hook("one")
        time.sleep(0.15)
        two = self.hook("two")
        time.sleep(0.15)
        Path(self.dir.name, "off").touch()
        self.assertEqual(self.spoken(one, two), ["start", "one", "end", "one"])

    def test_a_reply_of_just_a_dash_stays_quiet(self):
        with mock.patch.object(speak, "take_ticket") as queued, mock.patch.object(speak.sys, "stdin", io.StringIO(
                json.dumps({"last_assistant_message": " \u2014 "}))), mock.patch.object(speak, "MUTE_FILE", "/nonexistent"):
            speak.main()
        queued.assert_not_called()


if __name__ == "__main__":
    unittest.main()
