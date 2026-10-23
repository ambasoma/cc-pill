#!/usr/bin/env python3
"""Voice worker: turn one Claude Code hook payload into spoken audio.

Runs detached from the session (spawned by hook.py). Pipeline:
  1. Pull the text to speak (last assistant message for Stop, the
     notification message for Notification).
  2. Rewrite it into a short spoken briefing with the local model
     (llama.cpp, started and stopped by the daemon). No local model: say a
     short plain message as it is, else that a turn finished.
  3. Synthesize with Kokoro (local ONNX) and play it.

A spool lock serializes playback so two finishing sessions never talk
over each other. Also drops "briefing" events for the pill app so its
bloom syncs with the first spoken word.

Platform layer (everything OS-specific lives in the few functions marked
"platform" below):
  macOS  afplay for playback, media-control for ducking, lsappinfo for the
         frontmost app.
  Linux  pw-play / paplay / aplay / ffplay for playback, playerctl (MPRIS)
         for ducking, kdotool (KWin) or xdotool (X11) for the active window.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

VOICE_DIR = os.path.dirname(os.path.abspath(__file__))
SPOOL = os.path.join(VOICE_DIR, "spool")
LOCK = os.path.join(SPOOL, "playback.lock")
PLAYER_PID = os.path.join(SPOOL, "player.pid")
NOTIFY_STAMP = os.path.join(SPOOL, "last-notify")
SPOKE_STAMP = os.path.join(SPOOL, "last-spoke")
STOP_STAMP = os.path.join(SPOOL, "last-stop")
# The newest explicit request (a replay from the card, say.py). Requests
# queue behind the playback lock; an older one that finds it is no longer
# the newest gives way instead of playing over the click that replaced it.
LATEST_ASK = os.path.join(SPOOL, "latest-ask")
CONFIG = os.path.expanduser("~/.cc-pill/config.json")

MODEL_ONNX = os.path.join(VOICE_DIR, "models", "kokoro-v1.0.onnx")
VOICES_BIN = os.path.join(VOICE_DIR, "models", "voices-v1.0.bin")

IS_MAC = sys.platform == "darwin"


def load_config():
    cfg = {
        "enabled": True,
        "name": "Jarvis",
        "voice": "bm_george",
        "speed": 1.05,
        "volume": 0.7,
        "notify_throttle_seconds": 120,
        # Silence between two briefings that would otherwise run together.
        "briefing_gap_seconds": 2.5,
        # Hard cap on a spoken briefing (a decision may run slightly over).
        "briefing_max_words": 25,
    }
    try:
        with open(CONFIG) as f:
            cfg.update(json.load(f))
    except Exception:
        pass
    return cfg


def last_assistant_text(transcript_path):
    """Last assistant text block from a Claude Code JSONL transcript."""
    text = ""
    try:
        with open(transcript_path) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("type") != "assistant":
                    continue
                content = (entry.get("message") or {}).get("content") or []
                parts = [
                    b.get("text", "")
                    for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                ]
                if any(p.strip() for p in parts):
                    text = "\n".join(p for p in parts if p.strip())
    except Exception:
        pass
    return text.strip()


def last_briefing():
    """Most recent spoken stop-briefing from the log (no nags, no skips)."""
    try:
        with open(os.path.join(SPOOL, "voice.log")) as f:
            lines = f.read().splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        m = re.match(r"\[[0-9:]+\] stop: (.+)", line)
        if m and m.group(1) != "(skipped)":
            return m.group(1)
    return ""


def last_spoke():
    """When and for which session the voice last actually spoke."""
    try:
        with open(SPOKE_STAMP) as f:
            data = json.loads(f.read())
    except Exception:
        return {"t": 0.0, "sid": "", "repo": ""}
    if not isinstance(data, dict):  # legacy stamp: bare timestamp
        return {"t": float(data), "sid": "", "repo": ""}
    return {"t": float(data.get("t", 0)), "sid": data.get("sid", ""), "repo": data.get("repo", "")}


def spoken_name(container):
    """How a container's name is said: "web-dev" -> "web dev"."""
    return re.sub(r"[-_.]+", " ", container).strip()


def trim_words(line, limit):
    """Keep whole sentences within the word cap (with a little slack for a
    decision); never less than the first sentence."""
    if limit <= 0 or len(line.split()) <= limit + 5:
        return line
    sentences = re.split(r"(?<=[.!?])\s+", line.strip())
    kept = [sentences[0]]
    for s in sentences[1:]:
        if len(" ".join(kept + [s]).split()) > limit + 5:
            break
        kept.append(s)
    return " ".join(kept)


def speakable_as_is(raw, max_words):
    """Short plain English needs no summary: speak it and save the model
    call. Anything with code-ish characters still goes through the model,
    which knows not to read paths and symbols aloud."""
    text = " ".join(raw.split())
    return (0 < len(text.split()) <= max(8, max_words)
            and not re.search(r"[`/\\_{}<>#*|$=~\[\]]|\.\w{1,5}\b|\d{4,}", text))


def clip(raw, limit=4000):
    """The head and the tail of a long message: the outcome is usually at
    the start, a question for the user at the end."""
    if len(raw) <= limit:
        return raw
    return raw[:limit * 5 // 8] + "\n[...]\n" + raw[-(limit * 3 // 8):]


LOCAL_LLM = "http://127.0.0.1:8099"
LLM_WAIT = 30.0          # seconds a briefing waits for the local model to load
# A bare acknowledgement is not news: no model call, nothing said.
ACK = re.compile(r"^\W*(ok(ay)?|done|sure|got it|yes|no|thanks?( you)?|noted|will do|on it)\W*$", re.I)


def daemon_url(path):
    cfg = load_config()
    port = cfg.get("daemon_port", 17357)
    return f"http://127.0.0.1:{port if isinstance(port, int) else 17357}{path}"


def _post(url, body, timeout, headers=None):
    import urllib.request
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers=dict({"Content-Type": "application/json"}, **(headers or {})))
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def llm_ready(url):
    import urllib.request
    try:
        urllib.request.urlopen(url + "/health", timeout=0.5).close()
        return True
    except Exception:
        return False


# A question for the user: a sentence that ends in "?". Code finds it; the
# model only has to put it in plain words.
QUESTION = re.compile(r"[^.!?\n]*\?")
NEWS_ASK = {
    "type": "object",
    "properties": {"news": {"type": "string"}, "ask": {"type": "string", "minLength": 8}},
    "required": ["news", "ask"],
}


# A file path in a spoken line ("~/.config/app/config.toml", "src/pool.rs"):
# the persona says never to read them; a small model sometimes does.
PATHLIKE = re.compile(r"(?<![\w])(?:~|\.{1,2})?/?(?:[\w.-]+/)+[\w.-]+|`[^`]*`")


def speakable(line):
    """The line with paths and code spans turned into words."""
    line = PATHLIKE.sub("that path", line or "")
    return re.sub(r"\bthat path(\s+that path)+", "that path", line)


def has_question(raw):
    return bool(QUESTION.search(raw[-1500:]))


def compose(news, ask, max_words):
    """What happened, then the question, which is never the part that is
    cut: when both don't fit, the question goes alone."""
    news = " ".join((news or "").split()).strip()
    ask = " ".join((ask or "").split()).strip().rstrip(".!") + "?" if ask else ""
    if ask.endswith("??"):
        ask = ask[:-1]
    if news and news[-1] not in ".!?":
        news += "."
    if not news or (max_words and len(news.split()) + len(ask.split()) > max_words + 5):
        return ask
    return f"{news} {ask}"


def local_summary(system, message, url=None, wait=LLM_WAIT, sleep=time.sleep, clock=time.time, schema=None):
    """The spoken line from the local model (llama.cpp, owned by the daemon),
    or None when there is no local model.

    The daemon starts the model and stops it when idle; each briefing tells
    it the model is in use. The plain completion route with a rule that
    allows no "<" keeps Gemma from opening a thought block before it
    answers, which in chat mode it does whatever it is told."""
    url = (url or load_config().get("alfred_llm_url") or LOCAL_LLM).rstrip("/")
    try:
        _post(daemon_url("/llm/warm"), {}, 2, {"X-CC-Pill": "1"})   # start it, or keep it alive
    except Exception:
        pass
    end = clock() + wait
    while not llm_ready(url):
        if clock() > end:
            return None
        sleep(0.5)
    mark = "\x00MESSAGE\x00"
    try:
        tpl = _post(url + "/apply-template", {
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": mark}],
            "chat_template_kwargs": {"enable_thinking": False}}, 10)["prompt"]
        if tpl.count(mark) != 1:
            return None
        # the model's control markers (<|turn>, <turn|>) must not come from a session
        safe = message.replace("<|", "< |").replace("|>", "| >")
        body = {"prompt": tpl.replace(mark, safe), "n_predict": 110, "temperature": 0.3, "cache_prompt": True}
        if schema:
            body.update({"json_schema": schema, "stop": ["}"]})   # no nested braces: "}" ends it
        else:
            body["grammar"] = "root ::= [^<]{1,400}"
        out = _post(url + "/completion", body, 60)
    except Exception:
        return None
    text = str(out.get("content") or "")
    if schema:
        m = re.search(r"\{.*", text, re.S)
        try:
            got = json.loads(m.group(0) + ("" if text.rstrip().endswith("}") else "}")) if m else None
        except ValueError:
            got = None
        return got if isinstance(got, dict) else None
    line = " ".join(text.split()).strip("\"' ")
    return line or None


def plain_fallback(raw, max_words):
    """No local model: speak a short plain message as it is, else just say a
    turn finished. Never code, paths or markdown read aloud."""
    if speakable_as_is(raw, max_words):
        return " ".join(raw.split())
    return "A turn finished."


def summarize(raw, mode, ctx_repo=None, max_words=0, container=""):
    with open(os.path.join(VOICE_DIR, "prompt.txt")) as f:
        prompt = f.read()
    # Rules a small local model needs spelled out.
    prompt += (
        "\nIf the message asks the user something or waits on a decision, say what is being asked, "
        "and never answer it or advise yourself: the user decides.\n"
        "Never add news that is not in the message.\n"
    )
    if max_words > 0:
        prompt += (
            f"\nHard limit: {max_words} words, one sentence, two at most. Only a "
            "decision the user must make may run a little longer.\n"
        )
    if container:
        prompt += (
            "\nDo not name the container or machine: the user hears its name "
            "just before your words.\n"
        )
    if ctx_repo:
        prompt += (
            "\nIt has been a while since the user last heard a briefing, or the "
            "last one was about a different project, so they have lost the "
            "thread. Open with a few words of orientation that name the "
            "project, '" + ctx_repo + "', before the news. Something like "
            "'On the " + ctx_repo + " work, ...' but vary the phrasing. Keep "
            "the orientation to a few words.\n"
        )
    if mode == "notify":
        prompt += (
            "\nThis one is a NOTIFICATION: the session is paused and waiting on "
            "the user (a permission request or idle prompt). Say briefly that "
            "their attention is needed and for what. One sentence is ideal.\n"
        )
    if ACK.match(raw):
        return "SKIP"
    if mode == "stop" and has_question(raw):
        # The question must reach the user, put to them, not answered:
        # a small model drops or answers it unless the answer has a slot
        # for it.
        got = local_summary(prompt + (
            "\nThe message asks the user a question. Answer as JSON: news is what happened, in one short "
            "spoken sentence (may be empty); ask is that question, put to the user in plain spoken words. "
            "Do not answer the question.\n"), clip(raw), schema=NEWS_ASK)
        if got and str(got.get("ask") or "").strip():
            return speakable(compose(got.get("news"), got.get("ask"), max_words))
        return plain_fallback(raw, max_words)
    line = local_summary(prompt, clip(raw))
    return speakable(line) if line else plain_fallback(raw, max_words)


EVENTS = os.path.expanduser("~/.cc-pill/events")


def pill_event(evt):
    """Tell the pill app what is being spoken (best effort, never fails)."""
    try:
        os.makedirs(EVENTS, exist_ok=True)
        tmp = os.path.join(EVENTS, f".tmp-{time.time_ns()}")
        with open(tmp, "w") as f:
            json.dump(evt, f)
        os.rename(tmp, os.path.join(EVENTS, f"evt-{time.time_ns()}.json"))
    except Exception:
        pass


def _run(args, timeout=3):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


# ---------------------------------------------------------------- platform:
# audio ducking. macOS: media-control (Now Playing). Linux: playerctl (MPRIS).

MEDIA_CONTROL = (
    "/opt/homebrew/bin/media-control"
    if os.path.exists("/opt/homebrew/bin/media-control")
    else "media-control"
)


def _media(cmd):
    return _run([MEDIA_CONTROL, cmd])


def _mpris_playing():
    """Names of MPRIS players currently playing (Linux, via playerctl)."""
    if not shutil.which("playerctl"):
        return []
    out = _run(["playerctl", "-l"])
    if not out or out.returncode != 0:
        return []
    playing = []
    for name in out.stdout.split():
        st = _run(["playerctl", "-p", name, "status"])
        if st and st.returncode == 0 and st.stdout.strip() == "Playing":
            playing.append(name)
    return playing


def duck_begin():
    """Pause whatever the user is listening to. Returns a token for duck_end,
    or None when nothing was playing (or ducking is unavailable)."""
    if IS_MAC:
        out = _media("get")
        if out and out.returncode == 0 and out.stdout.strip():
            try:
                data = json.loads(out.stdout)
                # media-control prints the JSON literal null when nothing is
                # registered with Now Playing.
                if isinstance(data, dict) and data.get("playing"):
                    _media("pause")
                    return "mac"
            except ValueError:
                pass
        return None
    players = _mpris_playing()
    for p in players:
        _run(["playerctl", "-p", p, "pause"])
    return players or None


def duck_end(token):
    if not token:
        return
    if token == "mac":
        _media("play")
        return
    for p in token:
        _run(["playerctl", "-p", p, "play"])


def other_audio_playing():
    """Kept for callers that only want to know, without pausing anything."""
    if IS_MAC:
        out = _media("get")
        if out and out.returncode == 0 and out.stdout.strip():
            try:
                data = json.loads(out.stdout)
                return bool(isinstance(data, dict) and data.get("playing"))
            except ValueError:
                pass
        return False
    return bool(_mpris_playing())


# ---------------------------------------------------------------- platform:
# is the user already looking at this session's terminal?

TERMINAL_APPS = {"Ghostty", "Terminal", "iTerm2", "WezTerm", "kitty", "Alacritty"}

# Window classes (lowercased) of terminals on Linux desktops.
TERMINAL_CLASSES = {
    "konsole", "org.kde.konsole", "yakuake", "org.kde.yakuake", "kitty", "alacritty",
    "wezterm", "org.wezfurlong.wezterm", "ghostty", "com.mitchellh.ghostty", "foot",
    "footclient", "gnome-terminal", "gnome-terminal-server", "org.gnome.terminal",
    "org.gnome.console", "kgx", "xterm", "urxvt", "st", "st-256color", "tilix",
    "terminator", "xfce4-terminal", "tmux",
}


def frontmost_app():
    """Name of the frontmost app, via lsappinfo (macOS, no permissions needed)."""
    try:
        asn = subprocess.run(
            ["lsappinfo", "front"], capture_output=True, text=True, timeout=3
        ).stdout.strip()
        if not asn:
            return ""
        out = subprocess.run(
            ["lsappinfo", "info", "-only", "name", asn],
            capture_output=True, text=True, timeout=3,
        ).stdout
        m = re.search(r'"LSDisplayName"="([^"]+)"', out)
        return m.group(1) if m else ""
    except Exception:
        return ""


def active_window_class():
    """Window class of the focused window on Linux: kdotool talks to KWin
    (Wayland and X11), xdotool covers other X11 sessions. Empty if unknown."""
    if shutil.which("kdotool"):
        out = _run(["kdotool", "getactivewindow", "getwindowclassname"])
        if out and out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip().splitlines()[-1]
    if shutil.which("xdotool") and os.environ.get("DISPLAY"):
        out = _run(["xdotool", "getactivewindow", "getwindowclassname"])
        if out and out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip().splitlines()[-1]
    return ""


def terminal_in_front():
    if IS_MAC:
        return frontmost_app() in TERMINAL_APPS
    cls = active_window_class().lower()
    return bool(cls) and (cls in TERMINAL_CLASSES or cls.split(".")[-1] in TERMINAL_CLASSES)


def session_on_screen(cwd, exec_prefix=()):
    """True when the user is already looking at this session's terminal.

    Precise when the session runs under tmux (the claude wrapper, or any
    pane in this cwd): the pane must be the active pane of an attached
    client. Otherwise falls back to "a terminal app is frontmost".
    """
    if not terminal_in_front():
        return False
    if cwd:
        # A container session's panes live in the container's own tmux:
        # the daemon puts the `lxc exec` prefix in the job.
        try:
            out = subprocess.run(
                list(exec_prefix) + ["tmux", "list-panes", "-a", "-F",
                          "#{session_attached}\t#{window_active}\t#{pane_active}\t#{pane_current_path}"],
                capture_output=True, text=True, timeout=3,
            )
        except Exception:
            out = None
        if out and out.returncode == 0:
            known = False
            for line in out.stdout.splitlines():
                parts = line.split("\t")
                if len(parts) != 4:
                    continue
                attached, win_active, pane_active, path = parts
                if path == cwd:
                    known = True
                    if attached not in ("", "0") and win_active == "1" and pane_active == "1":
                        return True
            if known:
                # Runs under tmux but a different pane is on screen: speak.
                return False
    return True


# ---------------------------------------------------------------- platform:
# playback.

def player_command(wav, volume):
    """Command line that plays a WAV file, or None when no player exists.

    afplay takes the volume itself. The Linux players don't agree on a
    volume flag, so speak() scales the samples before writing the file and
    they all play at unity.
    """
    if IS_MAC:
        return ["afplay", "-v", str(volume), wav]
    for cand in (
        ["pw-play", wav],
        ["paplay", wav],
        ["aplay", "-q", wav],
        ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", wav],
    ):
        if shutil.which(cand[0]):
            return cand
    return None


def claim_ask():
    """Mark a new explicit request as the newest one. Returns its token."""
    token = f"{os.getpid()}-{time.time_ns()}"
    try:
        os.makedirs(SPOOL, exist_ok=True)
        tmp = LATEST_ASK + f".{os.getpid()}"
        with open(tmp, "w") as f:
            f.write(token)
        os.replace(tmp, LATEST_ASK)
    except OSError:
        pass
    return token


def ask_is_latest(token):
    try:
        with open(LATEST_ASK) as f:
            return f.read().strip() == token
    except OSError:
        return True   # nothing to compare with: play


def stop_playback():
    """Cut whatever is being spoken right now (an explicit ask preempts it)."""
    try:
        with open(PLAYER_PID) as f:
            pid = int(f.read().strip() or 0)
        if pid > 0:
            os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    if IS_MAC:
        _run(["killall", "afplay"])


def wait_for_gap(cfg, now=time.time, sleep=time.sleep):
    """Hold until briefing_gap_seconds have passed since the last briefing
    ended (last-spoke is stamped when playback finishes). Returns the wait."""
    try:
        gap = float(cfg.get("briefing_gap_seconds", 0) or 0)
    except (TypeError, ValueError):
        gap = 0.0
    if gap <= 0:
        return 0.0
    wait = min(gap, last_spoke()["t"] + gap - now())
    if wait > 0:
        sleep(wait)
        return wait
    return 0.0


def speak(text, cfg, meta=None, announce=True, ask=None):
    """Synthesize and play `text`. With `ask` (a claim_ask token), give way
    if a newer explicit request came in while this one waited its turn."""
    if ask is not None and not ask_is_latest(ask):
        return   # already replaced: skip the synthesis
    import soundfile as sf
    from kokoro_onnx import Kokoro

    kokoro = Kokoro(MODEL_ONNX, VOICES_BIN)
    samples, sr = kokoro.create(text, voice=cfg["voice"], speed=cfg["speed"])
    volume = float(cfg.get("volume", 0.7))
    if not IS_MAC:
        samples = samples * max(0.0, min(1.0, volume))
    os.makedirs(SPOOL, exist_ok=True)
    wav = os.path.join(SPOOL, f"say-{time.time_ns()}.wav")
    sf.write(wav, samples, sr)
    duration = len(samples) / float(sr)

    player = player_command(wav, volume)
    if player is None:
        print(f"[{time.strftime('%H:%M:%S')}] no audio player found (pw-play, paplay, aplay, ffplay)", flush=True)
        try:
            os.unlink(wav)
        except FileNotFoundError:
            pass
        return

    # Serialize playback across concurrent sessions (stale locks expire).
    waited = 0
    while waited < 120:
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            break
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(LOCK) > 120:
                    os.unlink(LOCK)
                    continue
            except FileNotFoundError:
                continue
            time.sleep(0.5)
            waited += 0.5
    if ask is not None and not ask_is_latest(ask):
        # A newer click replaced this one while it was synthesized or waited
        # for the lock: play nothing, and hand the lock on at once.
        for p in (LOCK, wav):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        return
    # Leave a breath after the previous briefing, so two that queue up behind
    # each other don't run together. An explicit ask is answered at once.
    if ask is None:
        wait_for_gap(cfg)
    # Duck: pause whatever the user is listening to, speak, then resume it.
    ducked = duck_begin()
    if ducked:
        time.sleep(0.4)
    # The pill blooms open on this event, timed with the first spoken word.
    if announce:
        pill_event({
            "type": "briefing", "t": time.time(), "text": text,
            "duration": duration, "silent": False,
            "sid": (meta or {}).get("sid", ""), "repo": (meta or {}).get("repo", ""),
        })
    try:
        proc = subprocess.Popen(player, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            with open(PLAYER_PID, "w") as f:
                f.write(str(proc.pid))
        except OSError:
            pass
        try:
            proc.wait(timeout=180)
        except subprocess.TimeoutExpired:
            proc.kill()
        stamp = {"t": time.time()}
        if meta:
            stamp.update(meta)
        with open(SPOKE_STAMP, "w") as f:
            f.write(json.dumps(stamp))
    finally:
        duck_end(ducked)
        for p in (LOCK, PLAYER_PID, wav):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def main():
    job_path = sys.argv[1]
    with open(job_path) as f:
        payload = json.load(f)
    try:
        os.unlink(job_path)
    except FileNotFoundError:
        pass

    cfg = load_config()
    if not cfg.get("enabled"):
        return

    mode = payload.get("pill_mode", "stop")
    if mode == "notify":
        msg = payload.get("message", "") or "Claude needs your attention."
        ntype = str(payload.get("notification_type", "")).lower()
        # Only genuine permission/approval prompts always speak. Everything
        # else ("done, what next", idle reminders, misc) is a nag: stay quiet
        # unless it has been a while since the user last heard from us.
        is_permission = ("permission" in msg.lower() or "approval" in msg.lower()
                         or "permission" in ntype)
        if not is_permission:
            quiet = None
            try:
                if time.time() - os.path.getmtime(SPOKE_STAMP) < 600:
                    quiet = "just spoke"
            except FileNotFoundError:
                pass
            if not quiet:
                try:
                    if time.time() - os.path.getmtime(STOP_STAMP) < 120:
                        quiet = "turn just ended"
                except FileNotFoundError:
                    pass
            if quiet:
                print(f"[{time.strftime('%H:%M:%S')}] notify: (quiet, {quiet})", flush=True)
                return
        else:
            # Permission/attention prompts: always speak, dedupe rapid repeats.
            try:
                if time.time() - os.path.getmtime(NOTIFY_STAMP) < cfg["notify_throttle_seconds"]:
                    return
            except FileNotFoundError:
                pass
        with open(NOTIFY_STAMP, "w") as f:
            f.write(str(time.time()))
        raw = msg
        brief = last_briefing()
        if brief:
            raw += (
                "\n(For context, the previous spoken briefing was: "
                + brief
                + "\nUse it to remind the user in a few words what this is about.)"
            )
    else:
        # Mark the briefing as in flight right away, before the (slow)
        # summarize call, so a trailing notification stays quiet.
        try:
            with open(STOP_STAMP, "w") as f:
                f.write(str(time.time()))
        except OSError:
            pass
        # Prefer the message passed directly in the payload: the transcript
        # file on disk can lag several messages behind the live session.
        raw = payload.get("last_assistant_message") or ""
        if isinstance(raw, dict):  # tolerate a content-block shape
            raw = "\n".join(
                b.get("text", "")
                for b in raw.get("content", [])
                if isinstance(b, dict) and b.get("type") == "text"
            )
        if not isinstance(raw, str) or not raw.strip():
            raw = last_assistant_text(payload.get("transcript_path", ""))

    if not raw:
        return
    # Re-orientation: if the user has not heard a briefing in a while, or the
    # last one they heard was a different session, open with the project name.
    sid = payload.get("session_id", "")
    repo = os.path.basename((payload.get("cwd") or "").rstrip("/"))
    container = payload.get("container") or ""
    ctx = None
    if mode == "stop" and repo:
        prev = last_spoke()
        stale = time.time() - prev["t"] > 600
        switched = bool(prev["sid"]) and bool(sid) and prev["sid"] != sid
        if stale or switched:
            ctx = repo
    try:
        max_words = int(cfg.get("briefing_max_words", 0) or 0)
    except (TypeError, ValueError):
        max_words = 0
    if ctx is None and speakable_as_is(raw, max_words):
        line = " ".join(raw.split())   # already a briefing: no model call
    else:
        line = summarize(raw, mode, ctx, max_words, container)
    if not line or line.strip().upper() == "SKIP":
        print(f"[{time.strftime('%H:%M:%S')}] {mode}: (skipped)", flush=True)
        return
    line = trim_words(line, max_words)
    if container:
        # Every container briefing opens with where it comes from.
        line = f"{spoken_name(container)}: {line}"
    print(f"[{time.strftime('%H:%M:%S')}] {mode}: {line}", flush=True)
    # Courtesy: if the user is already looking at this session's terminal,
    # the briefing is redundant. Log it (for replay and the pill) but stay
    # quiet.
    if session_on_screen(payload.get("cwd", ""), payload.get("exec_prefix") or []):
        print(f"[{time.strftime('%H:%M:%S')}] (terminal on screen, stayed quiet)", flush=True)
        # Silent bloom: the pill still shows the text, just without audio.
        pill_event({
            "type": "briefing", "t": time.time(), "text": line,
            "silent": True, "sid": sid, "repo": repo,
        })
        return
    speak(line, cfg, {"sid": sid, "repo": repo})


if __name__ == "__main__":
    main()
