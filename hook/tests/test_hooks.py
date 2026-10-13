import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
import threading
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


if __name__ == "__main__":
    unittest.main()
