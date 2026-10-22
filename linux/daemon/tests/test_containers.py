"""Claude Code sessions inside LXD containers: the daemon side (pid
translation, local-vs-remote, the bridge listener, card actions through
lxc exec), the hook's post, and cc-pill-containers' settings merge."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import ccpilld  # noqa: E402
from test_ccpilld import Base, evt  # noqa: E402

REPO = os.path.join(HERE, "..", "..", "..")


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


hook = load("hook_ct", os.path.join(REPO, "hooks", "hook.py"))
wire = load("cc_pill_containers", os.path.join(REPO, "linux", "bin", "cc-pill-containers"))


class ContainerBase(Base):
    def setUp(self):
        super().setUp()
        self.config.containers = {"web-dev": "tok-web", "dev2": "tok-dev2"}
        self.config.lxc_bin = "/usr/bin/lxc"
        self.pidmap = {("web-dev", 3535): 11875}
        self.lookups = []

        def host_pid(container, pid):
            self.lookups.append((container, pid))
            return self.pidmap.get((container, pid), 0)

        self.store.host_pid = host_pid
        self.store._local_addrs = {"192.0.2.1", "2001:db8::1", "127.0.0.1"}


class ApplyContainerTest(ContainerBase):
    def test_session_carries_container_and_host_pid(self):
        self.store.apply_container("web-dev", evt("prompt", pid=3535, cwd="/root/w/api", repo="api"))
        s = self.store.sessions[0]
        self.assertEqual((s.container, s.pid, s.state, s.remote), ("web-dev", 11875, "working", False))
        self.assertEqual(self.store.snapshot()["sessions"][0]["container"], "web-dev")

    def test_pid_lookup_is_cached_while_alive(self):
        for typ in ("start", "prompt", "stop"):
            self.store.apply_container("web-dev", evt(typ, pid=3535))
        self.assertEqual(self.lookups, [("web-dev", 3535)])

    def test_dead_cached_pid_is_looked_up_again(self):
        self.store.apply_container("web-dev", evt("start", pid=3535))
        self.dead.add(11875)
        self.pidmap[("web-dev", 3535)] = 22000
        self.store.apply_container("web-dev", evt("prompt", pid=3535))
        self.assertEqual(self.store.sessions[0].pid, 22000)

    def test_unresolved_pid_is_never_reaped(self):
        # The container's pid number means nothing on the host: never use it raw.
        self.store.apply_container("web-dev", evt("start", pid=999))
        self.assertEqual(self.store.sessions[0].pid, 0)
        self.dead.add(999)
        self.clock.advance(ccpilld.REAP_INTERVAL + 1)
        self.store.tick()
        self.assertEqual(len(self.store.sessions), 1)

    def test_reaped_when_the_host_process_dies(self):
        self.store.apply_container("web-dev", evt("start", pid=3535))
        self.dead.add(11875)
        self.clock.advance(ccpilld.REAP_INTERVAL + 1)
        self.store.tick()
        self.assertEqual(self.store.sessions, [])

    def test_ssh_from_the_host_is_local(self):
        self.store.apply_container("web-dev", evt("start", ssh_client="2001:db8::1", remote=True))
        self.assertFalse(self.store.sessions[0].remote)

    def test_ssh_from_elsewhere_is_remote(self):
        self.store.apply_container("web-dev", evt("start", ssh_client="100.64.1.9"))
        self.assertTrue(self.store.sessions[0].remote)

    def test_unclaimed_spare_processes_never_become_sessions(self):
        spare = "/tmp/cc-daemon-0/addcfb49/spare"
        self.store.apply_container("web-dev", evt("start", sid="sp", cwd=spare, repo="spare"))
        self.store.apply(evt("start", sid="sp2", cwd=spare + "/x", repo="x"))
        self.assertEqual(self.store.sessions, [])
        # once claimed, the same process works in its project like any session
        self.store.apply_container("web-dev", evt("prompt", sid="sp", cwd="/root/workspace/todo-app", repo="todo-app"))
        self.assertEqual([s.repo for s in self.store.sessions], ["todo-app"])

    def test_host_addresses_parses_ip_addr(self):
        out = ("1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever\n"
               "5: lxdbr0    inet6 2001:db8::1/64 scope global\\       valid_lft forever\n")
        self.assertEqual(ccpilld.host_addresses(lambda args: (out, 0)),
                         {"127.0.0.1", "2001:db8::1"})


class ContainerActionsTest(ContainerBase):
    def setUp(self):
        super().setUp()
        self.store.apply_container("web-dev", evt("start", sid="c1", pid=3535, cwd="/root/w/api", repo="api"))
        self.lxc_tmux = ["/usr/bin/lxc", "exec", "web-dev", "--", "tmux"]

    def test_a_non_root_user_gets_lxc_exec_user(self):
        self.config.container_users = {"web-dev": 1000}
        self.assertEqual(self.store.in_container("web-dev", ["tmux", "ls"]),
                         ["/usr/bin/lxc", "exec", "web-dev", "--user", "1000", "--", "tmux", "ls"])
        self.assertEqual(self.store.in_container("dev2", ["tmux", "ls"])[:4],
                         ["/usr/bin/lxc", "exec", "dev2", "--"])

    def test_send_prompt_goes_through_lxc_exec(self):
        self.runner.rules = [(self.lxc_tmux + ["list-panes"], ("%3\t0\t/root/w/api\t50\n", 0)),
                             (self.lxc_tmux + ["send-keys"], ("", 0))]
        self.assertTrue(self.store.send_prompt("c1", "run the tests"))
        self.assertEqual(self.runner.called(*self.lxc_tmux, "send-keys")[0][-3:], ["%3", "-l", "run the tests"])
        self.assertEqual(self.runner.called("tmux"), [])

    def test_open_terminal_switches_the_containers_client(self):
        self.runner.rules = [(self.lxc_tmux + ["list-panes"], ("%3\t0\t/root/w/api\t50\n", 0)),
                             (self.lxc_tmux + ["list-clients"], ("/dev/pts/1\n", 0))]
        self.assertTrue(self.store.open_terminal("c1"))
        self.assertEqual(self.runner.called(*self.lxc_tmux, "switch-client")[0][-4:],
                         ["-c", "/dev/pts/1", "-t", "%3"])

    def test_open_terminal_attaches_when_nobody_is_attached(self):
        self.runner.rules = [(self.lxc_tmux + ["list-panes"], ("%3\twork\t/root/w/api\t50\n", 0))]
        self.assertTrue(self.store.open_terminal("c1"))
        args, cwd = self.spawner.calls[0]
        self.assertEqual(args, ["konsole", "-e", "/usr/bin/lxc", "exec", "web-dev", "--env", "TERM=xterm-256color",
                                "--", "tmux", "attach", "-t", "work"])
        self.assertIsNone(cwd)   # /root/w/api is a container path

    def test_open_terminal_without_tmux_opens_a_shell_inside(self):
        self.assertTrue(self.store.open_terminal("c1"))
        self.assertEqual(self.spawner.calls[0][0],
                         ["konsole", "-e", "/usr/bin/lxc", "exec", "web-dev", "--env", "TERM=xterm-256color",
                          "--", "bash", "-l"])

    def test_ghostty_takes_the_command_after_dash_e(self):
        self.config.terminal = "ghostty"
        self.runner.rules = [(self.lxc_tmux + ["list-panes"], ("%3\twork\t/root/w/api\t50\n", 0))]
        self.assertTrue(self.store.open_terminal("c1"))
        self.assertEqual(self.spawner.calls[0][0][:3], ["ghostty", "-e", "/usr/bin/lxc"])

    # A container with four panes in /root/workspace/todo-app, and
    # sessions that share it or moved into a subdirectory.
    WEB_PANES = ("%0\t0\t/root/workspace/todo-app\t3472\n%5\t0\t/root/workspace/todo-app\t9000\n"
                  "%2\t0\t/root/workspace/todo-app\t3769\n%4\t0\t/root/workspace/todo-app\t9965\n")

    def web(self):
        self.runner.rules = [(self.lxc_tmux + ["list-panes"], (self.WEB_PANES, 0)),
                             (self.lxc_tmux + ["send-keys"], ("", 0))]
        # host pid -> its ancestors as the container sees them (pane_pid among them)
        self.tree.update({11875: {3535, 3472, 1}, 18935: {10308, 9965, 1}, 12154: {3801, 3769, 1}})
        self.pidmap.update({("web-dev", 3535): 11875, ("web-dev", 10308): 18935, ("web-dev", 3801): 12154})
        for sid, nspid, cwd in (("first", 3535, "/root/workspace/todo-app"),
                                ("second", 10308, "/root/workspace/todo-app"),
                                ("moved", 3801, "/root/workspace/todo-app/.scratch")):
            self.store.apply_container("web-dev", evt("start", sid=sid, pid=nspid, cwd=cwd, repo="todo-app"))

    def target_of_prompt(self, sid):
        self.runner.calls.clear()
        self.assertTrue(self.store.send_prompt(sid, "hi"))
        return self.runner.called(*self.lxc_tmux, "send-keys")[0][7]

    def test_prompts_reach_the_session_that_shares_a_directory(self):
        self.web()
        self.assertEqual(self.target_of_prompt("first"), "%0")
        self.assertEqual(self.target_of_prompt("second"), "%4")   # by directory it went to %0

    def test_prompts_reach_a_session_that_moved_into_a_subdirectory(self):
        self.web()
        self.assertEqual(self.target_of_prompt("moved"), "%2")    # by directory: no pane at all

    def test_directory_is_the_fallback_without_a_pid(self):
        self.web()
        self.store.apply_container("web-dev", evt("start", sid="nopid", pid=0, cwd="/root/workspace/todo-app"))
        self.assertEqual(self.target_of_prompt("nopid"), "%0")

    def test_container_sessions_are_never_gc_candidates(self):
        self.config.pill_gc_minutes = 1
        self.clock.advance(120)
        self.store._gc_pill_sessions(self.clock())
        self.assertEqual(self.runner.calls, [])


class BridgeHttpTest(ContainerBase):
    def setUp(self):
        super().setUp()
        self.httpd = ccpilld.serve(self.store, 0, bridge=True)
        self.port = self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        super().tearDown()

    def post(self, path, body, token="tok-web", extra=None):
        h = {ccpilld.API_HEADER: "1", ccpilld.TOKEN_HEADER: token}
        h.update(extra or {})
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method="POST",
                                   data=json.dumps(body).encode(), headers=h)
        try:
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status
        except urllib.error.HTTPError as e:
            e.close()
            return e.code

    def test_event_with_its_token_is_applied(self):
        code = self.post("/event", {"container": "web-dev", "event": evt("prompt", pid=3535)})
        self.assertEqual(code, 200)
        self.assertEqual(self.store.sessions[0].container, "web-dev")

    def test_another_containers_token_is_refused(self):
        code = self.post("/event", {"container": "web-dev", "event": evt("prompt")}, token="tok-dev2")
        self.assertEqual(code, 403)
        self.assertEqual(self.store.sessions, [])

    def test_unknown_container_is_refused(self):
        self.assertEqual(self.post("/event", {"container": "evil", "event": evt("prompt")}, token=""), 403)

    def test_only_event_is_served(self):
        for path in ("/ask", "/prompt", "/terminal", "/mute", "/stop", "/place"):
            self.assertEqual(self.post(path, {"text": "x", "sid": "s1"}), 404, path)
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}/state", headers={ccpilld.API_HEADER: "1"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(r, timeout=5)
        self.assertEqual(cm.exception.code, 404)
        cm.exception.close()
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(self.spawner.calls, [])

    def test_origin_still_refused(self):
        code = self.post("/event", {"container": "web-dev", "event": evt("prompt")},
                         extra={"Origin": "http://x"})
        self.assertEqual(code, 403)


class RestoreTest(ContainerBase):
    def save(self, sessions):
        path = os.path.join(self.tmp, "saved-state.json")
        with open(path, "w") as f:
            json.dump({"sessions": sessions}, f)
        return path

    def test_running_sessions_come_back_after_a_restart(self):
        self.store.apply_container("web-dev", evt("prompt", sid="c1", pid=3535, cwd="/root/w/api", repo="api"))
        self.store.apply(evt("briefing", sid="c1", text="Shipped.", duration=1))
        path = self.save(self.store.snapshot()["sessions"])
        fresh = ccpilld.Store(self.config, clock=self.clock, runner=self.runner, spawner=self.spawner,
                              alive=lambda pid: pid not in self.dead)
        self.assertEqual(fresh.restore(path), 1)
        s = fresh.sessions[0]
        self.assertEqual((s.id, s.container, s.pid, s.state, s.cwd, s.last_briefing),
                         ("c1", "web-dev", 11875, "working", "/root/w/api", "Shipped."))

    def test_dead_unknown_and_duplicate_sessions_stay_out(self):
        self.dead.add(500)
        path = self.save([{"id": "dead", "pid": 500}, {"id": "nopid", "pid": 0},
                          {"id": "keep", "pid": 600, "state": "bogus"}, {"id": "keep", "pid": 600},
                          "junk", {"pid": 700}])
        self.assertEqual(self.store.restore(path), 1)
        self.assertEqual([(s.id, s.state) for s in self.store.sessions], [("keep", "done")])

    def test_missing_or_broken_state_is_harmless(self):
        self.assertEqual(self.store.restore(os.path.join(self.tmp, "nope.json")), 0)
        bad = os.path.join(self.tmp, "bad.json")
        with open(bad, "w") as f:
            f.write("{not json")
        self.assertEqual(self.store.restore(bad), 0)


class AncestorPidsTest(unittest.TestCase):
    def test_walks_up_in_the_containers_own_numbering(self):
        proc = tempfile.mkdtemp()
        try:
            for pid, ns, ppid in ((11875, "11875\t3535", 11800), (11800, "11800\t3472", 1500), (1500, "1500\t1", 1)):
                os.makedirs(os.path.join(proc, str(pid)))
                with open(os.path.join(proc, str(pid), "status"), "w") as f:
                    f.write(f"Name:\tclaude\nPPid:\t{ppid}\nNSpid:\t{ns}\n")
            self.assertEqual(ccpilld.ancestor_pids(11875, proc, depth=1), {3535, 3472, 1})
            self.assertEqual(ccpilld.ancestor_pids(11875, proc), {11875, 11800, 1500})   # host view
            self.assertEqual(ccpilld.ancestor_pids(424242, proc), set())
        finally:
            shutil.rmtree(proc)

    def test_a_sandbox_inside_the_container_is_not_mistaken_for_the_session(self):
        # host 11875 is the session (container pid 3535); host 12000 is a
        # process in a bwrap sandbox whose innermost pid is also 3535
        proc = tempfile.mkdtemp()
        try:
            for pid, ns in ((12000, "12000\t4100\t3535"), (11875, "11875\t3535")):
                os.makedirs(os.path.join(proc, str(pid)))
                with open(os.path.join(proc, str(pid), "status"), "w") as f:
                    f.write(f"Name:\tx\nNSpid:\t{ns}\n")
                with open(os.path.join(proc, str(pid), "cgroup"), "w") as f:
                    f.write("0::/lxc.payload.web-dev/user.slice\n")
            self.assertEqual(ccpilld.container_host_pid("web-dev", 3535, proc), 11875)
        finally:
            shutil.rmtree(proc)

    def test_real_proc_includes_this_process(self):
        self.assertIn(os.getpid(), ccpilld.ancestor_pids(os.getpid()))


class ContainerHostPidTest(unittest.TestCase):
    def setUp(self):
        self.proc = tempfile.mkdtemp(prefix="ccpill-proc-")

    def tearDown(self):
        shutil.rmtree(self.proc, ignore_errors=True)

    def add(self, pid, nspids, cgroup):
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d)
        with open(os.path.join(d, "status"), "w") as f:
            f.write(f"Name:\tclaude\nNSpid:\t{nspids}\n")
        with open(os.path.join(d, "cgroup"), "w") as f:
            f.write(cgroup + "\n")

    def test_finds_the_host_pid_in_the_right_container(self):
        self.add(11875, "11875\t3535", "0::/lxc.payload.web-dev/user.slice/tmux-spawn-1")
        self.add(12000, "12000\t3535", "0::/lxc.payload.web-dev2/user.slice")
        self.add(3535, "3535", "0::/user.slice/user-1000.slice")
        self.assertEqual(ccpilld.container_host_pid("web-dev", 3535, self.proc), 11875)
        self.assertEqual(ccpilld.container_host_pid("web-dev2", 3535, self.proc), 12000)
        self.assertEqual(ccpilld.container_host_pid("other", 3535, self.proc), 0)

    def test_container_init_cgroup_without_trailing_path(self):
        self.add(500, "500\t1", "0::/lxc.payload.web-dev")
        self.assertEqual(ccpilld.container_host_pid("web-dev", 1, self.proc), 500)


class HookPostTest(unittest.TestCase):
    """The hook's bare-socket POST, against a real local listener."""

    def serve(self, reply=b"HTTP/1.0 200 OK\r\n\r\n{}"):
        import socket
        import threading
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        got = {}

        def run():
            c, _ = srv.accept()
            data = b""
            while b"\r\n\r\n" not in data:
                data += c.recv(4096)
            head, body = data.split(b"\r\n\r\n", 1)
            n = int([l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
            while len(body) < n:
                body += c.recv(4096)
            got["head"], got["body"] = head.decode(), json.loads(body)
            c.sendall(reply)
            c.close()
            srv.close()
        t = threading.Thread(target=run, daemon=True)
        t.start()
        return srv.getsockname()[1], got, t

    def test_posts_event_with_token_and_ssh_client(self):
        port, got, t = self.serve()
        remote = {"url": f"http://127.0.0.1:{port}", "container": "web-dev", "token": "t0k"}
        with mock.patch.dict(os.environ, {"SSH_CONNECTION": "fd42::1 48658 fd42::2 22"}):
            hook.post_to_host({"type": "start", "sid": "s"}, remote)
        t.join(2)
        lines = got["head"].split("\r\n")
        self.assertEqual(lines[0], "POST /event HTTP/1.0")
        self.assertIn("X-CC-Pill: 1", lines)
        self.assertIn("X-CC-Pill-Token: t0k", lines)
        self.assertEqual(got["body"], {"container": "web-dev",
                                       "event": {"type": "start", "sid": "s", "ssh_client": "fd42::1"}})

    def test_the_real_daemon_accepts_it(self):
        # end to end with the daemon's own bridge handler (logging to a scratch dir)
        tmp = tempfile.mkdtemp()
        orig_log = ccpilld.LOG_PATH
        ccpilld.LOG_PATH = os.path.join(tmp, "pill.log")
        try:
            store = ccpilld.Store(ccpilld.Config({"containers": {"web-dev": "t0k"},
                                                  "speaker": os.path.join(tmp, "v")}),
                                  host_pid=lambda c, p: 0, local_addrs=set())
            httpd = ccpilld.serve(store, 0, bridge=True)
            try:
                remote = {"url": f"http://127.0.0.1:{httpd.server_address[1]}", "container": "web-dev", "token": "t0k"}
                hook.post_to_host({"type": "start", "sid": "s9", "cwd": "/root/x", "repo": "x", "pid": 0}, remote)
                self.assertEqual([s.id for s in store.sessions], ["s9"])
            finally:
                httpd.shutdown()
                httpd.server_close()
        finally:
            ccpilld.LOG_PATH = orig_log
            shutil.rmtree(tmp)

    def test_a_down_daemon_is_silent_and_quick(self):
        import socket
        import time
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()   # nothing listens there
        t = time.time()
        hook.post_to_host({"type": "start"}, {"url": f"http://127.0.0.1:{port}", "token": ""})
        hook.post_to_host({"type": "start"}, {"url": "garbage", "token": ""})
        self.assertLess(time.time() - t, 0.5)


class MergeHooksTest(unittest.TestCase):
    def cmd(self, mode):
        return f'python3 "/root/.cc-pill/hook.py" {mode}'

    def test_keeps_existing_hooks_and_appends_ours(self):
        mine = {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "ruby guard.rb"}]}
        settings = {"model": "opus", "hooks": {"PreToolUse": [mine]}}
        out = wire.merge_hooks(settings, self.cmd)
        self.assertEqual(out["model"], "opus")
        self.assertEqual(out["hooks"]["PreToolUse"][0], mine)
        self.assertEqual(out["hooks"]["PreToolUse"][1]["hooks"][0]["command"], self.cmd("tool"))
        self.assertEqual(set(out["hooks"]), set(wire.EVENTS))

    def test_rerun_does_not_duplicate(self):
        once = wire.merge_hooks({}, self.cmd)
        twice = wire.merge_hooks(json.loads(json.dumps(once)), self.cmd)
        self.assertEqual(once, twice)

    def test_strip_removes_only_ours(self):
        mixed = {"hooks": [{"type": "command", "command": "bash audit.sh"},
                           {"type": "command", "command": self.cmd("stop")}]}
        settings = {"hooks": {"Stop": [mixed], "SessionEnd": [{"hooks": [{"command": self.cmd("end")}]}]}}
        out = wire.strip_hooks(settings)
        self.assertEqual(out["hooks"], {"Stop": [{"hooks": [{"type": "command", "command": "bash audit.sh"}]}]})


if __name__ == "__main__":
    unittest.main()
