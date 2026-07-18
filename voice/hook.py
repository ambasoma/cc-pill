#!/usr/bin/env python3
"""Voice hook entry. Stdlib only, exits fast.

Registered (globally, by setup.sh) for the Stop and Notification events.
Reads the hook JSON from stdin, drops a job file in spool/, spawns the
worker (in the local venv) detached, and exits so the session never waits
on audio.
"""
import json
import os
import re
import subprocess
import sys
import time

VOICE_DIR = os.path.dirname(os.path.abspath(__file__))
SPOOL = os.path.join(VOICE_DIR, "spool")
VENV_PY = os.path.join(VOICE_DIR, ".venv", "bin", "python")


def main():
    # Guard: never fire for the inner `claude -p` summarizer call, for a
    # continued stop loop, or when the voice is switched off.
    if os.environ.get("PILL_INNER"):
        return
    if os.path.exists(os.path.join(VOICE_DIR, ".off")):
        return

    mode = sys.argv[1] if len(sys.argv) > 1 else "stop"
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}

    # Sessions run over SSH play audio on THIS machine while the user is on
    # another device: pointless. Skip them entirely.
    is_ssh = any(os.environ.get(k) for k in ("SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT"))

    os.makedirs(SPOOL, exist_ok=True)
    with open(os.path.join(SPOOL, "hook-debug.log"), "a") as dbg:
        tag = " ssh(skip)" if is_ssh else ""
        dbg.write(f"{time.strftime('%H:%M:%S')} {mode} keys={sorted(payload)}{tag}\n")

    if is_ssh:
        return

    if payload.get("stop_hook_active"):
        return

    # Safety net: if the harness ever runs us without stdin, fall back to the
    # most recently modified transcript for this project.
    if mode == "stop" and not payload.get("transcript_path"):
        project = re.sub(r"[^A-Za-z0-9]", "-", payload.get("cwd") or os.getcwd())
        tdir = os.path.expanduser(os.path.join("~/.claude/projects", project))
        try:
            newest = max(
                (os.path.join(tdir, f) for f in os.listdir(tdir) if f.endswith(".jsonl")),
                key=os.path.getmtime,
            )
            payload["transcript_path"] = newest
        except (OSError, ValueError):
            return

    payload["pill_mode"] = mode
    job = os.path.join(SPOOL, f"job-{time.time_ns()}.json")
    with open(job, "w") as f:
        json.dump(payload, f)

    log = open(os.path.join(SPOOL, "voice.log"), "a")
    subprocess.Popen(
        [VENV_PY, os.path.join(VOICE_DIR, "worker.py"), job],
        stdout=log,
        stderr=log,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )


if __name__ == "__main__":
    main()
