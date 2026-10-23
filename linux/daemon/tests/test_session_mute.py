"""Muting one session: the flag in the state, the daemon's handoff for
container sessions, the localhost route, and the voice worker for host
sessions. No audio."""
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import ccpilld  # noqa: E402
from test_briefings import HandoffBase  # noqa: E402
from test_ccpilld import Base, evt  # noqa: E402
from test_containers import REPO, ContainerBase, load  # noqa: E402

worker = load("worker_mute", os.path.join(REPO, "voice", "worker.py"))


class MuteFlagTest(Base):
    def test_flag_in_snapshot(self):
        self.store.apply(evt("prompt"))
        self.assertFalse(self.store.snapshot()["sessions"][0]["muted"])
        self.assertTrue(self.store.mute_session("s1", True))
        self.assertTrue(self.store.snapshot()["sessions"][0]["muted"])
        self.assertTrue(self.store.mute_session("s1", False))
        self.assertFalse(self.store.snapshot()["sessions"][0]["muted"])

    def test_unknown_session(self):
        self.assertFalse(self.store.mute_session("nope", True))
        self.assertEqual(self.store.muted, set())


class MutedHandoffTest(HandoffBase):
    def test_no_job_for_a_muted_session(self):
        self.store.apply_container("web-dev", evt("prompt", sid="c1", pid=3535))
        self.store.mute_session("c1", True)
        self.store.apply_container("web-dev", evt("stop", sid="c1", pid=3535, speech={"text": "Done."}))
        self.assert_no_job()

    def test_other_sessions_still_speak(self):
        self.store.apply_container("web-dev", evt("prompt", sid="c1", pid=3535))
        self.store.mute_session("c1", True)
        self.store.apply_container("web-dev", evt("stop", sid="c2", pid=3535, speech={"text": "Done."}))
        self.assertEqual(len(self.jobs()), 1)


class RouteMixin:
    def req(self, body):
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}/session/mute", method="POST",
                                   data=json.dumps(body).encode(),
                                   headers={ccpilld.API_HEADER: "1", ccpilld.TOKEN_HEADER: "tok-web"})
        try:
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            e.close()
            return e.code, None


class LocalRouteTest(RouteMixin, ContainerBase):
    def setUp(self):
        super().setUp()
        self.httpd = ccpilld.serve(self.store, 0)
        self.port = self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        super().tearDown()

    def test_mute_and_unmute(self):
        self.store.apply(evt("prompt"))
        self.assertEqual(self.req({"sid": "s1", "on": True}), (200, {"ok": True}))
        self.assertEqual(self.store.muted, {"s1"})
        self.assertEqual(self.req({"sid": "s1", "on": False}), (200, {"ok": True}))
        self.assertEqual(self.store.muted, set())
        self.assertEqual(self.req({"sid": "nope", "on": True}), (200, {"ok": False}))


class BridgeRouteTest(RouteMixin, ContainerBase):
    def setUp(self):
        super().setUp()
        self.httpd = ccpilld.serve(self.store, 0, bridge=True)
        self.port = self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        super().tearDown()

    def test_not_served_on_the_bridge(self):
        self.store.apply(evt("prompt"))
        self.assertEqual(self.req({"sid": "s1", "on": True})[0], 404)
        self.assertEqual(self.store.muted, set())


class WorkerMuteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state.json")
        self.spoken = []
        self.patches = [
            mock.patch.object(worker, "STATE", self.state),
            mock.patch.object(worker, "STOP_STAMP", os.path.join(self.tmp, "last-stop")),
            mock.patch.object(worker, "load_config", lambda: {"enabled": True, "briefing_max_words": 25}),
            mock.patch.object(worker, "last_spoke", lambda: {"t": 0, "sid": ""}),
            mock.patch.object(worker, "summarize", lambda *a, **k: "All tests pass."),
            mock.patch.object(worker, "session_on_screen", lambda *a: False),
            mock.patch.object(worker, "speak", lambda line, cfg, meta=None, **k: self.spoken.append(line)),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        shutil.rmtree(self.tmp)

    def run_job(self, sid):
        job = os.path.join(self.tmp, "job-1.json")
        with open(job, "w") as f:
            json.dump({"pill_mode": "stop", "session_id": sid, "cwd": "/home/u/demo",
                       "last_assistant_message": "Done. All tests pass."}, f)
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["worker.py", job]), redirect_stdout(out):
            worker.main()
        return out.getvalue()

    def write_state(self, sessions):
        with open(self.state, "w") as f:
            json.dump({"sessions": sessions}, f)

    def test_muted_session_stays_quiet(self):
        self.write_state([{"id": "s1", "muted": True}])
        out = self.run_job("s1")
        self.assertIn("(muted session, stayed quiet)", out)
        self.assertEqual(self.spoken, [])

    def test_other_session_speaks(self):
        self.write_state([{"id": "s1", "muted": True}, {"id": "s2", "muted": False}])
        self.run_job("s2")
        self.assertEqual(len(self.spoken), 1)

    def test_unreadable_state_speaks(self):
        with open(self.state, "w") as f:
            f.write("{oops")
        self.run_job("s1")
        self.assertEqual(len(self.spoken), 1)
        os.remove(self.state)
        self.run_job("s1")
        self.assertEqual(len(self.spoken), 2)


if __name__ == "__main__":
    unittest.main()
