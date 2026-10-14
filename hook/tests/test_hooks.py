import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HOOKS = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HOOKS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


speak = load("speak")
brief = load("notchvoice_brief")
permission = load("notchvoice_permission")
mcp = load("notchvoice_mcp")
desktop = load("notchvoice_desktop")
sessions = load("notchvoice_sessions")
question = load("notchvoice_question")


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
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for name, value in (("LOG_FILE", os.path.join(self.dir.name, "permissions.log")), ("CONNECT_GRACE", 0.3)):
            patcher = mock.patch.object(permission, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_without_the_app_there_is_no_decision(self):
        with mock.patch.object(permission, "SOCKET", os.path.join(self.dir.name, "missing.sock")):
            decision, outcome = permission.ask_notch({"tool_name": "Bash"}, permission.Transcript(None, "Bash", {}))
        self.assertIsNone(decision)
        self.assertEqual(outcome, "notch app not reachable")

    def test_every_request_is_logged_with_what_happened(self):
        with mock.patch.object(permission, "ask_notch", return_value=(None, "answered in Claude")):
            run_main(permission, {"tool_name": "Bash", "tool_input": {}, "session_id": "s1", "permission_mode": "auto"})
        with open(permission.LOG_FILE) as f:
            entry = json.loads(f.readline())
        self.assertEqual((entry["session"], entry["mode"], entry["tool"], entry["outcome"]), ("s1", "auto", "Bash", "answered in Claude"))

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
                decision, _ = permission.ask_notch({"tool_name": "Bash"}, permission.Transcript(None, "Bash", {}))
            thread.join()
            server.close()
            self.assertEqual(decision, "allow")

    def test_prints_allow_and_deny_decisions_for_claude_code(self):
        for decision, behavior in (("allow", "allow"), ("deny", "deny")):
            with mock.patch.object(permission, "ask_notch", return_value=(decision, "notch")):
                output = json.loads(run_main(permission, {"tool_name": "Bash", "tool_input": {"command": "ls"}}))
            self.assertEqual(output["hookSpecificOutput"]["hookEventName"], "PermissionRequest")
            self.assertEqual(output["hookSpecificOutput"]["decision"]["behavior"], behavior)

    def test_a_dismissed_request_leaves_the_decision_to_claude_code(self):
        with mock.patch.object(permission, "ask_notch", return_value=(None, "notch: ask")):
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


if __name__ == "__main__":
    unittest.main()


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        patcher = mock.patch.object(sessions, "SESSIONS_DIR", self.dir.name)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.dir.cleanup)

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


class OrchestratorModeTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        root = self.dir.name
        self.settings = os.path.join(root, "tts_settings.json")
        self.orchestrator = os.path.join(root, "orchestrator.json")
        self.sessions = os.path.join(root, "sessions")
        os.makedirs(self.sessions)
        for module, names in ((speak, ("ORCHESTRATOR_FILE", "SESSIONS_DIR")), (brief, ("ORCHESTRATOR_FILE", "SETTINGS_FILE"))):
            for name in names:
                value = {"ORCHESTRATOR_FILE": self.orchestrator, "SESSIONS_DIR": self.sessions, "SETTINGS_FILE": self.settings}[name]
                patcher = mock.patch.object(module, name, value)
                patcher.start()
                self.addCleanup(patcher.stop)

    def write(self, path, data):
        with open(path, "w") as f:
            json.dump(data, f)

    def test_everyone_speaks_until_the_mode_is_on_and_a_session_claims_it(self):
        self.assertFalse(speak.silenced({"session_id": "worker"}, {}))
        self.assertFalse(speak.silenced({"session_id": "worker"}, {"orchestrator": True}))
        self.write(self.orchestrator, {"session_id": "boss"})
        self.assertTrue(speak.silenced({"session_id": "worker"}, {"orchestrator": True}))
        self.assertFalse(speak.silenced({"session_id": "boss"}, {"orchestrator": True}))
        self.assertFalse(speak.silenced({"session_id": "worker"}, {"orchestrator": False}))

    def test_samples_and_desktop_chats_always_speak(self):
        self.write(self.orchestrator, {"session_id": "boss"})
        self.assertFalse(speak.silenced({}, {"orchestrator": True}))

    def test_an_ended_orchestrator_hands_the_voice_back(self):
        self.write(self.orchestrator, {"session_id": "boss"})
        self.write(os.path.join(self.sessions, "boss.json"), {"state": "ended"})
        self.assertFalse(speak.silenced({"session_id": "worker"}, {"orchestrator": True}))

    def test_only_the_orchestrator_is_reminded_to_keep_replies_short(self):
        self.write(self.settings, {"orchestrator": True})
        self.write(self.orchestrator, {"session_id": "boss"})
        with mock.patch.object(brief, "MUTE_FILE", os.path.join(self.dir.name, "missing")):
            self.assertEqual(run_main(brief, {"session_id": "worker"}), "")
            self.assertIn("read aloud", run_main(brief, {"session_id": "boss"}))


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for name, sub in (("SESSIONS_DIR", "sessions"), ("HANDOFF_DIR", "handoffs")):
            os.makedirs(os.path.join(self.dir.name, sub))
            patcher = mock.patch.object(sessions, name, os.path.join(self.dir.name, sub))
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_a_compacted_session_gets_its_saved_state_back(self):
        with open(os.path.join(self.dir.name, "handoffs", "abc.json".replace(".json", ".md")), "w") as f:
            f.write("## Goal\nShip the session list")
        output = run_main(sessions, {"hook_event_name": "SessionStart", "source": "compact", "session_id": "abc"})
        self.assertIn("Ship the session list", json.loads(output)["hookSpecificOutput"]["additionalContext"])

    def test_a_normal_start_adds_nothing(self):
        self.assertEqual(run_main(sessions, {"hook_event_name": "SessionStart", "source": "startup", "session_id": "abc"}), "")


_spec = importlib.util.spec_from_file_location("snapshot", HOOKS.parent / "orchestrator" / "snapshot.py")
snapshot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(snapshot)


class TrackerTests(unittest.TestCase):
    def test_bugbot_is_read_apart_from_the_rest_of_ci(self):
        rollup = [
            {"name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"},
            {"name": "Cursor Bugbot", "status": "COMPLETED", "conclusion": "NEUTRAL"},
        ]
        self.assertEqual(snapshot.check_summary(rollup), ("passing", "findings"))
        rollup[1] = {"name": "Cursor Bugbot", "status": "IN_PROGRESS", "conclusion": ""}
        self.assertEqual(snapshot.check_summary(rollup)[1], "running")
        self.assertEqual(snapshot.check_summary([{"name": "Cursor Bugbot", "status": "COMPLETED", "conclusion": "SUCCESS"}]), ("none", "clean"))

    def test_one_failing_check_fails_ci_and_a_running_one_keeps_it_pending(self):
        self.assertEqual(snapshot.check_summary([{"name": "a", "status": "COMPLETED", "conclusion": "FAILURE"},
                                                 {"name": "b", "status": "QUEUED"}])[0], "failing")
        self.assertEqual(snapshot.check_summary([{"context": "vercel", "state": "PENDING"}])[0], "pending")
        self.assertEqual(snapshot.check_summary([]), ("none", "missing"))

    def test_the_session_that_created_a_pr_owns_it(self):
        claims = {}
        key = ("me/repo", 7)
        snapshot.claim_pr(claims, key, "mentioner", 1)
        snapshot.claim_pr(claims, key, "on-branch", 2)
        snapshot.claim_pr(claims, key, "creator", 3)
        snapshot.claim_pr(claims, key, "late-mention", 1)
        self.assertEqual(claims[key][0], "creator")

    def test_finds_prs_a_session_created_or_mentioned(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "t.jsonl")
            entries = [
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "1", "name": "Bash", "input": {"command": "gh pr create --fill"}}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "1", "content": "https://github.com/me/repo/pull/12"}]}},
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "2", "name": "Bash", "input": {"command": "gh pr list"}}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "2", "content": "see https://github.com/other/thing/pull/3"}]}},
            ]
            with open(path, "w") as f:
                f.write("\n".join(json.dumps(e) for e in entries))
            self.assertEqual(snapshot.transcript_prs(path), {("me/repo", 12): "created", ("other/thing", 3): "mentioned"})


class DictationWaitTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.flag = os.path.join(self.dir.name, "notchvoice_dictating")
        patcher = mock.patch.object(speak, "DICTATION_FILE", self.flag)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_speaks_straight_away_when_nobody_is_dictating(self):
        self.assertTrue(speak.wait_for_dictation_to_end())

    def test_waits_until_dictation_ends(self):
        open(self.flag, "w").close()
        threading.Timer(0.5, os.remove, [self.flag]).start()
        started = time.time()
        self.assertTrue(speak.wait_for_dictation_to_end())
        self.assertGreaterEqual(time.time() - started, 0.4)

    def test_a_flag_left_behind_long_ago_is_ignored(self):
        open(self.flag, "w").close()
        old = time.time() - speak.DICTATION_STALE_SECONDS - 5
        os.utime(self.flag, (old, old))
        self.assertFalse(speak.user_is_dictating())


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.object(speak, "QUEUE_DIR", self.dir.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    def ticket(self, ns, pid):
        path = os.path.join(self.dir.name, f"{ns:020d}-{pid}")
        open(path, "w").close()
        return path

    def test_a_new_reply_waits_behind_the_one_speaking(self):
        first = self.ticket(1, os.getpid())
        second = self.ticket(2, os.getpid())
        self.assertEqual(speak.queue_ahead_of(first), [])
        self.assertEqual(speak.queue_ahead_of(second), [os.path.basename(first)])
        threading.Timer(0.4, speak.leave_queue, [first]).start()
        self.assertTrue(speak.wait_for_turn(second))

    def test_a_ticket_left_by_a_dead_hook_is_cleared(self):
        dead = self.ticket(1, 999999)
        mine = self.ticket(2, os.getpid())
        self.assertEqual(speak.queue_ahead_of(mine), [])
        self.assertFalse(os.path.exists(dead))

    def test_the_last_reply_knows_nobody_else_is_waiting(self):
        mine = speak.enqueue()
        self.assertFalse(speak.others_waiting(mine))
        other = self.ticket(time.time_ns() + 1, os.getpid())
        self.assertTrue(speak.others_waiting(mine))
        speak.leave_queue(other)

    def test_skip_all_silences_replies_queued_before_it(self):
        marker = os.path.join(self.dir.name, "skip")
        with mock.patch.object(speak, "SKIP_MARKER", marker):
            early = self.ticket(100, os.getpid())
            late = self.ticket(300, os.getpid())
            self.assertFalse(speak.skipped_by_user(early))
            with open(marker, "w") as f:
                f.write("200")
            self.assertTrue(speak.skipped_by_user(early))
            self.assertFalse(speak.skipped_by_user(late))

    def test_an_em_dash_or_nothing_means_stay_quiet(self):
        self.assertTrue(speak.is_silent("\u2014"))
        self.assertTrue(speak.is_silent("  \u2014\n"))
        self.assertTrue(speak.is_silent(""))
        self.assertFalse(speak.is_silent("\u2014 nothing new, all sessions idle"))


class QuestionHookTests(unittest.TestCase):
    QUESTIONS = [{"question": "Which database?", "header": "DB", "multiSelect": False,
                  "options": [{"label": "Postgres", "description": ""}, {"label": "SQLite", "description": ""}]}]

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.object(question, "LOG_FILE", os.path.join(self.dir.name, "log"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def payload(self):
        return {"tool_name": "AskUserQuestion", "tool_input": {"questions": self.QUESTIONS}, "session_id": "s"}

    def test_answers_from_the_notch_go_back_as_the_tool_input(self):
        with mock.patch.object(question, "ask_notch", return_value=({"Which database?": "SQLite"}, "answered in the notch")):
            output = json.loads(run_main(question, self.payload()))["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "PreToolUse")
        self.assertEqual(output["permissionDecision"], "allow")
        self.assertEqual(output["updatedInput"]["answers"], {"Which database?": "SQLite"})
        self.assertEqual(output["updatedInput"]["questions"], self.QUESTIONS)

    def test_handing_back_or_no_app_leaves_the_question_to_claude(self):
        with mock.patch.object(question, "ask_notch", return_value=(None, "handed back to Claude")):
            self.assertEqual(run_main(question, self.payload()), "")
        with mock.patch.object(question, "SOCKET", os.path.join(self.dir.name, "missing.sock")):
            self.assertEqual(run_main(question, self.payload()), "")

    def test_other_tools_are_ignored(self):
        with mock.patch.object(question, "ask_notch") as ask:
            self.assertEqual(run_main(question, {"tool_name": "Bash", "tool_input": {}}), "")
        ask.assert_not_called()


class BlockedNoticeTests(unittest.TestCase):
    def test_an_auto_mode_block_leaves_a_notice_for_the_notch(self):
        with tempfile.TemporaryDirectory() as folder:
            with mock.patch.object(sessions, "SESSIONS_DIR", os.path.join(folder, "s")), \
                 mock.patch.object(sessions, "NOTICES_DIR", os.path.join(folder, "n")):
                os.makedirs(os.path.join(folder, "s"))
                run_main(sessions, {"hook_event_name": "PermissionDenied", "session_id": "abc", "cwd": "/x/demo",
                                    "tool_name": "Bash", "tool_input": {"command": "rm -rf build", "description": "Clean"}})
                files = os.listdir(os.path.join(folder, "n"))
                self.assertEqual(len(files), 1)
                with open(os.path.join(folder, "n", files[0])) as f:
                    notice = json.load(f)
        self.assertEqual((notice["project"], notice["title"], notice["detail"]), ("demo", "Running Clean", "rm -rf build"))
