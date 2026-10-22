"""Unit tests for ccpilld. Stdlib unittest only:

    python3 -m unittest discover linux/daemon/tests

Everything runs against a temporary data directory and a fake clock, fake
process runner and fake liveness check, so no tmux, no audio and no real
Claude sessions are involved.
"""
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import ccpilld  # noqa: E402


class FakeClock:
    def __init__(self, start=1000.0):
        self.now = start

    def __call__(self):
        return self.now

    def advance(self, dt):
        self.now += dt


class FakeRunner:
    """Records every command; answers from (prefix tuple -> (out, code)) rules."""

    def __init__(self, rules=None):
        self.rules = list(rules or [])
        self.calls = []

    def __call__(self, args, timeout=8):
        self.calls.append(list(args))
        for prefix, result in self.rules:
            if tuple(args[:len(prefix)]) == tuple(prefix):
                return result() if callable(result) else result
        return "", 1

    def called(self, *prefix):
        return [c for c in self.calls if tuple(c[:len(prefix)]) == tuple(prefix)]


class FakeSpawner:
    def __init__(self):
        self.calls = []
        self.envs = []

    def __call__(self, args, cwd=None, env=None):
        self.calls.append((list(args), cwd))
        self.envs.append(env)
        return True


def evt(typ, sid="s1", repo="demo", cwd="/home/u/demo", pid=4242, **extra):
    e = {"type": typ, "t": 0, "sid": sid, "cwd": cwd, "repo": repo, "pid": pid, "remote": False}
    e.update(extra)
    return e


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ccpill-test-")
        self.events = os.path.join(self.tmp, "events")
        os.makedirs(self.events)
        self._orig = (ccpilld.LOG_PATH, ccpilld.STATE_PATH, ccpilld.EVENTS_DIR)
        ccpilld.LOG_PATH = os.path.join(self.tmp, "pill.log")
        ccpilld.STATE_PATH = os.path.join(self.tmp, "state.json")
        ccpilld.EVENTS_DIR = self.events
        self.speaker = os.path.join(self.tmp, "voice")
        os.makedirs(self.speaker)
        self.clock = FakeClock()
        self.runner = FakeRunner()
        self.spawner = FakeSpawner()
        self.dead = set()
        self.config = ccpilld.Config({"speaker": self.speaker, "name": "Nova", "terminal": "konsole",
                                      "home_repo": os.path.join(self.tmp, "work"), "claude_bin": "/x/claude"})
        self.store = ccpilld.Store(self.config, clock=self.clock, runner=self.runner,
                                   spawner=self.spawner, alive=lambda pid: pid not in self.dead,
                                   rng=lambda: 0.1, sleeper=lambda s: None,
                                   ancestors=lambda pid: self.tree.get(pid, set()))
        self.tree = {}   # fake process tree: pid -> {pid and its ancestors}

    def tearDown(self):
        ccpilld.LOG_PATH, ccpilld.STATE_PATH, ccpilld.EVENTS_DIR = self._orig
        shutil.rmtree(self.tmp, ignore_errors=True)

    def log_text(self):
        try:
            with open(ccpilld.LOG_PATH) as f:
                return f.read()
        except OSError:
            return ""

    def tmux_server(self, taken=()):
        """Fake tmux: has-session answers from a set of existing names that
        new-session adds to, like the real thing."""
        existing = set(taken)

        def has(args):
            return ("", 0) if args[3].lstrip("=") in existing else ("", 1)

        def new(args):
            existing.add(args[4])
            return "", 0
        orig = self.runner.__call__

        def call(args, timeout=8):
            if args[:2] == ["tmux", "has-session"]:
                self.runner.calls.append(list(args))
                return has(args)
            if args[:2] == ["tmux", "new-session"]:
                self.runner.calls.append(list(args))
                return new(args)
            return orig(args, timeout)
        self.store.run = call

    def enable_voice(self):
        os.makedirs(os.path.join(self.speaker, ".venv", "bin"))
        open(os.path.join(self.speaker, ".venv", "bin", "python"), "w").close()
        open(os.path.join(self.speaker, "say.py"), "w").close()


class SessionsTest(Base):
    def test_start_is_done_and_idle(self):
        self.store.apply(evt("start"))
        self.assertEqual(self.store.sessions[0].state, "done")
        self.assertEqual(self.store.pill_state(), ("idle", ""))
        self.assertIn("session start: demo [s1]", self.log_text())

    def test_prompt_is_working_with_repo_label(self):
        self.store.apply(evt("prompt"))
        self.assertEqual(self.store.pill_state(), ("working", "demo"))

    def test_two_working_sessions_count(self):
        self.store.apply(evt("prompt", sid="a", repo="one"))
        self.clock.advance(1)
        self.store.apply(evt("prompt", sid="b", repo="two", pid=1))
        self.assertEqual(self.store.pill_state(), ("working", "2 sessions"))

    def test_idle_nag_is_ignored_but_real_notify_waits(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("notify", idle=True, msg="Claude is waiting for your input"))
        self.assertEqual(self.store.sessions[0].state, "working")
        self.assertIn("idle nag ignored: demo", self.log_text())
        self.store.apply(evt("notify", idle=False, msg="Claude needs your permission"))
        self.assertEqual(self.store.sessions[0].state, "waiting")

    def test_waiting_outranks_working(self):
        self.store.apply(evt("prompt", sid="a"))
        self.store.apply(evt("notify", sid="b", pid=1, idle=False))
        self.assertEqual(self.store.pill_state(), ("waiting", ""))

    def test_end_removes_and_hides(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("end"))
        self.assertEqual(self.store.sessions, [])
        self.assertEqual(self.store.pill_state(), ("hidden", ""))

    def test_since_only_moves_on_state_change(self):
        self.store.apply(evt("prompt"))
        self.clock.advance(5)
        self.store.apply(evt("tool", label="editing a.py"))
        self.assertEqual(self.store.sessions[0].since, 1000.0)
        self.clock.advance(5)
        self.store.apply(evt("stop"))
        self.assertEqual(self.store.sessions[0].since, 1010.0)
        self.assertIsNone(self.store.sessions[0].activity)

    def test_upsert_updates_pid_and_cwd(self):
        self.store.apply(evt("start", pid=0, cwd=""))
        self.assertEqual(self.store.sessions[0].pid, 0)
        self.store.apply(evt("prompt", pid=77, cwd="/p/newname", repo="newname"))
        s = self.store.sessions[0]
        self.assertEqual((s.pid, s.cwd, s.repo), (77, "/p/newname", "newname"))

    def test_tool_event_for_unknown_session_creates_it(self):
        self.store.apply(evt("tool", label="running the tests"))
        s = self.store.sessions[0]
        self.assertEqual((s.state, s.activity), ("working", "running the tests"))

    def test_tool_without_label_or_sid_is_ignored(self):
        self.store.apply(evt("tool"))
        self.store.apply(evt("tool", sid="", label="x"))
        self.assertEqual(self.store.sessions, [])

    def test_tool_wakes_a_done_session(self):
        self.store.apply(evt("start"))
        self.clock.advance(3)
        self.store.apply(evt("tool", label="reading x"))
        self.assertEqual(self.store.sessions[0].state, "working")
        self.assertEqual(self.store.sessions[0].since, 1003.0)

    def test_real_event_replaces_tmux_placeholder(self):
        self.store.sessions.append(ccpilld.Session("tmux-4242", "demo", "/home/u/demo", 4242, "done", 0))
        self.store.apply(evt("prompt"))
        self.assertEqual([s.id for s in self.store.sessions], ["s1"])

    def test_remote_flag_kept(self):
        self.store.apply(evt("start", remote=True))
        self.assertTrue(self.store.sessions[0].remote)


class NarrationTest(Base):
    def phase(self, want):
        # Move the clock forward to the start of the next wanted phase of
        # the 3.5 s cycle (never backwards).
        p = ccpilld.NARRATION_PHASE
        base = int(self.clock.now / p)
        while base % 2 != want or base * p + 0.1 < self.clock.now:
            base += 1
        self.clock.now = base * p + 0.1

    def test_repo_then_activity(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("tool", label="editing a.py"))
        self.phase(0)
        self.store.tick()
        self.assertEqual(self.store.narration, "demo")
        self.phase(1)
        self.store.tick()
        self.assertEqual(self.store.narration, "editing a.py")

    def test_stale_activity_not_narrated(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("tool", label="editing a.py"))
        self.clock.advance(ccpilld.ACTIVITY_FRESH + 1)
        self.phase(1)
        self.store.tick()
        self.assertEqual(self.store.narration, "demo")

    def test_elapsed_minutes_after_three(self):
        self.store.apply(evt("prompt"))
        self.clock.advance(3 * 60 + 5)
        self.phase(0)
        self.store.tick()
        self.assertEqual(self.store.narration, "demo · 3m")

    def test_multiple_sessions_label(self):
        self.store.apply(evt("prompt", sid="a"))
        self.store.apply(evt("prompt", sid="b", pid=2))
        self.phase(0)
        self.store.tick()
        self.assertEqual(self.store.narration, "2 sessions")

    def test_narration_clears_after_delay(self):
        self.store.apply(evt("prompt"))
        self.phase(0)
        self.store.tick()
        self.assertEqual(self.store.narration, "demo")
        self.store.apply(evt("stop"))
        self.clock.advance(ccpilld.HOLD_SECONDS + 0.1)
        self.store.tick()
        self.assertEqual(self.store.narration, "demo")   # still sliding out
        self.clock.advance(ccpilld.NARRATION_CLEAR_DELAY)
        self.store.tick()
        self.assertEqual(self.store.narration, "")

    def test_contraction_hold(self):
        self.store.apply(evt("prompt"))
        self.store.tick()
        self.store.apply(evt("stop"))
        self.clock.advance(0.5)
        self.store.tick()
        self.assertEqual(self.store.pill_state(), ("working", "demo"))
        self.clock.advance(ccpilld.HOLD_SECONDS)
        self.store.tick()
        self.assertEqual(self.store.pill_state(), ("idle", ""))

    def test_hold_does_not_mask_waiting(self):
        self.store.apply(evt("prompt"))
        self.store.tick()
        self.store.apply(evt("notify", idle=False))
        self.store.tick()
        self.assertEqual(self.store.pill_state(), ("waiting", ""))


class BriefingAndMomentTest(Base):
    def test_duration_fallback_and_last_briefing(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("briefing", text="one two three four", silent=True))
        b = self.store.briefing
        self.assertAlmostEqual(b["duration"], 1.2)
        self.assertTrue(b["silent"])
        self.assertFalse(b["sad"])
        self.assertEqual(self.store.sessions[0].last_briefing, "one two three four")
        self.assertEqual(self.store.pill_state(), ("speaking", ""))

    def test_duration_fallback_caps_at_six(self):
        self.store.apply(evt("briefing", text=" ".join(["w"] * 40)))
        self.assertEqual(self.store.briefing["duration"], 6.0)

    def test_sad_detection(self):
        self.store.apply(evt("briefing", text="The tests failed again", duration=2))
        self.assertTrue(self.store.briefing["sad"])
        self.store.briefing = None
        self.store.apply(evt("briefing", text="It couldn't find the file", duration=2))
        self.assertTrue(self.store.briefing["sad"])

    def test_empty_briefing_ignored(self):
        self.store.apply(evt("briefing", text=""))
        self.assertIsNone(self.store.briefing)

    def test_bloom_then_star_moment(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("stop"))
        self.store.apply(evt("briefing", text="All green.", duration=2.0))
        self.clock.advance(2.0 + ccpilld.BRIEFING_TAIL - 0.1)
        self.store.tick()
        self.assertIsNotNone(self.store.briefing)
        self.clock.advance(0.2)
        self.store.tick()
        self.assertIsNone(self.store.briefing)
        self.assertEqual(self.store.moment["kind"], "star")
        self.assertEqual(self.store.moment["critter"], "charlie")
        self.assertEqual(self.store.moment["repo"], "demo")
        self.assertEqual(self.store.pill_state(), ("moment", "star"))
        self.clock.advance(ccpilld.MOMENT_DURATION["star"] + 0.01)
        self.store.tick()
        self.assertIsNone(self.store.moment)
        self.assertEqual(self.store.pill_state(), ("idle", ""))
        self.assertIn("briefing cleared", self.log_text())
        self.assertIn("moment: star (charlie) for demo", self.log_text())

    def test_sad_briefing_gives_sad_moment(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("stop"))
        self.store.apply(evt("briefing", text="Build broke.", duration=1.0))
        self.clock.advance(1.0 + ccpilld.BRIEFING_TAIL + 0.01)
        self.store.tick()
        self.assertEqual(self.store.moment["kind"], "sad")
        self.assertEqual(self.store.moment["duration"], 3.0)

    def test_moment_fallback_without_briefing(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("stop"))
        self.clock.advance(ccpilld.MOMENT_FALLBACK - 0.1)
        self.store.tick()
        self.assertIsNone(self.store.moment)
        self.clock.advance(0.2)
        self.store.tick()
        self.assertEqual(self.store.moment["kind"], "star")

    def test_briefing_cancels_fallback(self):
        self.store.apply(evt("prompt"))
        self.store.apply(evt("stop"))
        self.store.apply(evt("briefing", text="Done.", duration=10.0))
        self.clock.advance(ccpilld.MOMENT_FALLBACK + 1)
        self.store.tick()
        self.assertIsNone(self.store.moment)        # waits for the bloom
        self.assertIsNotNone(self.store.briefing)

    def test_stop_without_working_earns_no_moment(self):
        self.store.apply(evt("start"))
        self.store.apply(evt("stop"))
        self.clock.advance(ccpilld.MOMENT_FALLBACK + 1)
        self.store.tick()
        self.assertIsNone(self.store.moment)

    def test_briefing_backstop_in_reap(self):
        self.store.apply(evt("briefing", text="Hello there.", duration=1.0))
        self.store._briefing_clear_at = None          # simulate a lost deadline
        self.clock.advance(ccpilld.REAP_INTERVAL + 2)
        self.store.tick()
        self.assertIsNone(self.store.briefing)


class ReapAndGcTest(Base):
    def test_dead_pid_is_reaped(self):
        self.store.apply(evt("prompt", pid=555))
        self.dead.add(555)
        self.clock.advance(ccpilld.REAP_INTERVAL)
        self.store.tick()
        self.assertEqual(self.store.sessions, [])
        self.assertIn("reaped dead session: demo [s1]", self.log_text())

    def test_pid_zero_never_reaped(self):
        self.store.apply(evt("start", pid=0))
        self.clock.advance(ccpilld.REAP_INTERVAL)
        self.store.tick()
        self.assertEqual(len(self.store.sessions), 1)

    def test_gc_kills_only_idle_detached_pill_sessions(self):
        self.runner.rules.append((("tmux", "list-panes"), (
            "cc-work-pill\t0\t100\ncc-work-pill-2\t1\t200\ncc-work\t0\t300\n", 0)))
        for pid in (100, 200, 300):
            self.store.apply(evt("stop", sid=f"s{pid}", pid=pid))
        self.clock.advance(self.config.pill_gc_minutes * 60 + ccpilld.REAP_INTERVAL + 1)
        self.store.tick()
        kills = self.runner.called("tmux", "kill-session")
        self.assertEqual(kills, [["tmux", "kill-session", "-t", "cc-work-pill"]])

    def test_gc_disabled_with_zero_window(self):
        self.config.pill_gc_minutes = 0
        self.store.apply(evt("stop", pid=100))
        self.clock.advance(10 ** 6)
        self.store.tick()
        self.assertEqual(self.runner.called("tmux", "list-panes"), [])

    def test_adopt_existing(self):
        self.runner.rules.append((("tmux", "list-panes"), (
            "cc-demo\t900\t/home/u/demo\tclaude\n"
            "cc-other\t901\t/home/u/other\tnode\n"
            "main\t902\t/home/u\tclaude\n"
            "cc-shell\t903\t/home/u/shell\tzsh\n", 0)))
        self.store.sessions.append(ccpilld.Session("s-known", "other", "/home/u/other", 901, "working", 0))
        self.store.adopt_existing()
        ids = sorted(s.id for s in self.store.sessions)
        self.assertEqual(ids, ["s-known", "tmux-900"])
        adopted = self.store._find("tmux-900")
        self.assertEqual((adopted.repo, adopted.state), ("demo", "done"))


class DrainAndPublishTest(Base):
    def write_evt(self, name, obj):
        with open(os.path.join(self.events, name), "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))

    def test_drain_applies_in_name_order_and_deletes(self):
        self.write_evt("evt-2.json", evt("stop"))
        self.write_evt("evt-1.json", evt("prompt"))
        self.write_evt("evt-3.json", "{not json")
        self.write_evt(".tmp-9", evt("prompt"))      # in-progress hook write: left alone
        n = ccpilld.drain_events(self.store, self.events)
        self.assertEqual(n, 2)
        self.assertEqual(self.store.sessions[0].state, "done")
        self.assertEqual(sorted(os.listdir(self.events)), [".tmp-9"])

    def test_publish_only_on_change(self):
        path = ccpilld.STATE_PATH
        self.assertTrue(self.store.publish_if_changed(path))
        self.clock.advance(5)
        self.assertFalse(self.store.publish_if_changed(path))   # only the clock moved
        self.store.apply(evt("prompt"))
        self.assertTrue(self.store.publish_if_changed(path))
        with open(path) as f:
            snap = json.load(f)
        self.assertEqual(snap["v"], 2)
        self.assertEqual(snap["pill"]["state"], "working")
        self.assertEqual(snap["sessions"][0]["id"], "s1")
        self.assertEqual(snap["voice"]["name"], "Nova")
        self.assertFalse(os.path.exists(path + f".tmp-{os.getpid()}"))

    def test_snapshot_shape(self):
        snap = self.store.snapshot()
        for key in ("v", "t", "pill", "sessions", "briefing", "moment", "voice", "toast", "hotkey"):
            self.assertIn(key, snap)
        self.assertEqual(snap["pill"], {"state": "hidden", "label": "", "narration": ""})

    def test_toast_clears(self):
        self.store.flash("Hi")
        self.assertEqual(self.store.snapshot()["toast"], "Hi")
        self.clock.advance(ccpilld.TOAST_SECONDS + 0.1)
        self.store.tick()
        self.assertIsNone(self.store.toast)


class ConfigTest(unittest.TestCase):
    def test_defaults(self):
        c = ccpilld.Config({})
        self.assertEqual(c.name, "Jarvis")
        self.assertEqual(c.permission_mode, "acceptEdits")
        self.assertEqual(c.terminal, "konsole")
        self.assertEqual(c.port, ccpilld.DEFAULT_PORT)
        self.assertEqual(c.pill_gc_minutes, 30.0)
        self.assertTrue(c.speaker.endswith("/voice"))

    def test_values_and_validation(self):
        c = ccpilld.Config({"daemon_port": 80, "pill_gc_minutes": "x", "name": "", "speaker": "~/v"})
        self.assertEqual(c.port, ccpilld.DEFAULT_PORT)
        self.assertEqual(c.pill_gc_minutes, 30.0)
        self.assertEqual(c.name, "Jarvis")
        self.assertEqual(c.speaker, os.path.expanduser("~/v"))
        c = ccpilld.Config({"daemon_port": 20000, "pill_gc_minutes": 0})
        self.assertEqual((c.port, c.pill_gc_minutes), (20000, 0.0))

    def test_load_missing_or_broken_file(self):
        tmp = tempfile.mkdtemp()
        try:
            self.assertEqual(ccpilld.Config.load(os.path.join(tmp, "nope.json")).name, "Jarvis")
            p = os.path.join(tmp, "bad.json")
            with open(p, "w") as f:
                f.write("[1,2")
            self.assertEqual(ccpilld.Config.load(p).name, "Jarvis")
        finally:
            shutil.rmtree(tmp)


class ActionsTest(Base):
    PANES = "%3\tcc-demo\t/home/u/demo\t700\n%4\tmain\t/home/u\t701\n"

    def test_terminal_command_table(self):
        tail = ["tmux", "attach", "-t", "x"]
        self.config.terminal = "konsole"
        self.assertEqual(self.store.terminal_command(tail), ["konsole", "-e"] + tail)
        self.config.terminal = "kitty"
        self.assertEqual(self.store.terminal_command(tail), ["kitty"] + tail)
        self.config.terminal = "/usr/bin/wezterm"
        self.assertEqual(self.store.terminal_command(tail), ["/usr/bin/wezterm", "start", "--"] + tail)
        self.config.terminal = "st"
        self.assertEqual(self.store.terminal_command(tail), ["st", "-e"] + tail)
        self.assertEqual(self.store.terminal_command([]), ["st"])

    def test_send_prompt(self):
        self.runner.rules.append((("tmux", "list-panes"), (self.PANES, 0)))
        self.runner.rules.append((("tmux", "send-keys"), ("", 0)))
        self.store.apply(evt("start"))
        self.assertTrue(self.store.send_prompt("s1", "  fix the tests  "))
        keys = self.runner.called("tmux", "send-keys")
        self.assertEqual(keys[0], ["tmux", "send-keys", "-t", "%3", "-l", "fix the tests"])
        self.assertEqual(keys[1], ["tmux", "send-keys", "-t", "%3", "Enter"])
        self.assertEqual(self.store.toast, "Sent to demo")

    def test_send_prompt_without_pane(self):
        self.runner.rules.append((("tmux", "list-panes"), ("", 0)))
        self.store.apply(evt("start"))
        self.assertFalse(self.store.send_prompt("s1", "hello"))
        self.assertEqual(self.store.toast, "No tmux session for demo")
        self.assertFalse(self.store.send_prompt("s1", "   "))
        self.assertFalse(self.store.send_prompt("nope", "hello"))

    def test_open_terminal_switches_attached_client(self):
        self.runner.rules.append((("tmux", "list-panes"), (self.PANES, 0)))
        self.runner.rules.append((("tmux", "list-clients"), ("/dev/pts/2\n", 0)))
        self.store.apply(evt("start"))
        self.assertTrue(self.store.open_terminal("s1"))
        self.assertEqual(self.runner.called("tmux", "switch-client"),
                         [["tmux", "switch-client", "-c", "/dev/pts/2", "-t", "%3"]])
        self.assertEqual(self.spawner.calls, [])

    def test_open_terminal_spawns_when_no_client(self):
        self.runner.rules.append((("tmux", "list-panes"), (self.PANES, 0)))
        self.runner.rules.append((("tmux", "list-clients"), ("", 0)))
        self.store.apply(evt("start"))
        self.assertTrue(self.store.open_terminal("s1"))
        self.assertEqual(self.spawner.calls,
                         [(["konsole", "-e", "tmux", "attach", "-t", "cc-demo"], "/home/u/demo")])

    def test_recap(self):
        self.store.apply(evt("start"))
        self.assertFalse(self.store.recap("s1"))
        self.assertEqual(self.store.toast, "Voice system not found")
        self.enable_voice()
        self.store.apply(evt("briefing", text="Shipped it.", duration=1))
        self.assertTrue(self.store.recap("s1"))
        args, _ = self.spawner.calls[0]
        self.assertEqual(args[1:], [os.path.join(self.speaker, "say.py"), "--sid", "s1", "Shipped it."])

    def test_mute_toggle(self):
        self.enable_voice()
        self.assertFalse(self.store.voice_muted())
        self.assertTrue(self.store.toggle_mute())
        self.assertTrue(os.path.exists(os.path.join(self.speaker, ".off")))
        stops = [c for c in self.runner.calls if c[-1] == "--stop"]
        self.assertEqual(len(stops), 1)
        self.assertFalse(self.store.toggle_mute())
        self.assertFalse(self.store.voice_muted())

    def test_launch_session_accept_edits(self):
        self.tmux_server()
        self.runner.rules.append((("tmux", "capture-pane"), ("│ > │\n? for shortcuts\n", 0)))
        self.runner.rules.append((("tmux", "send-keys"), ("", 0)))
        self.assertTrue(self.store.launch_session("  tidy the readme "))
        new = self.runner.called("tmux", "new-session")[0]
        self.assertEqual(new[:7], ["tmux", "new-session", "-d", "-s", "cc-work-pill", "-c", self.config.home_repo])
        self.assertEqual(new[7:], ["/x/claude", "--permission-mode", "acceptEdits"])
        keys = self.runner.called("tmux", "send-keys")
        self.assertEqual(keys[0], ["tmux", "send-keys", "-t", "cc-work-pill", "-l", "tidy the readme"])
        self.assertEqual(keys[1][-1], "Enter")
        self.assertIn("launched cc-work-pill ready=True sent=True", self.log_text())

    def test_launch_session_bypass_accepts_dialog_and_picks_free_name(self):
        self.config.permission_mode = "bypass"
        self.config.pill_system_prompt = "Be terse."
        self.tmux_server(taken={"cc-work-pill"})    # first name taken
        captures = iter(["Yes, I accept\n", "shift+tab to cycle\n"])
        self.runner.rules.append((("tmux", "capture-pane"), lambda: (next(captures), 0)))
        self.runner.rules.append((("tmux", "send-keys"), ("", 0)))
        self.assertTrue(self.store.launch_session("go"))
        new = self.runner.called("tmux", "new-session")[0]
        self.assertEqual(new[4], "cc-work-pill-2")
        self.assertEqual(new[7:], ["/x/claude", "--dangerously-skip-permissions",
                                   "--append-system-prompt", "Be terse."])
        keys = self.runner.called("tmux", "send-keys")
        self.assertEqual(keys[0][-1], "2")           # answered the acceptance dialog
        self.assertEqual(keys[2][-2:], ["-l", "go"])

    def test_launch_empty_prompt_dropped(self):
        self.assertFalse(self.store.launch_session("   "))
        self.assertEqual(self.runner.calls, [])


class HttpTest(Base):
    def setUp(self):
        super().setUp()
        self.httpd = ccpilld.serve(self.store, 0)
        self.port = self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        super().tearDown()

    def req(self, path, method="GET", body=None, headers=None, raw=None):
        h = {ccpilld.API_HEADER: "1"}
        if headers is not None:
            h = headers
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status, json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"null")

    def test_state(self):
        self.store.apply(evt("prompt"))
        code, obj = self.req("/state")
        self.assertEqual(code, 200)
        self.assertEqual(obj["pill"]["state"], "working")
        self.assertEqual(obj["sessions"][0]["repo"], "demo")

    def test_missing_header_rejected(self):
        code, obj = self.req("/state", headers={})
        self.assertEqual(code, 403)

    def test_origin_rejected_even_with_header(self):
        code, _ = self.req("/state", headers={ccpilld.API_HEADER: "1", "Origin": "http://evil.example"})
        self.assertEqual(code, 403)
        code, _ = self.req("/ask", method="POST", body={"text": "rm -rf"},
                           headers={ccpilld.API_HEADER: "1", "Origin": "null"})
        self.assertEqual(code, 403)
        self.assertEqual(self.runner.calls, [])

    def test_preflight_refused_without_cors_headers(self):
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}/ask", method="OPTIONS",
                                   headers={"Origin": "http://evil.example",
                                            "Access-Control-Request-Method": "POST"})
        try:
            urllib.request.urlopen(r, timeout=5)
            self.fail("expected 403")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 403)
            self.assertIsNone(e.headers.get("Access-Control-Allow-Origin"))

    def test_unknown_routes(self):
        self.assertEqual(self.req("/nope")[0], 404)
        self.assertEqual(self.req("/nope", method="POST", body={})[0], 404)

    def test_bad_bodies(self):
        self.assertEqual(self.req("/prompt", method="POST", raw=b"{oops")[0], 400)
        self.assertEqual(self.req("/prompt", method="POST", raw=b"[1]")[0], 400)
        self.assertEqual(self.req("/prompt", method="POST", raw=b"x" * (ccpilld.MAX_BODY + 1))[0], 400)

    def test_prompt_and_mute_routes(self):
        self.runner.rules.append((("tmux", "list-panes"), (ActionsTest.PANES, 0)))
        self.runner.rules.append((("tmux", "send-keys"), ("", 0)))
        self.store.apply(evt("start"))
        code, obj = self.req("/prompt", method="POST", body={"sid": "s1", "text": "hi"})
        self.assertEqual((code, obj["ok"]), (200, True))
        self.enable_voice()
        code, obj = self.req("/mute", method="POST", body={})
        self.assertEqual((code, obj["muted"]), (200, True))
        code, obj = self.req("/mute", method="POST")
        self.assertEqual(obj["muted"], False)
        code, obj = self.req("/stop", method="POST")
        self.assertEqual(obj["ok"], True)

    def test_place_route_runs_the_placer_detached(self):
        code, obj = self.req("/place", method="POST", body={"edge": "top", "align": "center"})
        self.assertEqual((code, obj["ok"]), (200, True))
        args, _ = self.spawner.calls[-1]
        self.assertTrue(args[1].endswith("linux/bin/cc-pill-place"))
        self.assertEqual(args[2:], ["--edge", "top", "--align", "center"])
        self.assertEqual(self.store.snapshot()["toast"], "Moving the widget…")
        self.assertEqual(self.req("/place", method="POST", body={"edge": "middle", "align": "end"})[1]["ok"], False)
        self.assertEqual(self.req("/place", method="POST", body={"edge": "top", "align": "sideways"})[1]["ok"], False)
        self.assertEqual(len(self.spawner.calls), 1)

    def test_ask_route_launches_in_background(self):
        done = threading.Event()
        self.tmux_server()
        self.runner.rules.append((("tmux", "capture-pane"), ("? for shortcuts", 0)))

        def sent():
            done.set()
            return "", 0
        self.runner.rules.append((("tmux", "send-keys"), sent))
        code, obj = self.req("/ask", method="POST", body={"text": "hello"})
        self.assertEqual((code, obj["ok"]), (200, True))
        self.assertTrue(done.wait(5))
        self.assertEqual(self.req("/ask", method="POST", body={"text": ""})[1]["ok"], False)


class PidAliveTest(unittest.TestCase):
    def test_self_alive_and_bogus_dead(self):
        self.assertTrue(ccpilld.pid_alive(os.getpid()))
        self.assertFalse(ccpilld.pid_alive(2 ** 22 - 7))


if __name__ == "__main__":
    unittest.main()
