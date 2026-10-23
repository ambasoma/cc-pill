#!/usr/bin/env python3
"""ccpilld: the pill's brain on Linux.

The macOS app keeps the session model and the renderer in one Swift
process. On Linux the model lives here, as a small stdlib-only daemon, and
renderers (the Plasma widget, or anything else) read it over a localhost
HTTP API or from ~/.cc-pill/state.json.

What it does, one for one with app/Sources/Pill/Model.swift:
  * watches ~/.cc-pill/events/ for the JSON events written by hooks/hook.py
    and the voice worker, applies them, deletes them
  * tracks every Claude Code session (working / waiting / done), narrates
    what the newest working session is doing, reaps dead sessions
  * runs the briefing bloom and the critter moments on the same timings
  * performs the card's actions: replay briefing, send a prompt to a
    session, mute, stop speech
  * optionally takes events from Claude Code sessions inside LXD containers,
    posted by the same hook over the LXD bridge (see "containers" below)
  * runs Alfred, the assistant behind the hotkey (alfred.py)

Run it under a systemd user service (linux/setup.sh does this). Set
CC_PILL_HOME to use a different data directory (tests do).
"""
import errno
import hmac
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.environ.get("CC_PILL_HOME") or os.path.expanduser("~/.cc-pill")
EVENTS_DIR = os.path.join(HOME, "events")
STATE_PATH = os.path.join(HOME, "state.json")
LOG_PATH = os.path.join(HOME, "pill.log")
CONFIG_PATH = os.path.join(HOME, "config.json")

# <install>/linux/daemon/ccpilld.py -> <install>
INSTALL_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEFAULT_PORT = 17357
API_HEADER = "X-CC-Pill"

# The pill contracts 1.1 s after the last working signal (Swift: holdUntil).
HOLD_SECONDS = 1.1
# Narration alternates repo / activity on this phase (Swift: 3.5).
NARRATION_PHASE = 3.5
# A tool label older than this is no longer narrated.
ACTIVITY_FRESH = 90
# Elapsed minutes appear in the narration from this many minutes.
ELAPSED_FROM_MINUTES = 3
NARRATION_CLEAR_DELAY = 0.9
BRIEFING_TAIL = 3.0
MOMENT_FALLBACK = 6.0
MOMENT_DURATION = {"star": 2.4, "sad": 3.0}
TOAST_SECONDS = 3.0
REAP_INTERVAL = 10.0
# Spoken briefings for container sessions: one job per session per window,
# and no more than this many waiting, whatever a container posts.
BRIEF_WINDOW = 15.0
BRIEF_QUEUE_MAX = 4
ADDRS_TTL = 300.0
PID_RETRY = 30.0     # seconds between lookups of a container pid that wasn't found

# Claude Code 2.x pre-starts "spare" processes for background sessions, in
# /tmp/cc-daemon-<uid>/<id>/spare, and moves one to its project when it is
# claimed. Nothing real runs there: an event from it is never a session.
SPARE_CWD_RE = re.compile(r"/cc-daemon-[^/]+/[^/]+/spare(/|$)")

SAD_RE = re.compile(r"fail(ed|ing)?|error|broke|broken|couldn.t|didn.t work|crash", re.I)

# ---------------------------------------------------------------- logging

def log(msg):
    """Append one timestamped line to pill.log (same format as the Swift app)."""
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except OSError:
        pass


# ----------------------------------------------------------------- config

class Config:
    """~/.cc-pill/config.json, with the same keys and defaults as MBConfig."""

    def __init__(self, data=None):
        data = data or {}
        self.name = data.get("name") or "Jarvis"
        self.speaker = os.path.expanduser(data.get("speaker") or os.path.join(INSTALL_DIR, "voice"))
        self.hotkey = data.get("hotkey") or "meta+alt+m"
        port = data.get("daemon_port", DEFAULT_PORT)
        self.port = int(port) if isinstance(port, int) and 1024 <= port <= 65535 else DEFAULT_PORT
        # LXD containers: the host's bridge address the containers post to,
        # and one token per container ({"web-dev": "<token>"}).
        bh = data.get("bridge_host")
        # The bridge listener is for the LXD bridge only, never every interface.
        self.bridge_host = bh if isinstance(bh, str) and bh not in ("0.0.0.0", "::", "") else ""
        ct = data.get("containers")
        self.containers = {str(k): str(v) for k, v in ct.items() if v} if isinstance(ct, dict) else {}
        self.lxc_bin = data.get("lxc_bin") or shutil.which("lxc") or "/snap/bin/lxc"
        # Alfred: the local model server, Whisper and the recorder; each one
        # defaults to what ~/.local/opt/local-ai holds, when it is there.
        def found(key, path):
            v = data.get(key)
            if isinstance(v, str):
                return os.path.expanduser(v)
            return path if os.path.exists(path) else ""
        ai = os.path.expanduser("~/.local/opt/local-ai")
        self.alfred_llm_url = data.get("alfred_llm_url") or "http://127.0.0.1:8099"
        self.alfred_llm_cmd = found("alfred_llm_cmd", os.path.join(ai, "bin", "llm-server"))
        self.alfred_whisper_cli = found("alfred_whisper_cli",
                                        os.path.join(ai, "whisper.cpp", "whisper-bin-ubuntu-x64", "whisper-cli"))
        self.alfred_whisper_model = found("alfred_whisper_model", os.path.join(ai, "models", "ggml-base.en.bin"))
        self.alfred_recorder = data.get("alfred_recorder") or shutil.which("pw-record") or shutil.which("arecord") or ""
        idle = data.get("alfred_llm_idle_minutes", 15)
        self.alfred_llm_idle = float(idle) * 60 if isinstance(idle, (int, float)) else 900.0
        # The uid Claude Code runs as inside a container, when it isn't root
        # (cc-pill-containers add --user): tmux runs as that user.
        cu = data.get("container_users")
        self.container_users = {str(k): v for k, v in cu.items()
                                if isinstance(v, int) and v > 0} if isinstance(cu, dict) else {}

    @classmethod
    def load(cls, path=CONFIG_PATH):
        try:
            with open(path) as f:
                data = json.load(f)
            if not isinstance(data, dict):
                data = {}
        except (OSError, ValueError):
            data = {}
        return cls(data)



# -------------------------------------------------------------- processes

def user_path():
    """PATH with the usual user bin dirs first: systemd user managers don't
    always have ~/.local/bin, where Claude Code installs itself."""
    return os.path.expanduser("~/.local/bin") + ":/usr/local/bin:" + os.environ.get("PATH", "/usr/bin:/bin")


EVENT_STR = ("type", "sid", "repo", "cwd", "label", "msg", "ssh_client")


def clean_event(evt):
    """A container's event with every field the daemon reads coerced to
    its type: a container can post anything."""
    out = {k: (evt.get(k) if isinstance(evt.get(k), str) else "")[:4096] for k in EVENT_STR}
    out["repo"] = out["repo"][:200] or "?"
    pid = evt.get("pid")
    out["pid"] = pid if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0 else 0
    out["idle"] = evt.get("idle") is True
    sp = evt.get("speech")
    if isinstance(sp, dict):
        out["speech"] = {"text": sp["text"] if isinstance(sp.get("text"), str) else "",
                         "notification_type": sp["notification_type"]
                         if isinstance(sp.get("notification_type"), str) else ""}
    return out


def run(args, timeout=8, input=None, cwd=None, stderr=True):
    """Run a command, returning (stdout+stderr, exit code). Never raises.
    stderr=False leaves out the command's log lines (Whisper).

    Under systemd the PATH can be bare: add the usual user bin dirs. Set a
    UTF-8 locale for tmux. Its -F output is split on tabs: tmux 3.5 escapes
    other control characters (\x01 comes out as the text "\001").
    """
    env = dict(os.environ, PATH=user_path())
    if not env.get("LANG"):
        env["LANG"] = "C.UTF-8"
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env,
                           input=input, cwd=cwd)
        return (p.stdout + p.stderr if stderr else p.stdout), p.returncode
    except subprocess.TimeoutExpired as e:
        return (e.stdout or "") if isinstance(e.stdout, str) else "", -1
    except (OSError, ValueError):
        return "", -1


def spawn(args, cwd=None, env=None):
    """Start a detached process (never waits, never raises). `env` adds to
    this process's environment."""
    try:
        subprocess.Popen(args, cwd=cwd, env=dict(os.environ, **env) if env else None,
                         stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        return True
    except OSError:
        return False


def pid_alive(pid):
    """True unless the process is definitely gone (ESRCH), like kill(pid, 0)."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError as e:
        return e.errno != errno.ESRCH


def container_host_pid(container, nspid, proc="/proc"):
    """The host pid of process `nspid` inside LXD container `container`, or 0.

    Container processes are visible on the host: their cgroup path names the
    container (lxc.payload.<name>) and the second NSpid field is the pid as the
    container sees it. Owned by a mapped uid, so kill(pid, 0) answers EPERM,
    which pid_alive already counts as alive."""
    marker = f"/lxc.payload.{container}/"
    try:
        names = os.listdir(proc)
    except OSError:
        return 0
    for name in names:
        if not name.isdigit():
            continue
        try:
            with open(f"{proc}/{name}/status") as f:
                ns = next((l.split()[1:] for l in f if l.startswith("NSpid:")), None)
            # ns[1]: the container's own namespace. A deeper field belongs
            # to a sandbox inside the container (bwrap, docker), whose pids
            # can repeat the session's number.
            if not ns or len(ns) < 2 or ns[1] != str(nspid):
                continue
            with open(f"{proc}/{name}/cgroup") as f:
                cg = f.read()
        except (OSError, ValueError):
            continue
        if marker in cg or cg.rstrip().endswith(marker.rstrip("/")):
            return int(name)
    return 0


def ancestor_pids(pid, proc="/proc", limit=40, depth=0):
    """`pid` and its ancestors, as pid namespace `depth` sees them: 0 is the
    host, 1 a top-level LXD container, where tmux reports its pane_pid."""
    seen = set()
    while pid > 1 and len(seen) < limit:
        try:
            with open(f"{proc}/{pid}/status") as f:
                fields = dict(l.split(":", 1) for l in f if ":" in l)
            ns = fields["NSpid"].split()
            seen.add(int(ns[min(depth, len(ns) - 1)]))
            pid = int(fields["PPid"].split()[0])
        except (OSError, KeyError, ValueError, IndexError):
            break
    return seen


def host_addresses(runner=None):
    """Every address of this host (for telling an ssh from the host apart
    from a genuinely remote one)."""
    out, _ = (runner or run)(["ip", "-o", "addr", "show"])
    addrs = set()
    for line in out.splitlines():
        parts = line.split()
        for i, w in enumerate(parts[:-1]):
            if w in ("inet", "inet6"):
                addrs.add(parts[i + 1].split("/")[0])
    return addrs


# ------------------------------------------------------------------ model

class Session:
    __slots__ = ("id", "repo", "cwd", "pid", "state", "since", "activity",
                 "activity_at", "last_briefing", "remote", "container")

    def __init__(self, sid, repo, cwd, pid, state, since, remote=False, container=""):
        self.id = sid
        self.repo = repo
        self.cwd = cwd
        self.pid = pid
        self.state = state          # working | waiting | done
        self.since = since          # when the CURRENT state was entered
        self.activity = None        # "editing worker.py", from tool events
        self.activity_at = None
        self.last_briefing = None
        self.remote = remote
        self.container = container  # LXD container name, "" on the host

    def to_json(self):
        return {
            "id": self.id, "repo": self.repo, "cwd": self.cwd, "pid": self.pid,
            "state": self.state, "since": self.since, "activity": self.activity,
            "activity_at": self.activity_at, "last_briefing": self.last_briefing,
            "remote": self.remote, "container": self.container,
        }


def short(sid):
    return sid[:8]


class Store:
    """The session model. Port of Store in Model.swift.

    Timers are deadlines checked in tick(), so the whole model is driven by
    an injectable clock and is deterministic under test. All public methods
    take the lock; renderers call them from HTTP threads.
    """

    def __init__(self, config, clock=time.time, runner=run, spawner=spawn,
                 alive=pid_alive, rng=random.random, sleeper=time.sleep,
                 host_pid=container_host_pid, local_addrs=None, ancestors=ancestor_pids):
        self.config = config
        self.clock = clock
        self.run = runner
        self.spawn = spawner
        self.alive = alive
        self.rng = rng
        self.sleep = sleeper
        self.host_pid = host_pid
        self.ancestors = ancestors
        self._local_addrs = local_addrs   # lazily from `ip addr`
        self._local_addrs_at = clock() if local_addrs else 0.0
        self._brief_last = {}             # (sid, mode) -> when a job was last queued
        self._pid_cache = {}              # (container, container pid) -> host pid
        self._pid_miss = {}               # (container, container pid) -> when a lookup last failed
        self.lock = threading.RLock()

        self.sessions = []
        self.briefing = None
        self.moment = None
        self.narration = ""
        self.toast = None

        self._held_working = None
        self._hold_until = 0.0
        self._narr_clear_at = None
        self._briefing_clear_at = None
        self._pending_moment = False
        self._pending_moment_repo = ""
        self._moment_fallback_at = None
        self._moment_end_at = None
        self._toast_clear_at = None
        self._last_reap = 0.0

        self.version = 0
        self._last_signature = None
        self.alfred = None      # set by main(): the assistant

    # ------------------------------------------------------------ pill state

    def _raw_pill_state(self):
        if self.briefing is not None:
            return ("speaking", "")
        if self.moment is not None:
            return ("moment", self.moment["kind"])
        if not self.sessions:
            return ("hidden", "")
        if any(s.state == "waiting" for s in self.sessions):
            return ("waiting", "")
        working = [s for s in self.sessions if s.state == "working"]
        if working:
            newest = max(working, key=lambda s: s.since)
            return ("working", f"{len(working)} sessions" if len(working) > 1 else newest.repo)
        return ("idle", "")

    def pill_state(self):
        """(state, label) with the contraction hysteresis applied."""
        raw = self._raw_pill_state()
        if raw[0] == "idle" and self._held_working and self.clock() < self._hold_until:
            return self._held_working
        return raw

    def narrated_session(self):
        working = [s for s in self.sessions if s.state == "working"]
        return max(working, key=lambda s: s.since) if working else None

    def _update_narration(self, now):
        raw = self._raw_pill_state()
        if raw[0] == "working":
            self._held_working = raw
            self._hold_until = now + HOLD_SECONDS
        state = self.pill_state()
        s = self.narrated_session()
        if state[0] != "working" or s is None:
            self._set_narration("", now)
            return
        working = [x for x in self.sessions if x.state == "working"]
        base = f"{len(working)} sessions" if len(working) > 1 else s.repo
        mins = int((now - s.since) / 60)
        text = f"{base} · {mins}m" if mins >= ELAPSED_FROM_MINUTES else base
        phase = int(now / NARRATION_PHASE) % 2
        if phase == 1 and s.activity and s.activity_at is not None and now - s.activity_at < ACTIVITY_FRESH:
            text = s.activity
        self._set_narration(text, now)

    def _set_narration(self, text, now):
        if not text:
            if self.narration and self._narr_clear_at is None:
                self._narr_clear_at = now + NARRATION_CLEAR_DELAY
        else:
            self._narr_clear_at = None
            if self.narration != text:
                self.narration = text

    # ---------------------------------------------------------------- events

    def apply(self, evt):
        with self.lock:
            return self._apply(evt)

    def apply_container(self, container, evt):
        """An event posted from inside an LXD container. Its pid is the
        container's view: translate it to the host pid so reaping works.
        An ssh from this host into the container is a local session, not a
        remote one."""
        if not isinstance(evt, dict) or not container:
            return
        evt = clean_event(evt)
        evt["container"] = container
        if evt["pid"]:
            key = (container, evt["pid"])
            hp = self._pid_cache.get(key)
            if not hp or not self.alive(hp):
                hp = 0
                # A failed lookup scans all of /proc: don't repeat it on every
                # event of the session, only now and then.
                if self.clock() - self._pid_miss.get(key, -PID_RETRY) >= PID_RETRY:
                    hp = self.host_pid(container, evt["pid"])
                    if hp:
                        self._pid_cache[key] = hp
                        self._pid_miss.pop(key, None)
                    else:
                        self._pid_miss[key] = self.clock()
            evt["pid"] = hp or 0
        client = evt.pop("ssh_client")
        evt["remote"] = bool(client) and client not in self.local_addresses()
        speech = evt.pop("speech", None)
        with self.lock:
            # A container speaks only for its own sessions.
            s = self._find(evt["sid"])
            if s is not None and s.container != container:
                log(f"dropped {evt['type'] or 'event'} from {container} for a session of "
                    f"{s.container or 'the host'} [{short(evt['sid'])}]")
                return
            accepted = self._apply(evt)
        if accepted and evt.get("type") in ("stop", "notify") and not evt["remote"]:
            self.brief_container(container, evt, speech or {})

    def local_addresses(self):
        """This host's addresses, re-read now and then (a VPN or the bridge
        can come up after the daemon); an empty answer is never kept."""
        now = self.clock()
        if not self._local_addrs or now - self._local_addrs_at > ADDRS_TTL:
            addrs = host_addresses(self.run)
            if addrs:
                self._local_addrs, self._local_addrs_at = addrs, now
        return self._local_addrs or set()

    def brief_container(self, container, evt, speech):
        """Hand a container session's finished turn (or permission prompt) to
        the voice worker on this host, the way voice/hook.py does for host
        sessions: the container has no voice, no audio and no Claude login of
        its own for the summary. Its hook sent the text along."""
        if not self.voice_available() or self.voice_muted():
            return False
        now = self.clock()
        key = (evt.get("sid") or "", evt.get("type"))
        if now - self._brief_last.get(key, -BRIEF_WINDOW) < BRIEF_WINDOW:
            log(f"briefing skipped: {container} [{short(key[0])}] spoke under {BRIEF_WINDOW:.0f}s ago")
            return False
        spool = os.path.join(self.config.speaker, "spool")
        waiting = 0
        try:
            # A worker deletes its job as it starts; one that never started
            # (a broken venv) leaves it. Only recent jobs count, so leftovers
            # can't silence the voice for good.
            for n in os.listdir(spool):
                if n.startswith("job-"):
                    try:
                        waiting += time.time() - os.path.getmtime(os.path.join(spool, n)) < 120
                    except OSError:
                        pass
        except OSError:
            pass
        if waiting >= BRIEF_QUEUE_MAX:
            log(f"briefing skipped: {waiting} already waiting")
            return False
        job = {
            "pill_mode": evt["type"], "container": container,
            "session_id": evt["sid"], "cwd": evt["cwd"],
            "last_assistant_message": speech.get("text", "")[:8000],
            "message": evt["msg"][:2000],
            "notification_type": speech.get("notification_type", ""),
            # how the worker reaches the container's tmux
            "exec_prefix": self.in_container(container, []),
        }
        if job["pill_mode"] == "stop" and not job["last_assistant_message"].strip():
            return False
        try:
            os.makedirs(spool, exist_ok=True)
            path = os.path.join(spool, f"job-{time.time_ns()}.json")
            with open(path, "w") as f:
                json.dump(job, f)
        except OSError as e:
            log(f"ERROR: cannot queue briefing for {container}: {e}")
            return False
        worker = os.path.join(self.config.speaker, "worker.py")
        voice_log = os.path.join(spool, "voice.log")
        self._brief_last[key] = now
        log(f"briefing queued: {container} {evt.get('repo') or '?'} ({job['pill_mode']})")
        # sh only to append the worker's output to voice.log, like voice/hook.py
        return self.spawn(["sh", "-c", 'exec "$0" "$@" >>"$CCPILL_VOICE_LOG" 2>&1',
                           self.voice_python(), worker, path],
                          env={"CCPILL_VOICE_LOG": voice_log, "PATH": user_path()})

    def _apply(self, evt):
        """Apply one event; False when it was dropped."""
        if not isinstance(evt, dict):
            return False
        now = self.clock()
        typ = evt.get("type") or ""
        sid = evt.get("sid") or ""
        repo = evt.get("repo") or "?"
        cwd = evt.get("cwd") or ""
        pid = evt.get("pid") or 0
        pid = int(pid) if isinstance(pid, (int, float)) else 0
        remote = bool(evt.get("remote", False))
        container = evt.get("container") or ""
        if not isinstance(cwd, str) or SPARE_CWD_RE.search(cwd):
            return False

        if typ == "start":
            self._upsert(sid, repo, cwd, pid, remote, container, "done", now)
            log(f"session start: {repo} [{short(sid)}]")
        elif typ == "prompt":
            self._upsert(sid, repo, cwd, pid, remote, container, "working", now)
            log(f"working: {repo} [{short(sid)}]")
        elif typ == "stop":
            s = self._find(sid)
            was_working = s is not None and s.state == "working"
            self._upsert(sid, repo, cwd, pid, remote, container, "done", now)
            s = self._find(sid)
            if s is not None:
                s.activity = None
                s.activity_at = None
            log(f"done: {repo} [{short(sid)}]")
            if was_working:
                # A finished turn earns a critter moment. Usually the briefing
                # arrives within seconds and the moment plays after the bloom;
                # if no briefing shows up, play it anyway.
                self._pending_moment = True
                self._pending_moment_repo = repo
                self._moment_fallback_at = now + MOMENT_FALLBACK
        elif typ == "tool":
            label = evt.get("label") or ""
            if not label or not sid:
                return False
            s = self._find(sid)
            if s is not None:
                if s.state != "working":
                    s.state = "working"
                    s.since = now
                if s.activity != label:
                    s.activity = label
                    s.activity_at = now
                    log(f"activity: {repo}: {label}")
            else:
                self._upsert(sid, repo, cwd, pid, remote, container, "working", now)
                s = self._find(sid)
                if s is not None:
                    s.activity = label
                    s.activity_at = now
        elif typ == "notify":
            if evt.get("idle"):
                log(f"idle nag ignored: {repo}")
            else:
                self._upsert(sid, repo, cwd, pid, remote, container, "waiting", now)
                log(f"waiting: {repo} [{short(sid)}]")
        elif typ == "end":
            self.sessions = [s for s in self.sessions if s.id != sid]
            log(f"session end: {repo} [{short(sid)}]")
        elif typ == "briefing":
            text = evt.get("text") or ""
            if not isinstance(text, str) or not text:
                return False
            silent = bool(evt.get("silent", False))
            duration = evt.get("duration") or 0
            duration = float(duration) if isinstance(duration, (int, float)) else 0.0
            if duration <= 0:
                duration = min(6.0, len(text.split()) * 0.3)
            sad = SAD_RE.search(text) is not None
            self._moment_fallback_at = None  # moment now plays after the bloom
            self.briefing = {
                "text": text, "duration": duration, "silent": silent,
                "started": now, "repo": repo, "sad": sad, "sid": sid,
            }
            s = self._find(sid) if sid else None
            if s is not None:
                s.last_briefing = text
            how = "silent" if silent else f"{duration:.1f}s"
            log(f"briefing ({how}): {text[:60]}")
            self._briefing_clear_at = now + duration + BRIEFING_TAIL
        return True

    def _find(self, sid):
        for s in self.sessions:
            if s.id == sid:
                return s
        return None

    def _upsert(self, sid, repo, cwd, pid, remote, container, state, now):
        if not sid:
            return
        # A real hook event supersedes an adopted placeholder for the same claude.
        if pid > 0 and not sid.startswith("tmux-"):
            self.sessions = [s for s in self.sessions
                             if not (s.pid == pid and s.id.startswith("tmux-"))]
        s = self._find(sid)
        if s is not None:
            if s.state != state:
                s.state = state
                s.since = now   # elapsed measures time IN a state
            if pid > 0:
                s.pid = pid
            if cwd:
                s.cwd = cwd
                s.repo = repo
        else:
            self.sessions.append(Session(sid, repo, cwd, pid, state, now, remote, container))

    # --------------------------------------------------------------- moments

    def _start_moment(self, kind, now):
        self._pending_moment = False
        critter = "charlie" if self.rng() < 0.5 else "lily"
        self.moment = {
            "kind": kind, "critter": critter, "started": now,
            "repo": self._pending_moment_repo, "duration": MOMENT_DURATION[kind],
        }
        log(f"moment: {kind} ({critter}) for {self._pending_moment_repo}")
        self._moment_end_at = now + MOMENT_DURATION[kind]

    # ----------------------------------------------------------------- timers

    def tick(self):
        """Advance every deadline. Call often (the main loop does, 10x a second)."""
        with self.lock:
            now = self.clock()
            if self._narr_clear_at is not None and now >= self._narr_clear_at:
                self.narration = ""
                self._narr_clear_at = None
            if self._briefing_clear_at is not None and now >= self._briefing_clear_at:
                was_sad = bool(self.briefing and self.briefing["sad"])
                self.briefing = None
                self._briefing_clear_at = None
                log("briefing cleared")
                if self._pending_moment:
                    self._start_moment("sad" if was_sad else "star", now)
            if self._moment_fallback_at is not None and now >= self._moment_fallback_at:
                self._moment_fallback_at = None
                if self._pending_moment and self.briefing is None:
                    self._start_moment("star", now)
            if self._moment_end_at is not None and now >= self._moment_end_at:
                self.moment = None
                self._moment_end_at = None
            if self._toast_clear_at is not None and now >= self._toast_clear_at:
                self.toast = None
                self._toast_clear_at = None
            if now - self._last_reap >= REAP_INTERVAL:
                self._last_reap = now
                self._reap(now)
            self._update_narration(now)

    def _reap(self, now):
        """Drop sessions whose claude process is gone (crash, killed terminal)."""
        kept = []
        for s in self.sessions:
            if s.pid > 0 and not self.alive(s.pid):
                log(f"reaped dead session: {s.repo} [{short(s.id)}]")
                continue
            kept.append(s)
        self.sessions = kept
        # Backstop in case the briefing deadline got lost.
        if self.briefing and now - self.briefing["started"] > self.briefing["duration"] + 10:
            self.briefing = None
            self._briefing_clear_at = None

    def restore(self, path=STATE_PATH):
        """A restart (an update, a config change) must not forget the sessions
        that are running: idle ones send no event until their next turn.
        Take them back from the last published state while their claude
        process lives."""
        try:
            with open(path) as f:
                saved = json.load(f).get("sessions") or []
        except (OSError, ValueError, AttributeError):
            return 0
        n = 0
        with self.lock:
            for d in saved:
                if not isinstance(d, dict):
                    continue
                pid = d.get("pid")
                sid = d.get("id") or ""
                if not sid or not isinstance(pid, int) or pid <= 0 or not self.alive(pid) or self._find(sid):
                    continue
                state = d.get("state") if d.get("state") in ("working", "waiting", "done") else "done"
                s = Session(sid, d.get("repo") or "?", d.get("cwd") or "", pid, state,
                            float(d.get("since") or self.clock()), bool(d.get("remote")), d.get("container") or "")
                s.last_briefing = d.get("last_briefing")
                self.sessions.append(s)
                n += 1
        if n:
            log(f"restored {n} running session(s)")
        return n

    def adopt_existing(self):
        """Daemon restarts lose in-memory state, which would orphan running
        sessions. Adopt every cc-* tmux pane running claude; a real hook event
        for the same pid later replaces the placeholder."""
        with self.lock:
            out, code = self.run(["tmux", "list-panes", "-a", "-F",
                                  "#{session_name}\t#{pane_pid}\t#{pane_current_path}\t#{pane_current_command}"])
            log(f"adopt scan: code={code} lines={len(out.splitlines())}")
            now = self.clock()
            for line in out.splitlines():
                p = line.split("\t")
                if len(p) != 4 or not p[0].startswith("cc-") or p[3] not in ("claude", "node") or not p[1].isdigit():
                    continue
                pid = int(p[1])
                if any(s.pid == pid for s in self.sessions):
                    continue
                cwd = p[2]
                self.sessions.append(Session(f"tmux-{pid}", os.path.basename(cwd.rstrip("/")) or "?",
                                             cwd, pid, "done", now))
                log(f"adopted existing session {p[0]} (pid {pid})")

    def flash(self, msg):
        with self.lock:
            self.toast = msg
            self._toast_clear_at = self.clock() + TOAST_SECONDS
            log(f"toast: {msg}")

    # ---------------------------------------------------------------- publish

    def snapshot(self):
        """The renderer-facing state. Time-derived values (elapsed) are left
        to the renderer, which gets the daemon's clock in "t"."""
        with self.lock:
            now = self.clock()
            state, label = self.pill_state()
            return {
                "v": self.version,
                "t": now,
                "pill": {"state": state, "label": label, "narration": self.narration},
                "sessions": [s.to_json() for s in self.sessions],
                "briefing": dict(self.briefing) if self.briefing else None,
                "moment": dict(self.moment) if self.moment else None,
                "voice": {
                    "name": self.config.name,
                    "muted": self.voice_muted(),
                    "available": self.voice_available(),
                },
                "toast": self.toast,
                "hotkey": self.config.hotkey,
                "alfred": self.alfred.snapshot() if self.alfred else None,
            }

    def publish_if_changed(self, path=STATE_PATH):
        """Write state.json atomically when anything but the clock changed."""
        with self.lock:
            snap = self.snapshot()
            sig = json.dumps({k: v for k, v in snap.items() if k not in ("t", "v")}, sort_keys=True)
            if sig == self._last_signature:
                return False
            self._last_signature = sig
            self.version += 1
            snap["v"] = self.version
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                tmp = f"{path}.tmp-{os.getpid()}"
                with open(tmp, "w") as f:
                    json.dump(snap, f)
                os.replace(tmp, path)
            except OSError as e:
                log(f"ERROR: cannot write state: {e}")
            return True

    # ---------------------------------------------------------------- actions

    def voice_python(self):
        return os.path.join(self.config.speaker, ".venv", "bin", "python")

    def voice_available(self):
        return os.path.exists(self.voice_python())

    def voice_muted(self):
        return os.path.exists(os.path.join(self.config.speaker, ".off"))

    def toggle_mute(self):
        off = os.path.join(self.config.speaker, ".off")
        with self.lock:
            if os.path.exists(off):
                try:
                    os.remove(off)
                except OSError:
                    pass
                log("voice unmuted")
                return False
            try:
                open(off, "a").close()
            except OSError:
                pass
            self.stop_speech()
            log("voice muted")
            return True

    def speak(self, text):
        """Say `text` in the voice now, ahead of anything waiting (an answer
        to something the user asked)."""
        if text and self.voice_available():
            return self.spawn([self.voice_python(), os.path.join(self.config.speaker, "say.py"), text])
        return False

    def log_line(self, msg):
        log(msg)

    def stop_speech(self):
        # The bloom and the card's stop button end with the voice.
        with self.lock:
            self.briefing = None
            self._briefing_clear_at = None
            self._pending_moment = False
            self._moment_fallback_at = None
        if self.voice_available():
            self.run([self.voice_python(), os.path.join(self.config.speaker, "say.py"), "--stop"], timeout=5)
        else:
            self.run(["pkill", "-f", "say-[0-9]+\\.wav"], timeout=5)

    def in_container(self, container, args):
        """`args` as a command line that runs where the session lives: as is
        on the host, through `lxc exec` for a session in an LXD container."""
        if not container:
            return list(args)
        uid = self.config.container_users.get(container)
        user = ["--user", str(uid)] if uid else []
        return [self.config.lxc_bin, "exec", container] + user + ["--"] + list(args)

    def tmux(self, container, *args):
        return self.run(self.in_container(container, ["tmux"] + list(args)))

    def tmux_pane(self, cwd, container="", pid=0):
        """(pane_id, session_name) of the pane a session runs in, or None.

        By process first: the pane whose process is the session's claude or
        one of its ancestors. A session's cwd moves when it cds into a
        subdirectory, and two sessions can share one, so the directory is
        only the fallback, for sessions with no known pid."""
        out, code = self.tmux(container, "list-panes", "-a", "-F",
                              "#{pane_id}\t#{session_name}\t#{pane_current_path}\t#{pane_pid}")
        if code != 0:
            return None
        panes = [p for p in (line.split("\t") for line in out.splitlines()) if len(p) == 4]
        if pid > 0:
            mine = self.ancestors(pid, depth=1 if container else 0)
            for p in panes:
                if p[3].isdigit() and int(p[3]) in mine:
                    return p[0], p[1]
        for p in panes:
            if p[2] == cwd:
                return p[0], p[1]
        return None

    def recap(self, sid):
        s = self._find(sid)
        if s is None:
            return False
        if not self.voice_available():
            self.flash("Voice system not found")
            return False
        say = os.path.join(self.config.speaker, "say.py")
        if s.last_briefing:
            log(f"recap: {s.repo}: {s.last_briefing[:50]}")
            return self.spawn([self.voice_python(), say, "--sid", s.id, s.last_briefing])
        # Fall back to the global last briefing from the voice log.
        _, code = self.run(["bash", os.path.join(self.config.speaker, "pillctl"), "last"])
        if code == 0:
            log("recap fallback via pillctl")
        return code == 0

    PLACE_EDGES = ("top", "bottom", "left", "right")
    PLACE_ALIGNS = ("start", "center", "end")

    def place(self, edge, align):
        """Move the widget to a panel edge/position (the widget's Placement
        settings page). Runs linux/bin/cc-pill-place detached: it may restart
        plasmashell, which would take this request's caller with it."""
        if edge not in self.PLACE_EDGES or align not in self.PLACE_ALIGNS:
            return False
        script = os.path.join(INSTALL_DIR, "linux", "bin", "cc-pill-place")
        if not os.path.exists(script):
            self.flash("cc-pill-place not found")
            return False
        log(f"place: {edge} {align}")
        self.flash("Moving the widget…")
        return self.spawn([sys.executable, script, "--edge", edge, "--align", align])

    def send_prompt(self, sid, text):
        s = self._find(sid)
        t = (text or "").strip()
        if s is None or not t:
            return False
        pane = self.tmux_pane(s.cwd, s.container, s.pid)
        if not pane:
            self.flash(f"No tmux session for {s.repo}")
            log(f"sendPrompt FAILED, no pane for {s.cwd}")
            return False
        _, a = self.tmux(s.container, "send-keys", "-t", pane[0], "-l", t)
        _, b = self.tmux(s.container, "send-keys", "-t", pane[0], "Enter")
        ok = a == 0 and b == 0
        log(f"sendPrompt to {pane[0]} ({s.repo}) ok={ok}: {t[:60]}")
        if ok:
            self.flash(f"Sent to {s.repo}")
        return ok


# -------------------------------------------------------------- event drain

def drain_events(store, directory=EVENTS_DIR):
    """Apply and delete every event file, oldest first. Returns the count."""
    try:
        names = sorted(n for n in os.listdir(directory) if n.endswith(".json"))
    except OSError:
        return 0
    count = 0
    for name in names:
        path = os.path.join(directory, name)
        try:
            with open(path) as f:
                evt = json.load(f)
            store.apply(evt)
            count += 1
        except (OSError, ValueError):
            pass
        try:
            os.remove(path)
        except OSError:
            pass
    return count


# ------------------------------------------------------------------- HTTP

MAX_BODY = 64 * 1024


TOKEN_HEADER = "X-CC-Pill-Token"


def make_handler(store, bridge=False):
    """The API handler. With bridge=True it is the listener on the LXD bridge:
    it answers nothing but POST /event, and only with a container's token."""
    class Handler(BaseHTTPRequestHandler):
        server_version = "ccpilld/1.0"
        timeout = 5   # a client that opens a connection and sends nothing is dropped
        # HTTP/1.0: one request per connection, so a refused request whose
        # body was never read can't bleed into the next one.

        def log_message(self, fmt, *args):   # keep the journal quiet
            pass

        # Browser pages must never be able to drive the pill. Any request a
        # browser can send cross-origin carries an Origin header: refuse it.
        # Requiring a custom header turns everything else into a CORS
        # preflight, which is never answered (no Access-Control-* headers).
        def _guard(self):
            if self.headers.get("Origin") is not None:
                self._send(403, {"error": "cross-origin requests are not allowed"})
                return False
            if self.headers.get(API_HEADER) is None:
                self._send(403, {"error": f"missing {API_HEADER} header"})
                return False
            return True

        def _send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return None
            if n < 0 or n > MAX_BODY:
                return None
            raw = self.rfile.read(n) if n else b""
            if not raw:
                return {}
            try:
                obj = json.loads(raw)
            except ValueError:
                return None
            return obj if isinstance(obj, dict) else None

        def do_OPTIONS(self):
            self._send(403, {"error": "preflight refused"})

        def do_GET(self):
            if not self._guard():
                return
            if bridge:
                self._send(404, {"error": "not found"})
                return
            if self.path.split("?")[0] == "/state":
                self._send(200, store.snapshot())
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._guard():
                return
            route = self.path.split("?")[0]
            if bridge:
                self._container_event(route)
                return
            body = self._body()
            if body is None:
                self._send(400, {"error": "bad body"})
                return
            sid = str(body.get("sid") or "")
            text = body.get("text")
            text = text if isinstance(text, str) else ""
            if route == "/llm/warm":
                # The voice worker, before a briefing: start the local model,
                # or keep it from being stopped as idle.
                r = store.alfred.router if store.alfred else None
                if r is None or not r.cmd:
                    self._send(200, {"ok": False})
                    return
                threading.Thread(target=r.warm, daemon=True).start()
                self._send(200, {"ok": True})
                return
            if route.startswith("/alfred/"):
                a = store.alfred
                if a is None:
                    self._send(404, {"error": "not found"})
                    return
                pid = str(body.get("id") or "")
                if route == "/alfred/summon":
                    ok = a.summon()
                elif route == "/alfred/ask":
                    ok = a.ask(text)
                elif route == "/alfred/listen":
                    ok = a.listen(body.get("on") is True)
                elif route == "/alfred/confirm":
                    ok = a.confirm(pid)
                elif route == "/alfred/cancel":
                    ok = a.cancel(pid)
                else:
                    self._send(404, {"error": "not found"})
                    return
            elif route == "/recap":
                ok = store.recap(sid)
            elif route == "/prompt":
                ok = store.send_prompt(sid, text)
            elif route == "/mute":
                self._send(200, {"ok": True, "muted": store.toggle_mute()})
                return
            elif route == "/place":
                ok = store.place(body.get("edge"), body.get("align"))
            elif route == "/stop":
                store.stop_speech()
                ok = True
            else:
                self._send(404, {"error": "not found"})
                return
            self._send(200, {"ok": bool(ok)})

        def _container_event(self, route):
            if route != "/event":
                self._send(404, {"error": "not found"})
                return
            body = self._body()
            if body is None:
                self._send(400, {"error": "bad body"})
                return
            container = str(body.get("container") or "")
            expected = store.config.containers.get(container)
            token = self.headers.get(TOKEN_HEADER) or ""
            if not expected or not hmac.compare_digest(token.encode(), expected.encode()):
                self._send(403, {"error": "unknown container or bad token"})
                return
            store.apply_container(container, body.get("event"))
            self._send(200, {"ok": True})

    return Handler


def serve(store, port, host="127.0.0.1", bridge=False):
    httpd = ThreadingHTTPServer((host, port), make_handler(store, bridge))
    httpd.daemon_threads = True
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd


def serve_bridge(store, config, sleeper=time.sleep):
    """The container listener on the LXD bridge address. The bridge can come
    up long after us at login (snap LXD is slow), so keep trying in the
    background, less often as time goes on."""
    holder = {}

    def bind():
        wait, i = 2.0, 0
        while True:
            try:
                holder["httpd"] = serve(store, config.port, config.bridge_host, bridge=True)
                log(f"listening for containers on {config.bridge_host}:{config.port} "
                    f"({', '.join(sorted(config.containers))})")
                return
            except OSError as e:
                if i == 0 or i % 20 == 0:
                    log(f"bridge {config.bridge_host}:{config.port} not bindable yet: {e}")
                i += 1
                sleeper(wait)
                wait = min(wait * 1.5, 30.0)

    threading.Thread(target=bind, daemon=True).start()

    class Handle:
        def shutdown(self):
            if "httpd" in holder:
                holder["httpd"].shutdown()
    return Handle()


# ------------------------------------------------------------------- main

def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if "--version" in argv:
        print("ccpilld 1.0")
        return 0
    os.makedirs(EVENTS_DIR, exist_ok=True)
    config = Config.load()
    store = Store(config)
    import alfred as alfred_mod
    store.alfred = alfred_mod.Alfred(store, config, router=alfred_mod.Router(
        config.alfred_llm_url, config.alfred_llm_cmd,
        idle=config.alfred_llm_idle, log_path=os.path.join(HOME, "alfred", "llm.log"), log=log),
        data_dir=os.path.join(HOME, "alfred"))
    log(f"ccpilld starting (pid {os.getpid()}, data {HOME})")
    try:
        httpd = serve(store, config.port)
    except OSError as e:
        log(f"ERROR: cannot bind 127.0.0.1:{config.port}: {e}")
        print(f"ccpilld: cannot bind 127.0.0.1:{config.port}: {e}", file=sys.stderr)
        return 1
    log(f"listening on 127.0.0.1:{config.port}")
    store.restore()
    bridge = None
    if config.bridge_host and config.containers:
        bridge = serve_bridge(store, config)
    store.adopt_existing()
    log(f"watching {EVENTS_DIR}")

    stop = threading.Event()

    def on_signal(signum, frame):
        stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    while not stop.is_set():
        drain_events(store)
        store.tick()
        store.alfred.tick()
        store.publish_if_changed()
        stop.wait(0.1)

    if store.alfred.router:
        store.alfred.router.idle = -1
        store.alfred.router.tick()      # stop the model server we started
    httpd.shutdown()
    if bridge:
        bridge.shutdown()
    log("ccpilld stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
