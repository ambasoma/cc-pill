"""Alfred: the assistant side of the pill.

The hotkey opens the card on an "Ask Alfred" box. You type a request, or
hold Space and say it (recorded with pw-record, turned into text by a local
Whisper). Alfred then:

  * briefs you on all sessions ("what's going on?"), from the state the
    daemon already has: no model call
  * tells you about one session ("how is todo-app doing?")
  * passes a message to one session ("tell the waiting todo-app to keep
    fail-fast"), always after you confirm, through the same tmux path as
    the card's send-a-prompt
  * answers other questions about the sessions in a sentence

Only routing needs a model: which of these you want, which session, what
to send. It runs on the local Gemma server (llama.cpp, started on demand,
stopped when idle); nothing goes to a cloud model. The model can only choose;
Alfred composes every sentence he says, and nothing is sent without your
yes. Stdlib only.
"""
import json
import os
import re
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request

LOCAL_AI = os.path.expanduser("~/.local/opt/local-ai")

YES = re.compile(r"^\W*(yes|yeah|yep|yup|sure|ok(ay)?|send( it)?|do it|go( ahead)?|confirm(ed)?|correct)\b", re.I)
NO = re.compile(r"^\W*(no|nope|cancel|don'?t|stop|never ?mind|forget it)\b", re.I)
BRIEF = re.compile(r"what(?:'s| is|s) (going on|happening|up|new)|\bstatus\b|\bbrief\b|catch me up"
                   r"|update me|give me an update|how are (things|my sessions|we doing|the sessions)"
                   r"|\boverview\b|anything (new|for me)|where are we|what did i miss", re.I)
# Whisper marks silence and noise like this; they are not words.
WHISPER_NOISE = re.compile(r"\[[^\]]*\]|\([^)]*\)")

LISTEN_MAX = 20.0          # seconds of recording before Alfred stops listening himself
PENDING_TTL = 120.0        # a send waits this long for your yes
LOCAL_WAIT = 30.0          # how long a request waits for the local model to load

# Kept small: the local model writes about 13 tokens a second.
ROUTE_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"type": "string", "enum": ["brief", "send", "detail", "answer"]},
        "n": {"type": "integer"},
        "text": {"type": "string"},
    },
    "required": ["intent", "n", "text"],
}


def plain(text):
    """Text that goes into the model's raw prompt, without the characters of
    its control markers (<|turn>, <turn|>, <|channel>): session news comes
    from the sessions, and must not fake a turn."""
    return re.sub(r"[<>|]", " ", text or "")


def spoken(name):
    """How a container's name is said: "web-dev" -> "web dev"."""
    return re.sub(r"[-_.]+", " ", name or "").strip()


def sentence(text):
    """`text` ending in one full stop, question or exclamation mark."""
    text = (text or "").strip()
    return text if text[-1:] in (".", "?", "!") else text + "."


def activity_words(act, clipped_at=44):
    """A session's activity label, fit to say: the hook clips labels at 44
    characters, so a label that long ends in half a word; drop it."""
    act = " ".join((act or "").split()).rstrip(" .;:,")
    if len(act) >= clipped_at - 1 and " " in act:
        act = act.rsplit(" ", 1)[0].rstrip(" .;:,")
    return act


def first_json(text):
    """The first JSON object in a model's answer."""
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def http_json(url, body=None, timeout=10.0):
    """GET (no body) or POST JSON; the decoded answer, or None."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except (OSError, ValueError, urllib.error.URLError):
        return None


class Router:
    """One routing decision, by the local Gemma server. Its process is this
    daemon's to start and stop; the voice worker uses it too (/llm/warm)."""

    def __init__(self, url, cmd, idle=900.0, http=http_json, popen=subprocess.Popen,
                 clock=time.time, sleeper=time.sleep, log_path=None, log=lambda msg: None):
        self.url = (url or "").rstrip("/")
        self.cmd = cmd
        self.idle = idle
        self.http = http
        self.popen = popen
        self.clock = clock
        self.sleep = sleeper
        self.log_path = log_path
        self.log = log
        self.template = {}          # system prompt -> (before, after) the request
        self.proc = None            # the server we started (we stop only that one)
        self.last_used = 0.0
        self.lock = threading.Lock()

    def healthy(self):
        return bool(self.url) and self.http(self.url + "/health", timeout=0.5) is not None

    def warm(self, system=None):
        """Get the local model ready while you type or talk (the hotkey calls
        this): start the server if it is not up, then send the session list
        once, so the GPU code is built and the long part of the prompt is
        cached before your request comes."""
        self.last_used = self.clock()
        with self.lock:
            if self.cmd and not (self.proc and self.proc.poll() is None) and not self.healthy():
                log = subprocess.DEVNULL
                if self.log_path:
                    try:
                        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
                        log = open(self.log_path, "ab")
                    except OSError:
                        log = subprocess.DEVNULL
                try:
                    self.proc = self.popen([self.cmd], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                           start_new_session=True)
                except OSError:
                    self.proc = None
        if system is None:
            return
        end = self.clock() + 30
        while not self.healthy():
            if not (self.proc and self.proc.poll() is None) or self.clock() > end:
                return
            self.sleep(0.25)
        prompt = self._prompt(system, "status")
        if prompt:
            self.http(self.url + "/completion", self._body(prompt, 1), timeout=30.0)

    def _prompt(self, system, request):
        """The raw prompt, in the model's own chat format (the server's
        template, asked once per session list)."""
        mark = "\x00REQUEST\x00"
        parts = self.template.get(system)
        if parts is None:
            out = self.http(self.url + "/apply-template", {
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": mark}],
                "chat_template_kwargs": {"enable_thinking": False}}, timeout=10.0)
            raw = out.get("prompt") if isinstance(out, dict) else None
            if not isinstance(raw, str) or raw.count(mark) != 1:
                return None
            parts = tuple(raw.split(mark))
            self.template = {system: parts}     # one session list at a time
        return parts[0] + plain(request) + parts[1]

    def _body(self, prompt, n_predict):
        # The plain completion route, with the JSON rule on from the first
        # token: Gemma 4 thinks before it answers in chat mode (whatever the
        # template is told) and spends seconds on it; here it cannot.
        # The object has no nested braces, so the first "}" ends it.
        return {"prompt": prompt, "json_schema": ROUTE_SCHEMA, "n_predict": n_predict,
                "temperature": 0.1, "cache_prompt": True, "stop": ["}"]}

    def tick(self):
        """Stop the server we started when nobody asked for a while: it holds
        about 3 GB of shared GPU memory."""
        with self.lock:
            if self.proc and self.proc.poll() is None and self.clock() - self.last_used > self.idle:
                try:
                    os.killpg(self.proc.pid, signal.SIGTERM)
                except OSError:
                    pass
                self.proc = None

    def route(self, system, request):
        self.last_used = start = self.clock()
        ready = self.healthy()
        if not ready:
            self.warm()                 # not up (stopped as idle, or never summoned): start it
        if not ready and self.proc and self.proc.poll() is None:
            end = self.clock() + LOCAL_WAIT
            while not ready and self.clock() < end:
                self.sleep(0.25)
                ready = self.healthy()
        if ready:
            prompt = self._prompt(system, request)
            out = self.http(self.url + "/completion", self._body(prompt, 60), timeout=20.0) if prompt else None
            content = out.get("content") if isinstance(out, dict) else None
            got = first_json(content if "}" in (content or "") else (content or "") + "}") if content else None
            if got:
                self.log(f"alfred: routed by the local model in {self.clock() - start:.1f}s")
                return got
        self.log("alfred: the local model could not route the request" if ready
                 else "alfred: no local model to route with")
        return None


class Alfred:
    def __init__(self, store, config, router=None, popen=subprocess.Popen, clock=time.time,
                 background=True, data_dir=None):
        self.store = store
        self.config = config
        self.router = router
        self.popen = popen
        self.clock = clock
        self.background = background
        self.data_dir = data_dir or os.path.expanduser("~/.cc-pill/alfred")
        self.lock = threading.Lock()
        self.summons = 0
        self.busy = False
        self.listening = False
        self.you = ""
        self.reply = ""
        self.pending = None         # {"id", "sid", "label", "text", "at"}
        self.recorder = None
        self.wav = None
        self.listen_until = 0.0
        self.dictating = None       # {"sid", "listening"}: a dictation being recorded or written down
        self.dictation = None       # {"sid", "text", "n"}: the last one written down
        self.dictations = 0

    # --------------------------------------------------------------- state

    def can_listen(self):
        c = self.config
        return bool(c.alfred_recorder and c.alfred_whisper_cli and c.alfred_whisper_model
                    and os.path.exists(c.alfred_whisper_cli) and os.path.exists(c.alfred_whisper_model))

    def snapshot(self):
        p = self.pending
        return {
            "summon": self.summons, "busy": self.busy, "listening": self.listening,
            "can_listen": self.can_listen(), "you": self.you, "reply": self.reply,
            "pending": {"id": p["id"], "sid": p["sid"], "label": p["label"], "text": p["text"]} if p else None,
            "dictating": self.dictating, "dictation": self.dictation,
        }

    def tick(self):
        if self.router:
            self.router.tick()
        if self.listening and self.clock() > self.listen_until:
            self.listen(False)
        d = self.dictating
        if d and d["listening"] and self.clock() > self.listen_until:
            self.dictate(d["sid"], False)
        p = self.pending
        if p and self.clock() - p["at"] > PENDING_TTL:
            self.pending = None

    # ------------------------------------------------------------- actions

    def summon(self):
        self.summons += 1
        self._warm()
        return True

    def _warm(self):
        if self.router:
            threading.Thread(target=lambda: self.router.warm(self.system_prompt(self.sessions())),
                             daemon=True).start()

    def ask(self, text):
        text = " ".join((text or "").split())[:1000]
        if not text:
            return False
        self.you, self.reply, self.busy = text, "", True
        self._run(self._answer, text)
        return True

    def confirm(self, pid):
        p = self.pending
        if not p or p["id"] != pid:
            return False
        self.pending = None
        ok = self.store.send_prompt(p["sid"], p["text"])
        self._say(f"Sent to {p['label']}." if ok else f"I couldn't reach {p['label']}.")
        return ok

    def cancel(self, pid):
        p = self.pending
        if not p or p["id"] != pid:
            return False
        self.pending = None
        self._say("Cancelled.")
        return True

    def listen(self, on):
        """Hold-to-talk: on starts the recording, off stops it and hands the
        words to ask()."""
        if on:
            if self.listening or self.dictating or not self._record():
                return False
            self.listening = True
            self._warm()
            return True
        if not self.listening:
            return False
        self.listening = False
        wav = self._stop_recording()
        self.busy = True
        self._run(self._transcribe_then_answer, wav)
        return True

    def dictate(self, sid, on):
        """Hold-to-talk into one session's prompt field: on starts the
        recording, off stops it and writes the words down as `dictation`
        for the card. No model reads them and nothing is sent: you check
        the text and press send."""
        if on:
            if (self.listening or self.dictating or not sid
                    or not any(s["id"] == sid for s in self.store.snapshot()["sessions"])
                    or not self._record()):
                return False
            self.dictating = {"sid": sid, "listening": True}
            return True
        d = self.dictating
        if not d or not d["listening"]:
            return False
        self.dictating = {"sid": d["sid"], "listening": False}
        wav = self._stop_recording()
        self._run(self._write_down, d["sid"], wav)
        return True

    # ------------------------------------------------------------ internals

    def _run(self, fn, *args):
        if self.background:
            threading.Thread(target=fn, args=args, daemon=True).start()
        else:
            fn(*args)

    def _record(self):
        """Start pw-record (or arecord) into a new WAV; False if it can't."""
        if not self.can_listen():
            return False
        os.makedirs(self.data_dir, exist_ok=True)
        self.wav = os.path.join(self.data_dir, f"heard-{time.time_ns()}.wav")
        rec = self.config.alfred_recorder
        args = ([rec, "--rate", "16000", "--channels", "1", "--format", "s16", self.wav]
                if os.path.basename(rec) == "pw-record"
                else [rec, "-q", "-f", "S16_LE", "-r", "16000", "-c", "1", self.wav])
        try:
            self.recorder = self.popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
        except OSError:
            self.recorder = self.wav = None
            return False
        self.stop_speech()
        self.listen_until = self.clock() + LISTEN_MAX
        return True

    def _stop_recording(self):
        """Stop the recorder; the WAV it wrote."""
        rec, wav = self.recorder, self.wav
        self.recorder = self.wav = None
        if rec:
            try:
                rec.send_signal(signal.SIGINT)   # pw-record and arecord finish the file on SIGINT
                rec.wait(timeout=3)
            except Exception:
                try:
                    rec.kill()
                except Exception:
                    pass
        return wav

    def _write_down(self, sid, wav):
        text = ""
        try:
            text = self._transcribe(wav)
        finally:
            self.dictating = None
        if not text:
            self.store.log_line("alfred: heard nothing to write down")
            return
        self.dictations += 1
        self.dictation = {"sid": sid, "text": text[:2000], "n": self.dictations}
        self.store.log_line(f"alfred: wrote down {len(text.split())} words for {sid}")

    def _transcribe(self, wav):
        """Whisper's text for a WAV, without its noise marks; the WAV is
        deleted."""
        text = ""
        try:
            c = self.config
            out, code = self.store.run([c.alfred_whisper_cli, "-m", c.alfred_whisper_model, "-t", "8",
                                        "-nt", "-np", "-f", wav], timeout=30,
                                       cwd=os.path.dirname(c.alfred_whisper_cli), stderr=False)
            if code == 0:
                text = " ".join(WHISPER_NOISE.sub(" ", out).split())
        finally:
            try:
                os.remove(wav)
            except (OSError, TypeError):
                pass
        return text

    def _transcribe_then_answer(self, wav):
        text = self._transcribe(wav)
        if not text:
            self.busy = False
            self._say("I didn't catch that.")
            return
        self.you = text
        self._answer(text)

    def sessions(self):
        """The sessions as the card orders them: needs you, working, done."""
        order = {"waiting": 0, "working": 1, "done": 2}
        ss = self.store.snapshot()["sessions"]
        return sorted(ss, key=lambda s: (order.get(s["state"], 3), s["since"]))

    def label(self, s, ss, tell_apart=True):
        """How a session is named aloud: its project, its container, and (to
        confirm a send) its state when another session shares the name. The
        briefing says each state anyway."""
        name = s["repo"]
        if s.get("container"):
            name += " in " + spoken(s["container"])
        if tell_apart and sum(1 for x in ss if x["repo"] == s["repo"] and x.get("container") == s.get("container")) > 1:
            name += ", the one that " + {"waiting": "needs you", "working": "is working"}.get(s["state"], "is done")
        return name

    def brief(self, ss):
        if not ss:
            return "No Claude sessions are running."
        parts = [f"{len(ss)} session{'s' if len(ss) != 1 else ''}."]
        done = [s for s in ss if s["state"] == "done"]
        for s in ss:
            if s["state"] == "waiting":
                why = s.get("last_briefing")
                parts.append(f"{self.label(s, ss, False)} needs you." + (" " + sentence(why) if why else ""))
            elif s["state"] == "working":
                act = activity_words(s.get("activity"))
                parts.append(f"{self.label(s, ss, False)} is working" + (f": {act}." if act else "."))
        if 0 < len(done) <= 2:
            parts += [f"{self.label(s, ss, False)} is done." for s in done]
        elif done:
            parts.append(f"{len(done)} others are done.")
        return " ".join(parts)

    def detail(self, s, ss):
        state = {"waiting": "needs you", "working": "is working", "done": "is done"}.get(s["state"], s["state"])
        line = f"{self.label(s, ss, False)} {state}"
        if s["state"] == "working" and activity_words(s.get("activity")):
            line += f": {activity_words(s['activity'])}"
        line += "."
        if s.get("last_briefing"):
            line += " Last: " + sentence(s["last_briefing"])
        return line

    def system_prompt(self, ss):
        rows = []
        for i, s in enumerate(ss, 1):
            where = f" (container {s['container']})" if s.get("container") else ""
            state = {"waiting": "needs the user", "working": "working", "done": "done"}.get(s["state"], s["state"])
            doing = f", doing: {s['activity']}" if s["state"] == "working" and s.get("activity") else ""
            last = f", last news: {s['last_briefing']}" if s.get("last_briefing") else ""
            rows.append(plain(f"{i}. {s['repo']}{where}: {state}{doing}{last}"))
        return ("You route one request from the user to their Claude Code sessions. The sessions, numbered:\n"
                + "\n".join(rows) + "\n\n"
                "intent is one of: brief (an overview of all sessions); send (pass a message to one session: "
                "n is its number, text is the instruction for that session, in the user's words, without "
                "the session's name); detail (about one session: n is its number, text is empty); answer "
                "(any other question about the sessions: text is the answer, at most 25 words, plain speech). "
                "If a send does not name a session clearly, choose the session that needs the user. Use 0 for "
                "n when no session fits.")

    def _answer(self, text):
        try:
            reply = self._route(text)
        except Exception as e:   # never leave the box spinning
            reply = "Something went wrong there."
            self.store.log_line(f"alfred: error: {e!r}")
        self.busy = False
        self._say(reply)

    def _route(self, text):
        ss = self.sessions()
        p = self.pending
        if p and YES.match(text):
            self.pending = None
            ok = self.store.send_prompt(p["sid"], p["text"])
            return f"Sent to {p['label']}." if ok else f"I couldn't reach {p['label']}."
        if p and NO.match(text):
            self.pending = None
            return "Cancelled."
        if not p and len(text.split()) <= 3 and (YES.match(text) or NO.match(text)):
            return "Nothing is waiting for a yes or no."
        if BRIEF.search(text) or not ss:
            return self.brief(ss)
        if not self.router or not self.router.cmd and not self.router.healthy():
            return "I can only give a briefing: there is no local model for the rest."
        got = self.router.route(self.system_prompt(ss), text)
        if got is None:
            return "The local model didn't answer. Try again in a moment."
        intent = got.get("intent")
        n = got.get("n") if isinstance(got.get("n"), int) else 0
        s = ss[n - 1] if 1 <= n <= len(ss) else None
        if intent == "brief":
            return self.brief(ss)
        if intent == "detail" and s:
            return self.detail(s, ss)
        if intent == "send":
            msg = " ".join(str(got.get("text") or "").split())[:2000]
            if not s or not msg:
                return "Which session should get that?"
            label = self.label(s, ss)
            self.pending = {"id": f"p{time.time_ns()}", "sid": s["id"], "label": label, "text": msg,
                            "at": self.clock()}
            return f"Send “{msg}” to {label}?"
        if intent == "answer" and got.get("text"):
            return " ".join(str(got["text"]).split()[:35])
        return "Sorry, I couldn't work that out."

    def _say(self, text):
        self.reply = text
        self.store.log_line(f"alfred: {text[:80]}")
        self.store.speak(text)

    def stop_speech(self):
        self.store.stop_speech()
