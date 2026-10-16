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
    what the newest working session is doing, reaps dead sessions, garbage
    collects idle pill-launched tmux sessions
  * runs the briefing bloom and the critter moments on the same timings
  * performs the card's actions: replay briefing, open terminal, send a
    prompt to a session, launch a hands-free session, mute, stop speech

Run it under a systemd user service (linux/setup.sh does this). Set
CC_PILL_HOME to use a different data directory (tests do).
"""
import errno
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

SAD_RE = re.compile(r"fail(ed|ing)?|error|broke|broken|couldn.t|didn.t work|crash", re.I)

# How each terminal takes a command to run. Unknown terminals get "-e".
TERMINAL_EXEC = {
    "konsole": ["konsole", "-e"],
    "kitty": ["kitty"],
    "alacritty": ["alacritty", "-e"],
    "wezterm": ["wezterm", "start", "--"],
    "ghostty": ["ghostty", "-e"],
    "foot": ["foot"],
    "gnome-terminal": ["gnome-terminal", "--"],
    "xterm": ["xterm", "-e"],
}


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
        self.home_repo = os.path.expanduser(data.get("home_repo") or os.path.expanduser("~"))
        self.pill_system_prompt = data.get("pill_system_prompt") or ""
        self.permission_mode = data.get("permission_mode") or "acceptEdits"
        # On Linux this is a terminal command (konsole, kitty, ...), not a bundle id.
        self.terminal = data.get("terminal") or "konsole"
        self.hotkey = data.get("hotkey") or "meta+alt+m"
        self.claude_bin = data.get("claude_bin") or find_claude()
        gc = data.get("pill_gc_minutes", 30)
        self.pill_gc_minutes = float(gc) if isinstance(gc, (int, float)) else 30.0
        port = data.get("daemon_port", DEFAULT_PORT)
        self.port = int(port) if isinstance(port, int) and 1024 <= port <= 65535 else DEFAULT_PORT

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


def find_claude():
    for p in (os.path.expanduser("~/.local/bin/claude"), "/usr/local/bin/claude", "/usr/bin/claude"):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("claude") or "claude"


# -------------------------------------------------------------- processes

def run(args, timeout=8):
    """Run a command, returning (stdout+stderr, exit code). Never raises.

    Under systemd the PATH can be bare: add the usual user bin dirs. tmux
    sanitizes control-char separators without a UTF-8 locale, so make sure
    one is set.
    """
    env = dict(os.environ)
    extra = os.path.expanduser("~/.local/bin") + ":/usr/local/bin"
    env["PATH"] = extra + ":" + env.get("PATH", "/usr/bin:/bin")
    if not env.get("LANG"):
        env["LANG"] = "C.UTF-8"
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
        return p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        return (e.stdout or "") if isinstance(e.stdout, str) else "", -1
    except (OSError, ValueError):
        return "", -1


def spawn(args, cwd=None):
    """Start a detached process (never waits, never raises)."""
    try:
        subprocess.Popen(args, cwd=cwd, stdin=subprocess.DEVNULL,
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


# ------------------------------------------------------------------ model

class Session:
    __slots__ = ("id", "repo", "cwd", "pid", "state", "since", "activity",
                 "activity_at", "last_briefing", "remote")

    def __init__(self, sid, repo, cwd, pid, state, since, remote=False):
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

    def to_json(self):
        return {
            "id": self.id, "repo": self.repo, "cwd": self.cwd, "pid": self.pid,
            "state": self.state, "since": self.since, "activity": self.activity,
            "activity_at": self.activity_at, "last_briefing": self.last_briefing,
            "remote": self.remote,
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
                 alive=pid_alive, rng=random.random, sleeper=time.sleep):
        self.config = config
        self.clock = clock
        self.run = runner
        self.spawn = spawner
        self.alive = alive
        self.rng = rng
        self.sleep = sleeper
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
            self._apply(evt)

    def _apply(self, evt):
        if not isinstance(evt, dict):
            return
        now = self.clock()
        typ = evt.get("type") or ""
        sid = evt.get("sid") or ""
        repo = evt.get("repo") or "?"
        cwd = evt.get("cwd") or ""
        pid = evt.get("pid") or 0
        pid = int(pid) if isinstance(pid, (int, float)) else 0
        remote = bool(evt.get("remote", False))

        if typ == "start":
            self._upsert(sid, repo, cwd, pid, remote, "done", now)
            log(f"session start: {repo} [{short(sid)}]")
        elif typ == "prompt":
            self._upsert(sid, repo, cwd, pid, remote, "working", now)
            log(f"working: {repo} [{short(sid)}]")
        elif typ == "stop":
            s = self._find(sid)
            was_working = s is not None and s.state == "working"
            self._upsert(sid, repo, cwd, pid, remote, "done", now)
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
                return
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
                self._upsert(sid, repo, cwd, pid, remote, "working", now)
                s = self._find(sid)
                if s is not None:
                    s.activity = label
                    s.activity_at = now
        elif typ == "notify":
            if evt.get("idle"):
                log(f"idle nag ignored: {repo}")
            else:
                self._upsert(sid, repo, cwd, pid, remote, "waiting", now)
                log(f"waiting: {repo} [{short(sid)}]")
        elif typ == "end":
            self.sessions = [s for s in self.sessions if s.id != sid]
            log(f"session end: {repo} [{short(sid)}]")
        elif typ == "briefing":
            text = evt.get("text") or ""
            if not isinstance(text, str) or not text:
                return
            silent = bool(evt.get("silent", False))
            duration = evt.get("duration") or 0
            duration = float(duration) if isinstance(duration, (int, float)) else 0.0
            if duration <= 0:
                duration = min(6.0, len(text.split()) * 0.3)
            sad = SAD_RE.search(text) is not None
            self._moment_fallback_at = None  # moment now plays after the bloom
            self.briefing = {
                "text": text, "duration": duration, "silent": silent,
                "started": now, "repo": repo, "sad": sad,
            }
            s = self._find(sid) if sid else None
            if s is not None:
                s.last_briefing = text
            how = "silent" if silent else f"{duration:.1f}s"
            log(f"briefing ({how}): {text[:60]}")
            self._briefing_clear_at = now + duration + BRIEFING_TAIL

    def _find(self, sid):
        for s in self.sessions:
            if s.id == sid:
                return s
        return None

    def _upsert(self, sid, repo, cwd, pid, remote, state, now):
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
            self.sessions.append(Session(sid, repo, cwd, pid, state, now, remote))

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
        self._gc_pill_sessions(now)

    def _gc_pill_sessions(self, now):
        """Pill-launched tmux sessions that finished and sat idle get cleaned
        up: done, detached, and untouched past the configured window. Only
        names containing "-pill" are ever touched."""
        window = self.config.pill_gc_minutes * 60
        if window <= 0:
            return
        stale = {s.pid for s in self.sessions if s.state == "done" and now - s.since > window}
        if not stale:
            return
        out, _ = self.run(["tmux", "list-panes", "-a", "-F",
                           "#{session_name}\x01#{session_attached}\x01#{pane_pid}"])
        for line in out.splitlines():
            p = line.split("\x01")
            if len(p) != 3 or "-pill" not in p[0] or p[1] != "0" or not p[2].isdigit():
                continue
            if int(p[2]) in stale:
                self.run(["tmux", "kill-session", "-t", p[0]])
                log(f"gc: killed idle pill session {p[0]}")

    def adopt_existing(self):
        """Daemon restarts lose in-memory state, which would orphan running
        sessions. Adopt every cc-* tmux pane running claude; a real hook event
        for the same pid later replaces the placeholder."""
        with self.lock:
            out, code = self.run(["tmux", "list-panes", "-a", "-F",
                                  "#{session_name}\x01#{pane_pid}\x01#{pane_current_path}\x01#{pane_current_command}"])
            log(f"adopt scan: code={code} lines={len(out.splitlines())}")
            now = self.clock()
            for line in out.splitlines():
                p = line.split("\x01")
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

    def stop_speech(self):
        if self.voice_available():
            self.run([self.voice_python(), os.path.join(self.config.speaker, "say.py"), "--stop"], timeout=5)
        else:
            self.run(["pkill", "-f", "say-[0-9]+\\.wav"], timeout=5)

    def tmux_pane(self, cwd):
        """(pane_id, session_name) for a session's cwd, or None."""
        out, code = self.run(["tmux", "list-panes", "-a", "-F",
                              "#{pane_id}\x01#{session_name}\x01#{pane_current_path}"])
        if code != 0:
            return None
        for line in out.splitlines():
            p = line.split("\x01")
            if len(p) == 3 and p[2] == cwd:
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
            return self.spawn([self.voice_python(), say, s.last_briefing])
        # Fall back to the global last briefing from the voice log.
        _, code = self.run(["bash", os.path.join(self.config.speaker, "pillctl"), "last"])
        if code == 0:
            log("recap fallback via pillctl")
        return code == 0

    def terminal_command(self, tail):
        """Command line that opens the configured terminal running `tail`."""
        term = self.config.terminal.strip() or "konsole"
        if not tail:
            return [term]
        known = TERMINAL_EXEC.get(os.path.basename(term))
        # Keep the user's spelling (it may be a full path); take the flags.
        flags = known[1:] if known is not None else ["-e"]
        return [term] + flags + tail

    def open_terminal(self, sid):
        s = self._find(sid)
        if s is None:
            return False
        pane = self.tmux_pane(s.cwd)
        if pane:
            _, sess = pane
            clients, _ = self.run(["tmux", "list-clients", "-F", "#{client_name}"])
            names = [c for c in clients.splitlines() if c.strip()]
            if names:
                self.run(["tmux", "switch-client", "-c", names[0], "-t", sess])
                log(f"switched client {names[0]} to {sess}")
                self._activate_terminal()
                return True
            log(f"no attached tmux client; opening {self.config.terminal} on {sess}")
            return self.spawn(self.terminal_command(["tmux", "attach", "-t", sess]), cwd=s.cwd or None)
        log(f"no tmux pane for {s.cwd}; focusing the terminal")
        if not self._activate_terminal():
            return self.spawn(self.terminal_command([]), cwd=s.cwd or None)
        return True

    def _activate_terminal(self):
        """Raise an existing terminal window (kdotool on KWin, xdotool on X11)."""
        term = os.path.basename(self.config.terminal)
        if shutil.which("kdotool"):
            out, code = self.run(["kdotool", "search", "--class", term])
            ids = [w for w in out.split() if w]
            if code == 0 and ids:
                self.run(["kdotool", "windowactivate", ids[0]])
                return True
        if shutil.which("xdotool") and os.environ.get("DISPLAY"):
            out, code = self.run(["xdotool", "search", "--class", term])
            ids = [w for w in out.split() if w]
            if code == 0 and ids:
                self.run(["xdotool", "windowactivate", ids[-1]])
                return True
        return False

    def send_prompt(self, sid, text):
        s = self._find(sid)
        t = (text or "").strip()
        if s is None or not t:
            return False
        pane = self.tmux_pane(s.cwd)
        if not pane:
            self.flash(f"No tmux session for {s.repo}")
            log(f"sendPrompt FAILED, no pane for {s.cwd}")
            return False
        _, a = self.run(["tmux", "send-keys", "-t", pane[0], "-l", t])
        _, b = self.run(["tmux", "send-keys", "-t", pane[0], "Enter"])
        ok = a == 0 and b == 0
        log(f"sendPrompt to {pane[0]} ({s.repo}) ok={ok}: {t[:60]}")
        if ok:
            self.flash(f"Sent to {s.repo}")
        return ok

    def launch_session(self, prompt, wait=True):
        """Start a fresh Claude session in the home repo, detached in tmux,
        and deliver the prompt once the TUI is ready. Hooks then track it, the
        pill narrates it, the voice briefs it."""
        prompt = (prompt or "").strip()
        if not prompt:
            log("ask: empty, dropped")
            return False
        self.flash(f"Starting: {prompt[:34]}…")
        t = threading.Thread(target=self._launch, args=(prompt,), daemon=True)
        t.start()
        if wait:
            t.join()
        return True

    def _launch(self, prompt):
        cfg = self.config
        repo_name = os.path.basename(cfg.home_repo.rstrip("/")) or "home"
        name = f"cc-{repo_name}-pill"
        n = 2
        while self.run(["tmux", "has-session", "-t", f"={name}"])[1] == 0:
            name = f"cc-{repo_name}-pill-{n}"
            n += 1
        cmd = [cfg.claude_bin]
        if cfg.permission_mode == "bypass":
            cmd.append("--dangerously-skip-permissions")
        elif cfg.permission_mode == "default":
            pass
        else:
            cmd += ["--permission-mode", "acceptEdits"]
        if cfg.pill_system_prompt:
            cmd += ["--append-system-prompt", cfg.pill_system_prompt]
        out, code = self.run(["tmux", "new-session", "-d", "-s", name, "-c", cfg.home_repo] + cmd)
        if code != 0:
            self.flash("Couldn't start the session")
            log(f"launch FAILED: {out[:120]}")
            return
        # Wait for the input box before typing into it. Bypass mode shows an
        # acceptance dialog first: answer it, then wait for the ready screen.
        ready = False
        accepted = False
        for _ in range(40):   # up to 20 s
            self.sleep(0.5)
            if self.run(["tmux", "has-session", "-t", f"={name}"])[1] != 0:
                break
            pane, _ = self.run(["tmux", "capture-pane", "-t", name, "-p"])
            if not accepted and "Yes, I accept" in pane:
                self.run(["tmux", "send-keys", "-t", name, "2"])
                self.sleep(0.3)
                self.run(["tmux", "send-keys", "-t", name, "Enter"])
                accepted = True
                continue
            if "shift+tab to cycle" in pane or "? for shortcuts" in pane:
                ready = True
                break
        self.sleep(0.6)
        _, a = self.run(["tmux", "send-keys", "-t", name, "-l", prompt])
        _, b = self.run(["tmux", "send-keys", "-t", name, "Enter"])
        log(f"launched {name} ready={ready} sent={a == 0 and b == 0}: {prompt[:60]}")


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


def make_handler(store):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ccpilld/1.0"
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
            if self.path.split("?")[0] == "/state":
                self._send(200, store.snapshot())
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._guard():
                return
            route = self.path.split("?")[0]
            body = self._body()
            if body is None:
                self._send(400, {"error": "bad body"})
                return
            sid = str(body.get("sid") or "")
            text = body.get("text")
            text = text if isinstance(text, str) else ""
            if route == "/ask":
                ok = store.launch_session(text, wait=False)
            elif route == "/recap":
                ok = store.recap(sid)
            elif route == "/terminal":
                ok = store.open_terminal(sid)
            elif route == "/prompt":
                ok = store.send_prompt(sid, text)
            elif route == "/mute":
                self._send(200, {"ok": True, "muted": store.toggle_mute()})
                return
            elif route == "/stop":
                store.stop_speech()
                ok = True
            else:
                self._send(404, {"error": "not found"})
                return
            self._send(200, {"ok": bool(ok)})

    return Handler


def serve(store, port, host="127.0.0.1"):
    httpd = ThreadingHTTPServer((host, port), make_handler(store))
    httpd.daemon_threads = True
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd


# ------------------------------------------------------------------- main

def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if "--version" in argv:
        print("ccpilld 1.0")
        return 0
    os.makedirs(EVENTS_DIR, exist_ok=True)
    config = Config.load()
    store = Store(config)
    log(f"ccpilld starting (pid {os.getpid()}, data {HOME})")
    try:
        httpd = serve(store, config.port)
    except OSError as e:
        log(f"ERROR: cannot bind 127.0.0.1:{config.port}: {e}")
        print(f"ccpilld: cannot bind 127.0.0.1:{config.port}: {e}", file=sys.stderr)
        return 1
    log(f"listening on 127.0.0.1:{config.port}")
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
        store.publish_if_changed()
        stop.wait(0.1)

    httpd.shutdown()
    log("ccpilld stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
