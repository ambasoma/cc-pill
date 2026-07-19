#!/usr/bin/env python3
"""Voice worker: turn one Claude Code hook payload into spoken audio.

Runs detached from the session (spawned by hook.py). Pipeline:
  1. Pull the text to speak (last assistant message for Stop, the
     notification message for Notification).
  2. Rewrite it into a short spoken briefing with `claude -p` (Haiku).
  3. Synthesize with Kokoro (local ONNX) and play via afplay.

A spool lock serializes playback so two finishing sessions never talk
over each other. Also drops "briefing" events for the pill app so its
bloom syncs with the first spoken word.
"""
import json
import os
import re
import subprocess
import sys
import time

VOICE_DIR = os.path.dirname(os.path.abspath(__file__))
SPOOL = os.path.join(VOICE_DIR, "spool")
LOCK = os.path.join(SPOOL, "playback.lock")
NOTIFY_STAMP = os.path.join(SPOOL, "last-notify")
SPOKE_STAMP = os.path.join(SPOOL, "last-spoke")
STOP_STAMP = os.path.join(SPOOL, "last-stop")
CONFIG = os.path.expanduser("~/.cc-pill/config.json")

MODEL_ONNX = os.path.join(VOICE_DIR, "models", "kokoro-v1.0.onnx")
VOICES_BIN = os.path.join(VOICE_DIR, "models", "voices-v1.0.bin")


def load_config():
    cfg = {
        "enabled": True,
        "name": "Jarvis",
        "voice": "bm_george",
        "speed": 1.05,
        "volume": 0.7,
        "summarizer_model": "haiku",
        "notify_throttle_seconds": 120,
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


def summarize(raw, mode, model, ctx_repo=None):
    with open(os.path.join(VOICE_DIR, "prompt.txt")) as f:
        prompt = f.read()
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
    prompt += "\n<<<MESSAGE>>>\n" + raw[:8000] + "\n<<<END>>>\n"

    env = dict(os.environ, PILL_INNER="1")
    try:
        out = subprocess.run(
            ["claude", "-p", "--model", model],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=90,
            env=env,
        )
        line = out.stdout.strip()
        if out.returncode == 0 and line:
            return line
    except Exception:
        pass
    # Fallback: speak the first couple of sentences raw rather than staying silent.
    plain = " ".join(raw.split())
    return plain[:300] if plain else ""


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


MEDIA_CONTROL = (
    "/opt/homebrew/bin/media-control"
    if os.path.exists("/opt/homebrew/bin/media-control")
    else "media-control"
)


def _media(cmd):
    try:
        return subprocess.run(
            [MEDIA_CONTROL, cmd], capture_output=True, text=True, timeout=3
        )
    except Exception:
        return None


def other_audio_playing():
    out = _media("get")
    if out and out.returncode == 0 and out.stdout.strip():
        try:
            data = json.loads(out.stdout)
            # media-control prints the JSON literal null when nothing is
            # registered with Now Playing.
            return bool(isinstance(data, dict) and data.get("playing"))
        except ValueError:
            pass
    return False


TERMINAL_APPS = {"Ghostty", "Terminal", "iTerm2", "WezTerm", "kitty", "Alacritty"}


def frontmost_app():
    """Name of the frontmost app, via lsappinfo (no permissions needed)."""
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


def session_on_screen(cwd):
    """True when the user is already looking at this session's terminal.

    Precise when the session runs under tmux (the claude wrapper, or any
    pane in this cwd): the pane must be the active pane of an attached
    client. Otherwise falls back to "a terminal app is frontmost".
    """
    if frontmost_app() not in TERMINAL_APPS:
        return False
    if cwd:
        try:
            out = subprocess.run(
                ["tmux", "list-panes", "-a", "-F",
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


def speak(text, cfg, meta=None):
    import soundfile as sf
    from kokoro_onnx import Kokoro

    kokoro = Kokoro(MODEL_ONNX, VOICES_BIN)
    samples, sr = kokoro.create(text, voice=cfg["voice"], speed=cfg["speed"])
    wav = os.path.join(SPOOL, f"say-{time.time_ns()}.wav")
    sf.write(wav, samples, sr)
    duration = len(samples) / float(sr)

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
    # Duck: pause whatever the user is listening to, speak, then resume it.
    ducked = other_audio_playing()
    if ducked:
        _media("pause")
        time.sleep(0.4)
    # The pill blooms open on this event, timed with the first spoken word.
    pill_event({
        "type": "briefing", "t": time.time(), "text": text,
        "duration": duration, "silent": False,
        "sid": (meta or {}).get("sid", ""), "repo": (meta or {}).get("repo", ""),
    })
    try:
        subprocess.run(["afplay", "-v", str(cfg["volume"]), wav], timeout=180)
        stamp = {"t": time.time()}
        if meta:
            stamp.update(meta)
        with open(SPOKE_STAMP, "w") as f:
            f.write(json.dumps(stamp))
    finally:
        if ducked:
            _media("play")
        try:
            os.unlink(LOCK)
        except FileNotFoundError:
            pass
        try:
            os.unlink(wav)
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
    ctx = None
    if mode == "stop" and repo:
        prev = last_spoke()
        stale = time.time() - prev["t"] > 600
        switched = bool(prev["sid"]) and bool(sid) and prev["sid"] != sid
        if stale or switched:
            ctx = repo
    line = summarize(raw, mode, cfg["summarizer_model"], ctx)
    if not line or line.strip().upper() == "SKIP":
        print(f"[{time.strftime('%H:%M:%S')}] {mode}: (skipped)", flush=True)
        return
    print(f"[{time.strftime('%H:%M:%S')}] {mode}: {line}", flush=True)
    # Courtesy: if the user is already looking at this session's terminal,
    # the briefing is redundant. Log it (for replay and the pill) but stay
    # quiet.
    if session_on_screen(payload.get("cwd", "")):
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
