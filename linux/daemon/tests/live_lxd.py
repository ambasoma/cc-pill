#!/usr/bin/env python3
"""Live check of the LXD path on this machine, without installing anything.

    python3 linux/daemon/tests/live_lxd.py [-v] [--containers a,b] [--watch 60]

Not part of the unit suite (it needs LXD, running containers and a Plasma
session). Everything it creates is temporary and removed at the end, and the
last test proves it: checksums of every real file the install would touch
(the host's and each container's Claude settings, ~/.cc-pill, the systemd
units, the widget, kglobalshortcutsrc) are taken first and compared last.

What it exercises, all for real:
  * ccpilld from this checkout, as a transient systemd user unit (the same
    environment the installed service gets), on a spare port, with a
    scratch data dir, listening on the LXD bridge
  * cc-pill-containers wiring a scratch home inside each container: the hook
    pushed, remote.json written, a copy of that container's real
    settings.json merged (every existing hook must survive)
  * the merged hook commands, run exactly as Claude Code runs them (/bin/sh -c,
    payload on stdin) under a long-lived parent standing in for claude:
    sessions appear with the container's name, the host pid of that parent,
    narration from tool events, and are reaped when the parent dies
  * the SSH_CONNECTION of your running container sessions names this host,
    so they count as local (read-only); with --ssh, a real
    `ssh root@<container>.lxd` too (it may ask your ssh agent for a PIN/touch)
  * the bridge refuses bad tokens and serves nothing but POST /event
  * a card prompt delivered through `lxc exec ... tmux send-keys` into a
    throwaway tmux session, and the open-terminal command line
  * the widget (this checkout) loaded by plasmawindowed offscreen against
    the scratch daemon, card expanded: no QML errors, container shown
  * read-only: the parent chain of hook processes your running sessions
    spawn (Claude Code 2.1.x has helper processes; the hook must resolve to
    the session process), if any session runs a hook during --watch seconds
"""
import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
LXC = shutil.which("lxc") or "/snap/bin/lxc"
PORT = 17391
TAG = "ccpill-itest-" + secrets.token_hex(3)
CT_DIR = "/tmp/ccpill-itest"          # inside each container
CT_HOME = CT_DIR + "/home"
OPTS = argparse.Namespace(containers=None, watch=45.0, ssh=False)


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


wire = load("cc_pill_containers", os.path.join(REPO, "linux", "bin", "cc-pill-containers"))


def sh(container, script, input=None, check=True, timeout=30):
    p = subprocess.run([LXC, "exec", container, "--", "sh", "-c", script], input=input,
                       capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise AssertionError(f"{container}: {script[:60]}: {p.stderr.strip()}")
    return p.stdout


def wait_for(fn, timeout=10.0, every=0.2):
    end = time.time() + timeout
    while True:
        v = fn()
        if v or time.time() >= end:
            return v
        time.sleep(every)


def api(path, method="GET", body=None, host="127.0.0.1", headers=None):
    h = {"X-CC-Pill": "1"}
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"http://{host}:{PORT}{path}", data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        finally:
            e.close()


def sessions():
    code, st = api("/state")
    return st["sessions"] if code == 200 else []


def session(sid):
    return next((s for s in sessions() if s["id"] == sid), None)


def claude_containers():
    out = subprocess.run([LXC, "list", "--format", "csv", "-c", "ns"], capture_output=True, text=True).stdout
    names = [l.split(",")[0] for l in out.splitlines() if l.endswith(",RUNNING")]
    return [c for c in names
            if subprocess.run([LXC, "exec", c, "--", "test", "-d", "/root/.claude"]).returncode == 0]


# ------------------------------------------------------------- footprint

def fingerprint(containers):
    """Hash (or note the absence of) everything an install would change."""
    def digest(path):
        if os.path.isdir(path):
            return "dir:" + ",".join(sorted(os.listdir(path)))
        try:
            with open(path, "rb") as f:
                return hashlib.sha256(f.read()).hexdigest()
        except OSError:
            return "absent"
    home = os.path.expanduser("~")
    fp = {p: digest(os.path.join(home, p)) for p in (
        ".claude/settings.json", ".cc-pill", ".config/systemd/user/cc-pill.service",
        ".local/share/plasma/plasmoids/com.ccpill.pill", ".local/share/applications/cc-pill-ask.desktop",
        ".config/kglobalshortcutsrc", ".config/plasmawindowedrc", ".ssh/known_hosts")}
    units = subprocess.run(["systemctl", "--user", "list-units", "--all", "--plain", "--no-legend", "ccpill*", "cc-pill*"],
                           capture_output=True, text=True).stdout
    fp["systemd units"] = units.strip()
    for c in containers:
        fp[f"{c}:settings.json"] = sh(c, "sha256sum /root/.claude/settings.json 2>/dev/null || echo absent").split()[0]
        fp[f"{c}:/root/.cc-pill"] = sh(c, "test -e /root/.cc-pill && echo present || echo absent").strip()
        fp[f"{c}:{CT_DIR}"] = sh(c, f"test -e {CT_DIR} && echo present || echo absent").strip()
        fp[f"{c}:tmux {TAG}"] = sh(c, f"tmux has-session -t ={TAG} 2>/dev/null && echo present || echo absent").strip()
    return fp


# ------------------------------------------------------------- the rig

FAKE_CLAUDE = r'''
import json, os, subprocess, sys, time
# Stands in for a claude process: lives until killed, and runs hook commands
# the test drops into its job dir the way Claude Code does (/bin/sh -c, with
# the hook payload on stdin). argv carries the test tag so the host can
# identify this process independently of the daemon.
tag, jobs = sys.argv[1], sys.argv[2]
open(os.path.join(jobs, "pid"), "w").write(str(os.getpid()))
env = dict(os.environ, HOME=sys.argv[3])
for k in [k for k in env if k.startswith("SSH_")]:
    del env[k]
while True:
    for n in sorted(os.listdir(jobs)):
        if not n.startswith("job-"):
            continue
        p = os.path.join(jobs, n)
        job = json.load(open(p))
        os.remove(p)
        subprocess.run(["/bin/sh", "-c", job["cmd"]], input=json.dumps(job["payload"]).encode(), env=env)
    time.sleep(0.05)
'''


class Rig:
    scratch = None
    unit = None
    containers = []
    config = {}
    before = None
    commands = {}      # container -> {mode: hook command} read back from the merged settings

    @classmethod
    def up(cls):
        cls.containers = OPTS.containers or claude_containers()
        if not cls.containers:
            raise unittest.SkipTest("no running containers with /root/.claude")
        cls.before = fingerprint(cls.containers)
        cls.scratch = tempfile.mkdtemp(prefix="ccpill-itest-")
        data = os.path.join(cls.scratch, "data")
        os.makedirs(data)
        cls.term_log = os.path.join(cls.scratch, "terminal.log")
        term = os.path.join(cls.scratch, "fake-term")
        with open(term, "w") as f:
            f.write(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{cls.term_log}"\n')
        os.chmod(term, 0o755)
        # A stand-in voice: its "python" only records the jobs it is handed.
        cls.voice = os.path.join(cls.scratch, "voice")
        cls.voice_jobs = os.path.join(cls.scratch, "voice-jobs")
        os.makedirs(os.path.join(cls.voice, ".venv", "bin"))
        os.makedirs(cls.voice_jobs)
        fake_py = os.path.join(cls.voice, ".venv", "bin", "python")
        with open(fake_py, "w") as f:
            f.write(f'#!/bin/sh\n# $1 = worker.py, $2 = the job\ncp "$2" "{cls.voice_jobs}/"\necho "$1" > "{cls.voice_jobs}/.worker"\n')
        os.chmod(fake_py, 0o755)
        with open(os.path.join(data, "config.json"), "w") as f:
            json.dump({"daemon_port": PORT, "terminal": term, "name": "Itest",
                       "speaker": cls.voice}, f)
        cls.data = data

        # Wire a scratch home in every container, into the scratch config.
        env = dict(os.environ, CC_PILL_HOME=data)
        for c in cls.containers:
            sh(c, f"rm -rf {CT_DIR}; mkdir -p {CT_HOME}/.claude {CT_DIR}/jobs {CT_DIR}/proj")
            sh(c, f"cp -p /root/.claude/settings.json {CT_HOME}/.claude/settings.json 2>/dev/null || true")
        p = subprocess.run([sys.executable, os.path.join(REPO, "linux", "bin", "cc-pill-containers"), "add",
                            *cls.containers, "--home", CT_HOME, "--no-restart"],
                           env=env, capture_output=True, text=True)
        if p.returncode != 0:
            raise AssertionError("cc-pill-containers add failed: " + p.stdout + p.stderr)
        with open(os.path.join(data, "config.json")) as f:
            cls.config = json.load(f)

        # The daemon, as a transient user unit: the installed service's environment.
        cls.unit = TAG
        subprocess.run(["systemd-run", "--user", "--quiet", "--collect", f"--unit={cls.unit}",
                        f"--setenv=CC_PILL_HOME={data}", "--setenv=PYTHONUNBUFFERED=1",
                        "/usr/bin/env", "python3", os.path.join(REPO, "linux", "daemon", "ccpilld.py")],
                       check=True)
        log = os.path.join(data, "pill.log")
        def bound():
            try:
                with open(log) as f:
                    return "listening for containers" in f.read()
            except OSError:
                return False
        ok = wait_for(bound, 15)
        if not ok:
            raise AssertionError("daemon never bound the bridge:\n" + (open(log).read() if os.path.exists(log) else ""))

        # A stand-in claude in each container.
        for c in cls.containers:
            settings = json.loads(sh(c, f"cat {CT_HOME}/.claude/settings.json"))
            cls.commands[c] = {}
            for event, mode in wire.EVENTS.items():
                for g in settings["hooks"][event]:
                    for h in g["hooks"]:
                        if wire.MARK in h["command"]:
                            cls.commands[c][mode] = h["command"]
            sh(c, f"cat > {CT_DIR}/fake_claude.py", input=FAKE_CLAUDE)
            sh(c, f"setsid python3 {CT_DIR}/fake_claude.py {TAG} {CT_DIR}/jobs {CT_HOME} "
                  f"</dev/null >/dev/null 2>&1 &")

    @classmethod
    def down(cls):
        if cls.unit:
            subprocess.run(["systemctl", "--user", "stop", cls.unit], capture_output=True)
        for c in cls.containers:
            sh(c, f"pkill -f '[f]ake_claude.py {TAG}' ; tmux kill-session -t ={TAG} 2>/dev/null; rm -rf {CT_DIR}",
               check=False)
        if cls.scratch:
            shutil.rmtree(cls.scratch, ignore_errors=True)

    @classmethod
    def fire(cls, container, mode, sid, cwd=CT_DIR + "/proj", jobs=CT_DIR + "/jobs", **payload):
        """Run the merged hook command for `mode` under the stand-in claude
        that watches `jobs`."""
        payload = dict(payload, session_id=sid, cwd=cwd, hook_event_name=mode)
        job = {"cmd": cls.commands[container][mode], "payload": payload}
        sh(container, f"cat > {jobs}/.tmp && mv {jobs}/.tmp {jobs}/job-{time.time_ns()}",
           input=json.dumps(job))

    @classmethod
    def fake_pid(cls, container):
        return int(wait_for(lambda: sh(container, f"cat {CT_DIR}/jobs/pid 2>/dev/null || true").strip(), 5))


def host_pid_by_tag(container, nspid):
    """Independent of the daemon: the host process whose argv carries our
    tag and whose innermost pid is the stand-in's."""
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open(f"/proc/{p}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
            with open(f"/proc/{p}/status") as f:
                ns = next(l.split()[1:] for l in f if l.startswith("NSpid:"))
        except (OSError, StopIteration):
            continue
        if TAG.encode() in argv and ns[-1] == str(nspid):
            return int(p)
    return 0


def daemon_log_tail(n=8):
    try:
        with open(os.path.join(Rig.data, "pill.log")) as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


def setUpModule():
    Rig.up()


def tearDownModule():
    Rig.down()


class T1_Wiring(unittest.TestCase):
    def test_bridge_and_tokens_recorded(self):
        cfg = Rig.config
        self.assertEqual(cfg["bridge_host"], subprocess.run(
            ["sh", "-c", "ip -4 -o addr show lxdbr0 | awk '{print $4}' | cut -d/ -f1"],
            capture_output=True, text=True).stdout.strip())
        self.assertEqual(sorted(cfg["containers"]), sorted(Rig.containers))
        self.assertEqual(len(set(cfg["containers"].values())), len(Rig.containers))

    def test_existing_hooks_survive_the_merge(self):
        for c in Rig.containers:
            with self.subTest(container=c):
                # cc-pill's own entries (a container already wired) are replaced, not kept
                orig = wire.strip_hooks(json.loads(sh(c, "cat /root/.claude/settings.json 2>/dev/null || echo {}")))
                merged = json.loads(sh(c, f"cat {CT_HOME}/.claude/settings.json"))
                self.assertEqual({k: v for k, v in merged.items() if k != "hooks"},
                                 {k: v for k, v in orig.items() if k != "hooks"})
                for event, groups in (orig.get("hooks") or {}).items():
                    self.assertEqual(merged["hooks"][event][:len(groups)], groups, event)
                self.assertEqual(set(Rig.commands[c]), set(wire.EVENTS.values()))

    def test_remote_json_is_private_and_points_at_the_bridge(self):
        for c in Rig.containers:
            with self.subTest(container=c):
                mode = sh(c, f"stat -c %a {CT_HOME}/.cc-pill/remote.json").strip()
                self.assertEqual(mode, "600")
                remote = json.loads(sh(c, f"cat {CT_HOME}/.cc-pill/remote.json"))
                self.assertEqual(remote["container"], c)
                self.assertEqual(remote["url"], f"http://{Rig.config['bridge_host']}:{PORT}")


class T2_Sessions(unittest.TestCase):
    def test_lifecycle_in_every_container(self):
        for c in Rig.containers:
            with self.subTest(container=c):
                sid = f"{TAG}-{c}"
                Rig.fire(c, "start", sid)
                s = wait_for(lambda: session(sid))
                self.assertIsNotNone(s, f"no session from {c}")
                self.assertEqual(s["container"], c)
                self.assertEqual(s["repo"], "proj")
                self.assertFalse(s["remote"])
                nspid = Rig.fake_pid(c)
                self.assertEqual(s["pid"], host_pid_by_tag(c, nspid),
                                 "the daemon must track the stand-in claude's host pid")

                Rig.fire(c, "prompt", sid)
                self.assertTrue(wait_for(lambda: (session(sid) or {}).get("state") == "working"))
                Rig.fire(c, "tool", sid, tool_name="Edit", tool_input={"file_path": "/x/worker.py"})
                self.assertTrue(wait_for(lambda: (session(sid) or {}).get("activity") == "editing worker.py"))
                Rig.fire(c, "notify", sid, message="Claude needs your permission to use Bash",
                         notification_type="permission_prompt")
                self.assertTrue(wait_for(lambda: (session(sid) or {}).get("state") == "waiting"))
                Rig.fire(c, "stop", sid)
                self.assertTrue(wait_for(lambda: (session(sid) or {}).get("state") == "done"))
                Rig.fire(c, "end", sid)
                self.assertTrue(wait_for(lambda: session(sid) is None))

    def test_reaped_when_claude_dies(self):
        c = Rig.containers[0]
        sid = f"{TAG}-reap"
        Rig.fire(c, "start", sid)
        self.assertIsNotNone(wait_for(lambda: session(sid)))
        sh(c, f"pkill -f '[f]ake_claude.py {TAG}'")
        # the daemon reaps every 10 s
        self.assertTrue(wait_for(lambda: session(sid) is None, 15), "dead session was not reaped")
        sh(c, f"rm -f {CT_DIR}/jobs/pid; setsid python3 {CT_DIR}/fake_claude.py {TAG} {CT_DIR}/jobs {CT_HOME} "
              f"</dev/null >/dev/null 2>&1 &")
        Rig.fake_pid(c)


class T3_Ssh(unittest.TestCase):
    def test_your_ssh_sessions_come_from_this_host(self):
        """Read-only: the SSH_CONNECTION your running container sessions got
        from `ssh <container>.lxd` names an address the daemon counts as this
        host's, so they show as local."""
        sys.path.insert(0, os.path.join(REPO, "linux", "daemon"))
        import ccpilld
        local = ccpilld.host_addresses()
        seen = []
        for c in Rig.containers:
            out = sh(c, "for p in $(pgrep -x claude); do tr '\\0' '\\n' < /proc/$p/environ 2>/dev/null "
                        "| grep '^SSH_CONNECTION=' | head -1; done", check=False)
            seen += [(c, l.split("=", 1)[1].split()[0]) for l in out.splitlines() if "=" in l]
        if not seen:
            self.skipTest("none of your container sessions was started over ssh")
        for c, client in seen:
            with self.subTest(container=c, client=client):
                self.assertIn(client, local)

    def test_real_ssh_from_this_host_is_local(self):
        # Opt-in: a real ssh asks your ssh agent to sign, which can pop up a
        # PIN or touch prompt and wait on it.
        if not OPTS.ssh:
            self.skipTest("pass --ssh to open a real ssh connection (may ask your ssh agent)")
        c = Rig.containers[0]
        sid = f"{TAG}-ssh"
        payload = json.dumps({"session_id": sid, "cwd": CT_DIR + "/proj"})
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", f"root@{c}.lxd",
                            f"HOME={CT_HOME} sh -c '{Rig.commands[c]['start']}'"],
                           input=payload, capture_output=True, text=True, timeout=20)
        if p.returncode == 255:
            self.skipTest(f"ssh root@{c}.lxd unavailable: {p.stderr.strip()}")
        s = wait_for(lambda: session(sid))
        self.assertIsNotNone(s)
        self.assertFalse(s["remote"], "ssh from this host must not count as a remote session")
        Rig.fire(c, "end", sid)

    def test_ssh_from_elsewhere_is_remote(self):
        c = Rig.containers[0]
        sid = f"{TAG}-far"
        cmd = Rig.commands[c]["start"]
        sh(c, f"echo '{{\"session_id\": \"{sid}\", \"cwd\": \"/x\"}}' | "
              f"HOME={CT_HOME} SSH_CONNECTION='203.0.113.9 5000 10.0.0.2 22' sh -c '{cmd}'")
        s = wait_for(lambda: session(sid))
        self.assertTrue(s and s["remote"])
        Rig.fire(c, "end", sid)


class T3b_Briefings(unittest.TestCase):
    """A container session's finished turn reaches the host's voice worker
    with the final message and the container's name (stand-in worker: no
    audio, no Haiku)."""

    def jobs_for(self, sid):
        out = []
        for n in os.listdir(Rig.voice_jobs):
            if n.startswith("job-"):
                with open(os.path.join(Rig.voice_jobs, n)) as f:
                    j = json.load(f)
                if j.get("session_id") == sid:
                    out.append(j)
        return out

    def test_stop_from_every_container_reaches_the_voice(self):
        for c in Rig.containers:
            with self.subTest(container=c):
                sid = f"{TAG}-voice-{c}"
                Rig.fire(c, "start", sid)
                Rig.fire(c, "prompt", sid)
                Rig.fire(c, "stop", sid, last_assistant_message=f"Done in {c}. All 41 tests pass.")
                jobs = wait_for(lambda: self.jobs_for(sid), 8)
                self.assertTrue(jobs, f"no briefing job from {c}")
                [job] = jobs
                self.assertEqual((job["container"], job["pill_mode"]), (c, "stop"))
                self.assertEqual(job["last_assistant_message"], f"Done in {c}. All 41 tests pass.")
                with open(os.path.join(Rig.voice_jobs, ".worker")) as f:
                    self.assertEqual(f.read().strip(), os.path.join(Rig.voice, "worker.py"))
                Rig.fire(c, "end", sid)

    def test_transcript_fallback_inside_the_container(self):
        c = Rig.containers[0]
        sid = f"{TAG}-voice-transcript"
        t = f"{CT_DIR}/transcript.jsonl"
        line = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "From the transcript."}]}})
        sh(c, f"cat > {t}", input=line + "\n")
        Rig.fire(c, "stop", sid, transcript_path=t)
        jobs = wait_for(lambda: self.jobs_for(sid), 8)
        self.assertEqual([j["last_assistant_message"] for j in jobs], ["From the transcript."])
        Rig.fire(c, "end", sid)

    def test_permission_prompt_reaches_the_voice(self):
        c = Rig.containers[-1]
        sid = f"{TAG}-voice-notify"
        Rig.fire(c, "notify", sid, message="Claude needs your permission to use Bash",
                 notification_type="permission_prompt")
        jobs = wait_for(lambda: self.jobs_for(sid), 8)
        self.assertEqual([(j["pill_mode"], j["notification_type"], j["container"]) for j in jobs],
                         [("notify", "permission_prompt", c)])
        Rig.fire(c, "end", sid)


class T4_BridgeSecurity(unittest.TestCase):
    def curl(self, c, path, token, body='{"container":"%s","event":{"type":"start","sid":"evil"}}'):
        url = f"http://{Rig.config['bridge_host']}:{PORT}{path}"
        return sh(c, f"curl -s -o /dev/null -w '%{{http_code}}' -m 3 -H 'X-CC-Pill: 1' "
                     f"-H 'X-CC-Pill-Token: {token}' -d '{body % c}' {url}").strip()

    def test_bad_and_borrowed_tokens_are_refused(self):
        c = Rig.containers[0]
        self.assertEqual(self.curl(c, "/event", "wrong"), "403")
        if len(Rig.containers) > 1:
            other = Rig.config["containers"][Rig.containers[1]]
            self.assertEqual(self.curl(c, "/event", other), "403")
        self.assertIsNone(session("evil"))

    def test_only_event_is_reachable_from_containers(self):
        c = Rig.containers[0]
        token = Rig.config["containers"][c]
        for path in ("/ask", "/prompt", "/terminal", "/mute", "/place", "/stop"):
            self.assertEqual(self.curl(c, path, token), "404", path)
        url = f"http://{Rig.config['bridge_host']}:{PORT}/state"
        self.assertEqual(sh(c, f"curl -s -o /dev/null -w '%{{http_code}}' -m 3 -H 'X-CC-Pill: 1' {url}").strip(), "404")


class T5_CardActions(unittest.TestCase):
    def setUp(self):
        # Prefer a container with no tmux server of its own,
        # so nothing the user has open is ever touched
        idle = [c for c in Rig.containers if not sh(c, "tmux ls 2>/dev/null || true").strip()]
        if not idle:
            self.skipTest("every container has a tmux server in use; not touching it")
        self.c = idle[0]
        self.cwd = f"{CT_DIR}/proj"
        # cat echoes typed prompts; the sleep keeps the pane if a test client's ^D ends cat
        sh(self.c, f"tmux new-session -d -s {TAG} -c {self.cwd} 'cat; exec sleep 600'")
        self.sid = f"{TAG}-card"
        Rig.fire(self.c, "start", self.sid, cwd=self.cwd)
        self.assertIsNotNone(wait_for(lambda: session(self.sid)))

    def tearDown(self):
        Rig.fire(self.c, "end", self.sid, cwd=self.cwd)
        sh(self.c, f"tmux kill-session -t ={TAG} 2>/dev/null || true", check=False)

    def test_prompt_lands_in_the_containers_tmux_pane(self):
        code, r = api("/prompt", "POST", {"sid": self.sid, "text": f"hello from {TAG}"})
        self.assertEqual((code, r), (200, {"ok": True}),
                         sh(self.c, "tmux list-panes -a -F '#{pane_id} #{session_name} #{pane_current_path}'", check=False)
                         + daemon_log_tail())
        pane = wait_for(lambda: f"hello from {TAG}" in sh(self.c, f"tmux capture-pane -p -t {TAG}:"), 5)
        self.assertTrue(pane)

    def test_open_terminal_switches_an_attached_client_to_the_sessions_window(self):
        # The web-dev layout: claude sessions as windows of one tmux session,
        # a client attached showing another window. A throwaway client (under
        # script(1) for a tty) in the throwaway session stands in for it.
        sh(self.c, f"tmux new-window -d -t {TAG}: -c /tmp 'exec sleep 600'")
        sh(self.c, f"(TERM=xterm-256color setsid script -qfc 'tmux attach -t {TAG}' /dev/null "
                   f"</dev/null >/dev/null 2>&1 &)")
        clients = wait_for(lambda: sh(self.c, f"tmux list-clients -t {TAG} -F '#{{window_index}}'").split(), 5)
        if not clients:
            self.skipTest("could not attach a test client (script(1) missing?)")
        sh(self.c, f"tmux select-window -t {TAG}:1")
        self.assertTrue(wait_for(lambda: sh(self.c, f"tmux list-clients -t {TAG} -F '#{{window_index}}'").split() == ["1"], 5))
        code, r = api("/terminal", "POST", {"sid": self.sid})
        self.assertEqual((code, r), (200, {"ok": True}))
        self.assertTrue(wait_for(lambda: sh(self.c, f"tmux list-clients -t {TAG} -F '#{{window_index}}'").split() == ["0"], 5),
                        "the client should now show the session's window\n"
                        + sh(self.c, "tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index} #{pane_current_path}'")
                        + daemon_log_tail())

    def test_prompt_finds_the_right_pane_when_sessions_share_a_directory(self):
        # Two stand-in claudes in two panes of one window, same directory: the
        # web-dev layout where a directory match typed into the wrong session.
        panes = []
        for n in (1, 2):
            jobs = f"{CT_DIR}/jobs-pane{n}"
            sh(self.c, f"mkdir -p {jobs}")
            if n == 1:
                sh(self.c, f"tmux new-window -d -t {TAG}: -n shared -c {self.cwd} "
                           f"'python3 {CT_DIR}/fake_claude.py {TAG} {jobs} {CT_HOME}'")
            else:
                sh(self.c, f"tmux split-window -d -t {TAG}:shared -c {self.cwd} "
                           f"'python3 {CT_DIR}/fake_claude.py {TAG} {jobs} {CT_HOME}'")
            self.assertTrue(wait_for(lambda: sh(self.c, f"cat {jobs}/pid 2>/dev/null || true").strip(), 5))
            Rig.fire(self.c, "start", f"{TAG}-pane{n}", cwd=self.cwd, jobs=jobs)
            self.assertIsNotNone(wait_for(lambda: session(f"{TAG}-pane{n}")))
        panes = sh(self.c, f"tmux list-panes -t {TAG}:shared -F '#{{pane_id}}'").split()
        self.assertEqual(len(panes), 2)
        for n in (2, 1):
            code, r = api("/prompt", "POST", {"sid": f"{TAG}-pane{n}", "text": f"for pane {n} {TAG}"})
            self.assertEqual((code, r), (200, {"ok": True}), daemon_log_tail())
        for n, pane in ((1, panes[0]), (2, panes[1])):
            screen = wait_for(lambda: f"for pane {n}" in sh(self.c, f"tmux capture-pane -p -t {pane}") and
                              sh(self.c, f"tmux capture-pane -p -t {pane}"), 5)
            self.assertTrue(screen, f"pane {n} never got its prompt")
            self.assertNotIn(f"for pane {3 - n}", screen, f"pane {n} got the other session's prompt")
        for n in (1, 2):
            Rig.fire(self.c, "end", f"{TAG}-pane{n}", cwd=self.cwd, jobs=f"{CT_DIR}/jobs-pane{n}")

    def test_open_terminal_attaches_inside_the_container(self):
        code, r = api("/terminal", "POST", {"sid": self.sid})
        self.assertEqual((code, r), (200, {"ok": True}))
        self.assertTrue(wait_for(lambda: os.path.exists(Rig.term_log), 5))
        with open(Rig.term_log) as f:
            argv = f.read().split("\n")[:-1]
        self.assertEqual(argv[0], "-e")
        self.assertEqual(argv[2:], ["exec", self.c, "--env", "TERM=xterm-256color", "--", "tmux", "attach", "-t", TAG])
        self.assertTrue(os.access(argv[1], os.X_OK), f"lxc at {argv[1]} under systemd")

        # Run that command the way a terminal would, with your terminal's TERM
        # (xterm-ghostty, which the containers have no terminfo for), under a
        # pty and with no window: the client must attach.
        cmd = " ".join("'" + a.replace("'", "'\\''") + "'" for a in argv[1:])
        env = dict(os.environ, TERM=os.environ.get("TERM") or "xterm-ghostty")
        p = subprocess.Popen(["script", "-qfec", cmd, "/dev/null"], env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            attached = wait_for(lambda: sh(self.c, f"tmux list-clients -t {TAG} -F x").strip(), 6)
            self.assertTrue(attached, f"the terminal command did not attach with TERM={env['TERM']}")
        finally:
            sh(self.c, f"tmux detach-client -s {TAG} 2>/dev/null || true", check=False)
            p.stdin.close()
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                p.kill()


class T6_Widget(unittest.TestCase):
    """This checkout's widget, loaded by Plasma itself (offscreen), card open."""

    def test_card_renders_container_sessions_without_qml_errors(self):
        if not shutil.which("plasmawindowed"):
            self.skipTest("plasmawindowed not installed")
        c = Rig.containers[0]
        sid = f"{TAG}-widget"
        Rig.fire(c, "start", sid)
        self.assertIsNotNone(wait_for(lambda: session(sid)))

        root = os.path.join(Rig.scratch, "widget")
        data, conf = os.path.join(root, "data"), os.path.join(root, "config")
        pkg = os.path.join(root, "pkg")
        shutil.copytree(os.path.join(REPO, "linux", "plasmoid", "com.ccpill.pill"), pkg)
        main = os.path.join(pkg, "contents", "ui", "main.qml")
        with open(main) as f:
            src = f.read()
        # Open the card instead of the pill, and print every visible label.
        src = src.replace("preferredRepresentation: compactRepresentation",
                          "preferredRepresentation: fullRepresentation\n"
                          "    function itestDump(it) { if (!it || !it.visible) return;"
                          " if (typeof it.text === 'string' && it.text) console.log('ITEST-LABEL', it.text);"
                          " for (let i = 0; i < it.children.length; i++) itestDump(it.children[i]) }", 1)
        src = src.replace("fullRepresentation: Card { ctl: root }",
                          "fullRepresentation: Card { id: itestCard; ctl: root\n"
                          "        Timer { interval: 2500; running: true; repeat: true;"
                          " onTriggered: root.itestDump(itestCard) } }", 1)
        self.assertIn("itestDump(itestCard)", src)
        with open(main, "w") as f:
            f.write(src)
        os.makedirs(os.path.join(conf), exist_ok=True)
        with open(os.path.join(conf, "plasmawindowedrc"), "w") as f:
            f.write("[Applets][1]\nimmutability=1\nplugin=com.ccpill.pill\n\n"
                    "[Applets][1][Configuration]\ngeometry=0,0,700,600\n\n"
                    f"[Applets][1][Configuration][General]\nport={PORT}\n")
        env = dict(os.environ, XDG_DATA_HOME=data, XDG_CONFIG_HOME=conf,
                   XDG_CACHE_HOME=os.path.join(root, "cache"), QT_QPA_PLATFORM="offscreen")
        subprocess.run(["kpackagetool6", "--type", "Plasma/Applet", "--install", pkg],
                       env=env, check=True, capture_output=True)
        try:
            p = subprocess.run(["plasmawindowed", "com.ccpill.pill"], env=env,
                               capture_output=True, text=True, timeout=9)
            out = p.stdout + p.stderr
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"").decode() + (e.stderr or b"").decode()
        Rig.fire(c, "end", sid)
        errors = [l for l in out.splitlines()
                  if ("qml" in l.lower() and ("error" in l.lower() or "TypeError" in l or "ReferenceError" in l
                                              or "is not defined" in l or "Cannot" in l))
                  or ".qml:" in l and "ITEST" not in l]
        self.assertEqual(errors, [], out[-3000:])
        labels = [l.split("ITEST-LABEL", 1)[1].strip() for l in out.splitlines() if "ITEST-LABEL" in l]
        self.assertIn("proj", labels, f"card never showed the session; labels: {labels}\n{out[-2000:]}")
        self.assertIn(c, labels, f"card row does not show the container; labels: {labels}")
        self.assertNotIn("+ NEW", labels, "hands-free sessions were taken out of the card")


class T7_RealSessions(unittest.TestCase):
    """Read-only: when one of your sessions runs any hook, the hook's process
    chain must lead (past shells) to the `claude` session process, not to one
    of Claude Code's helpers (daemon, bg-pty-host)."""

    def test_hook_parent_is_the_session_process(self):
        hook = load("hook_live", os.path.join(REPO, "hooks", "hook.py"))
        end = time.time() + OPTS.watch
        seen = set()
        found = []
        while time.time() < end and len(found) < 3:
            for p in os.listdir("/proc"):
                if not p.isdigit() or p in seen:
                    continue
                try:
                    with open(f"/proc/{p}/cgroup") as f:
                        cg = f.read()
                    if "lxc.payload." not in cg:
                        continue
                    with open(f"/proc/{p}/cmdline", "rb") as f:
                        cmd = f.read().replace(b"\0", b" ").decode(errors="replace")
                except OSError:
                    continue
                if "/.claude/hooks/" not in cmd or TAG in cmd:
                    continue
                seen.add(p)
                # What hook.py's walk would answer for a hook spawned like this one:
                # this process plays the hook, its parent chain is real.
                info = hook._proc(int(p))
                if not info:
                    continue
                pid = info[1]
                for _ in range(4):
                    i = hook._proc(pid)
                    if not i or i[0] not in hook.SHELLS or i[1] <= 1:
                        break
                    pid = i[1]
                try:
                    with open(f"/proc/{pid}/cmdline", "rb") as f:
                        target = f.read().replace(b"\0", b" ").decode(errors="replace").strip()
                except OSError:
                    continue   # gone already
                container = cg.split("lxc.payload.", 1)[1].split("/", 1)[0]
                try:
                    with open(f"/proc/{pid}/status") as f:
                        nspid = next(l.split()[-1] for l in f if l.startswith("NSpid:"))
                except (OSError, StopIteration):
                    continue
                cwd = sh(container, f"readlink /proc/{nspid}/cwd", check=False).strip()
                found.append((cmd.strip()[:60], target[:80], cwd))
            time.sleep(0.005)
        if not found:
            self.skipTest(f"none of your container sessions ran a hook in {OPTS.watch:.0f}s; "
                          "re-run with a session working (or a larger --watch)")
        for cmd, target, cwd in found:
            print(f"\n    observed: {cmd}\n      -> resolves to: {target}  (cwd {cwd})", file=sys.stderr)
            with self.subTest(hook=cmd):
                self.assertNotIn(" daemon ", f" {target} ")
                self.assertNotIn("bg-pty-host", target)
                # A claimed background spare is the session itself: it has moved
                # to the project. One still in its spare dir is not a session.
                self.assertNotRegex(cwd, r"/cc-daemon-[^/]+/[^/]+/spare(/|$)", f"{target} in {cwd}")
                self.assertRegex(target, r"(^|/)claude( |$)", f"walk landed on: {target}")


class T9_NoTrace(unittest.TestCase):
    """Last: tear everything down and prove nothing on the system changed."""

    def test_nothing_changed(self):
        Rig.down()
        Rig.unit = None
        time.sleep(0.5)
        after = fingerprint(Rig.containers)
        diff = {k: (Rig.before[k], after[k]) for k in Rig.before if Rig.before[k] != after[k]}
        self.assertEqual(diff, {})
        Rig.containers = []


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--containers", type=lambda s: [c for c in s.split(",") if c])
    ap.add_argument("--watch", type=float, default=45.0, help="seconds to watch your sessions' hooks (T7)")
    ap.add_argument("--ssh", action="store_true", help="also ssh into a container for real (T3)")
    ap.add_argument("-v", action="store_true")
    a, rest = ap.parse_known_args()
    OPTS.containers, OPTS.watch, OPTS.ssh = a.containers, a.watch, a.ssh
    unittest.main(argv=[sys.argv[0]] + (["-v"] if a.v else []) + rest)
