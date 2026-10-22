"""Spoken briefings for container sessions, a pause between briefings, and
the word cap: the daemon's handoff to the voice worker, the hook's payload,
and the worker's prompt, prefix, trim and gap. No audio, no Haiku."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from test_ccpilld import evt  # noqa: E402
from test_containers import REPO, ContainerBase, hook, load  # noqa: E402

worker = load("worker_br", os.path.join(REPO, "voice", "worker.py"))


class DaemonHandoffTest(ContainerBase):
    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.speaker, ".venv", "bin"))
        open(os.path.join(self.speaker, ".venv", "bin", "python"), "w").close()

    def jobs(self):
        spool = os.path.join(self.speaker, "spool")
        out = []
        for n in sorted(os.listdir(spool)) if os.path.isdir(spool) else []:
            with open(os.path.join(spool, n)) as f:
                out.append(json.load(f))
        return out

    def test_stop_queues_a_job_with_the_message_and_container(self):
        self.store.apply_container("web-dev", evt("stop", sid="c1", pid=3535, cwd="/root/w/api",
                                                   speech={"text": "Done. All 41 tests pass."}))
        [job] = self.jobs()
        self.assertEqual(job["container"], "web-dev")
        self.assertEqual(job["pill_mode"], "stop")
        self.assertEqual(job["last_assistant_message"], "Done. All 41 tests pass.")
        self.assertEqual(job["cwd"], "/root/w/api")
        args, _ = self.spawner.calls[0]
        self.assertEqual(args[-3:-1], [os.path.join(self.speaker, ".venv", "bin", "python"),
                                       os.path.join(self.speaker, "worker.py")])
        self.assertEqual(self.spawner.envs[0]["CCPILL_VOICE_LOG"],
                         os.path.join(self.speaker, "spool", "voice.log"))

    def test_notify_queues_the_prompt(self):
        self.store.apply_container("web-dev", evt("notify", msg="Claude needs your permission to use Bash",
                                                   speech={"notification_type": "permission_prompt"}))
        [job] = self.jobs()
        self.assertEqual((job["pill_mode"], job["notification_type"]), ("notify", "permission_prompt"))
        self.assertIn("permission", job["message"])

    def test_session_still_tracked_and_speech_kept_out_of_the_model(self):
        self.store.apply_container("web-dev", evt("stop", sid="c1", speech={"text": "x"}))
        self.assertEqual(self.store.sessions[0].state, "done")
        self.assertNotIn("speech", json.dumps(self.store.snapshot()))

    def test_no_job_when_muted_missing_remote_empty_or_not_a_turn_end(self):
        open(os.path.join(self.speaker, ".off"), "w").close()
        self.store.apply_container("web-dev", evt("stop", speech={"text": "muted"}))
        os.remove(os.path.join(self.speaker, ".off"))
        self.store.apply_container("web-dev", evt("stop", ssh_client="203.0.113.9", speech={"text": "far"}))
        self.store.apply_container("web-dev", evt("stop", speech={"text": "  "}))
        self.store.apply_container("web-dev", evt("prompt", speech={"text": "a prompt"}))
        shutil.rmtree(os.path.join(self.speaker, ".venv"))
        self.store.apply_container("web-dev", evt("stop", speech={"text": "no voice"}))
        self.assertEqual(self.jobs(), [])
        self.assertEqual(self.spawner.calls, [])


class HookSpeechTest(unittest.TestCase):
    def test_stop_carries_the_final_message(self):
        self.assertEqual(hook.speech_for("stop", {"last_assistant_message": "All done."}), {"text": "All done."})

    def test_falls_back_to_the_transcript(self):
        d = tempfile.mkdtemp()
        try:
            t = os.path.join(d, "t.jsonl")
            with open(t, "w") as f:
                for text in ("first", "the final word"):
                    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}) + "\n")
                f.write(json.dumps({"type": "user", "message": {"content": "thanks"}}) + "\n")
            self.assertEqual(hook.speech_for("stop", {"transcript_path": t}), {"text": "the final word"})
        finally:
            shutil.rmtree(d)

    def test_notify_and_other_modes(self):
        self.assertEqual(hook.speech_for("notify", {"notification_type": "permission_prompt"}),
                         {"notification_type": "permission_prompt"})
        self.assertIsNone(hook.speech_for("tool", {}))

    def test_long_messages_are_capped(self):
        self.assertEqual(len(hook.speech_for("stop", {"last_assistant_message": "x" * 20000})["text"]), 8000)


class StopButtonTest(ContainerBase):
    def test_briefing_names_its_session_and_stop_clears_it(self):
        self.store.apply(evt("start", sid="c1"))
        self.store.apply(evt("briefing", sid="c1", text="Shipped it.", duration=3))
        self.assertEqual(self.store.snapshot()["briefing"]["sid"], "c1")
        self.assertEqual(self.store.snapshot()["pill"]["state"], "speaking")
        self.store.stop_speech()
        self.assertIsNone(self.store.snapshot()["briefing"])
        self.assertNotEqual(self.store.snapshot()["pill"]["state"], "speaking")


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self._orig = (worker.VOICE_DIR, worker.SPOKE_STAMP)
        worker.VOICE_DIR = self.tmp
        worker.SPOKE_STAMP = os.path.join(self.tmp, "last-spoke")
        with open(os.path.join(self.tmp, "prompt.txt"), "w") as f:
            f.write("You are Alfred.")

    def tearDown(self):
        worker.VOICE_DIR, worker.SPOKE_STAMP = self._orig
        shutil.rmtree(self.tmp)

    def test_spoken_name(self):
        self.assertEqual(worker.spoken_name("web-dev"), "web dev")
        self.assertEqual(worker.spoken_name("data_dev.2"), "data dev 2")

    def test_prompt_carries_the_cap_and_the_container_rule(self):
        seen = {}

        def fake_run(args, input, **kw):
            seen["prompt"] = input
            return mock.Mock(returncode=0, stdout="Batching is done.")
        with mock.patch.object(worker.subprocess, "run", fake_run):
            line = worker.summarize("long message", "stop", "haiku", None, 25, "web-dev")
        self.assertEqual(line, "Batching is done.")
        self.assertIn("Hard limit: 25 words", seen["prompt"])
        self.assertIn("Do not name the container", seen["prompt"])
        with mock.patch.object(worker.subprocess, "run", fake_run):
            worker.summarize("long message", "stop", "haiku")
        self.assertNotIn("Hard limit", seen["prompt"])
        self.assertNotIn("container", seen["prompt"])

    def test_trim_keeps_whole_sentences(self):
        short = "Batching is done and fifteen times faster. Decide on retries?"
        self.assertEqual(worker.trim_words(short, 25), short)
        long = ("The batch writer is finished. " * 3) + "Everything passes and the benchmark is fifteen times faster than before today."
        out = worker.trim_words(long, 10)
        self.assertTrue(out.endswith("."))
        self.assertLessEqual(len(out.split()), 15)
        one = "word " * 60 + "end."
        self.assertEqual(worker.trim_words(one, 10), one.strip())   # never less than a sentence
        self.assertEqual(worker.trim_words(long, 0), long)

    def stamp(self, t):
        with open(worker.SPOKE_STAMP, "w") as f:
            json.dump({"t": t}, f)

    def test_gap_waits_only_for_what_is_left(self):
        slept = []
        self.stamp(100.0)
        self.assertAlmostEqual(worker.wait_for_gap({"briefing_gap_seconds": 2.5}, now=lambda: 101.0,
                                                   sleep=slept.append), 1.5)
        self.assertAlmostEqual(slept[0], 1.5)

    def test_no_gap_long_after_or_when_off(self):
        slept = []
        self.stamp(100.0)
        self.assertEqual(worker.wait_for_gap({"briefing_gap_seconds": 2.5}, now=lambda: 200.0, sleep=slept.append), 0)
        self.assertEqual(worker.wait_for_gap({"briefing_gap_seconds": 0}, now=lambda: 100.1, sleep=slept.append), 0)
        os.remove(worker.SPOKE_STAMP)
        self.assertEqual(worker.wait_for_gap({"briefing_gap_seconds": 2.5}, now=lambda: 5.0, sleep=slept.append), 0)
        self.assertEqual(slept, [])

    def test_short_plain_messages_skip_haiku(self):
        self.assertTrue(worker.speakable_as_is("Claude needs your permission to use Bash", 25))
        self.assertTrue(worker.speakable_as_is("Done, all green.", 25))
        for raw in ("Edited src/writer.rs and it builds", "Run `make test` now", "word " * 40,
                    "Fixed config.json", "Ticket 12345 closed", "", "x = 1"):
            self.assertFalse(worker.speakable_as_is(raw, 25), raw)

    def test_clip_keeps_head_and_tail(self):
        raw = "OUTCOME " + "x" * 10000 + " QUESTION?"
        out = worker.clip(raw, 4000)
        self.assertLess(len(out), 4100)
        self.assertTrue(out.startswith("OUTCOME") and out.endswith("QUESTION?"))
        self.assertEqual(worker.clip("short"), "short")

    def test_no_haiku_call_for_a_plain_prompt(self):
        job = os.path.join(self.tmp, "job.json")
        with open(job, "w") as f:
            json.dump({"pill_mode": "notify", "container": "web-dev", "session_id": "s1", "cwd": "/root/w",
                       "message": "Claude needs your permission to use Bash",
                       "notification_type": "permission_prompt"}, f)
        spoken = {}
        cfg = dict(worker.load_config(), enabled=True)
        with mock.patch.object(worker, "load_config", lambda: cfg), \
                mock.patch.object(worker, "summarize", lambda *a, **k: self.fail("Haiku was called")), \
                mock.patch.object(worker, "session_on_screen", lambda cwd, ct="": False), \
                mock.patch.object(worker, "speak", lambda text, cfg, meta=None: spoken.update(text=text)), \
                mock.patch.object(worker, "NOTIFY_STAMP", os.path.join(self.tmp, "last-notify")), \
                mock.patch.object(worker, "SPOOL", self.tmp), \
                mock.patch.object(sys, "argv", ["worker.py", job]):
            worker.main()
        self.assertEqual(spoken["text"], "web dev: Claude needs your permission to use Bash")

    def test_container_briefing_opens_with_its_name(self):
        job = os.path.join(self.tmp, "job.json")
        with open(job, "w") as f:
            json.dump({"pill_mode": "stop", "container": "web-dev", "session_id": "s1",
                       "cwd": "/root/workspace/todo-app", "last_assistant_message": "Done, all green."}, f)
        spoken = {}
        cfg = dict(worker.load_config(), enabled=True)
        with mock.patch.object(worker, "load_config", lambda: cfg), \
                mock.patch.object(worker, "summarize", lambda *a, **k: "Everything passes now."), \
                mock.patch.object(worker, "session_on_screen", lambda cwd, ct="": spoken.setdefault("screen", (cwd, ct)) and False), \
                mock.patch.object(worker, "speak", lambda text, cfg, meta=None: spoken.update(text=text, meta=meta)), \
                mock.patch.object(worker, "STOP_STAMP", os.path.join(self.tmp, "last-stop")), \
                mock.patch.object(sys, "argv", ["worker.py", job]):
            worker.main()
        self.assertEqual(spoken["text"], "web dev: Everything passes now.")
        self.assertEqual(spoken["meta"], {"sid": "s1", "repo": "todo-app"})
        self.assertEqual(spoken["screen"], ("/root/workspace/todo-app", "web-dev"))

    def test_host_briefing_has_no_prefix(self):
        job = os.path.join(self.tmp, "job.json")
        with open(job, "w") as f:
            json.dump({"pill_mode": "stop", "session_id": "s1", "cwd": "/home/u/app",
                       "last_assistant_message": "Done."}, f)
        spoken = {}
        cfg = dict(worker.load_config(), enabled=True)
        with mock.patch.object(worker, "load_config", lambda: cfg), \
                mock.patch.object(worker, "summarize", lambda *a, **k: "All done."), \
                mock.patch.object(worker, "session_on_screen", lambda cwd, ct="": False), \
                mock.patch.object(worker, "speak", lambda text, cfg, meta=None: spoken.update(text=text)), \
                mock.patch.object(worker, "STOP_STAMP", os.path.join(self.tmp, "last-stop")), \
                mock.patch.object(sys, "argv", ["worker.py", job]):
            worker.main()
        self.assertEqual(spoken["text"], "All done.")


if __name__ == "__main__":
    unittest.main()
