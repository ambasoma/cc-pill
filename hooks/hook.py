#!/usr/bin/env python3
"""Pill event hook. Registered GLOBALLY in ~/.claude/settings.json so every
Claude Code session on this machine reports its lifecycle to the pill.

Modes (argv[1]): start | prompt | stop | notify | end | tool
Writes one small JSON event file into ~/.cc-pill/events/; the Pill app
watches that directory, applies the event, and deletes the file. Stdlib only,
exits in milliseconds, never blocks the session.

Inside an LXD container (linux/setup.sh containers) there is no pill to
watch a directory: ~/.cc-pill/remote.json holds the host daemon's bridge
address, this container's name and its token, and the event is posted there.
"""
import json
import os
import sys
import time


def tool_label(payload):
    """One short human phrase for what Claude is doing right now."""
    tool = payload.get("tool_name", "")
    ti = payload.get("tool_input") or {}
    base = os.path.basename

    if tool in ("Edit", "Write", "NotebookEdit"):
        p = ti.get("file_path", "")
        return "editing " + base(p) if p else "editing files"
    if tool == "Read":
        p = ti.get("file_path", "")
        return "reading " + base(p) if p else "reading"
    if tool == "Bash":
        desc = (ti.get("description") or "").strip()
        if desc:
            return desc[:1].lower() + desc[1:]
        cmd = (ti.get("command") or "").split()
        return "running " + base(cmd[0]) if cmd else "in the shell"
    if tool in ("Grep", "Glob"):
        return "searching the code"
    if tool in ("WebFetch", "WebSearch"):
        return "browsing the web"
    if tool in ("Agent", "Task", "Workflow"):
        return "delegating to agents"
    if tool.startswith("mcp__"):
        parts = tool.split("__")
        if len(parts) >= 3:
            srv = parts[1].replace("claude_ai_", "").replace("plugin_", "")
            return "using " + srv.replace("_", " ").strip()
        return "using a connector"
    return ""  # skip bookkeeping tools (tasks, skills, etc.)


SHELLS = {"sh", "bash", "dash", "zsh", "fish", "ksh"}
REMOTE_CONFIG = os.environ.get("CC_PILL_REMOTE") or os.path.expanduser("~/.cc-pill/remote.json")


def _proc(pid):
    """(name, parent pid) of a process from /proc, or None where there is no
    /proc (macOS), where the hook's parent is already the claude process."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            stat = f.read()
        name = stat[stat.index("(") + 1:stat.rindex(")")]
        parent = int(stat[stat.rindex(")") + 2:].split()[1])
        return os.path.basename(name), parent
    except (OSError, ValueError, IndexError):
        return None


def claude_pid(proc=_proc):
    """The pid the pill watches to know the session is alive. On Linux, Claude
    Code runs hooks through /bin/sh, so the direct parent is a shell that
    exits as soon as we do; walk up past shells to the claude process."""
    pid = os.getppid()
    for _ in range(4):
        info = proc(pid)
        if not info or info[0] not in SHELLS or info[1] <= 1:
            break
        pid = info[1]
    return pid


def last_assistant_text(transcript_path, tail=256 * 1024):
    """The last assistant text in a Claude Code transcript (the end of the
    file is enough), for hosts that do not pass last_assistant_message."""
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - tail))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except (OSError, TypeError, ValueError):
        return ""
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "assistant":
            continue
        content = (entry.get("message") or {}).get("content") or []
        parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
        text = "\n".join(p for p in parts if p.strip())
        if text:
            return text
    return ""


def speech_for(mode, payload):
    """What the host's voice needs to brief a container session: the turn's
    final message (stop) or the prompt's kind (notify). The host cannot read
    this container's transcript, so it travels with the event."""
    if mode == "stop":
        text = payload.get("last_assistant_message") or ""
        if isinstance(text, dict):
            text = "\n".join(b.get("text", "") for b in text.get("content", [])
                             if isinstance(b, dict) and b.get("type") == "text")
        if not isinstance(text, str) or not text.strip():
            text = last_assistant_text(payload.get("transcript_path", ""))
        return {"text": text[:8000]}
    if mode == "notify":
        return {"notification_type": str(payload.get("notification_type", ""))}
    return None


def post_to_host(evt, remote, timeout=0.5):
    """Send the event to the host daemon over the LXD bridge. Best effort:
    a pill that is down must never slow the session. A bare socket, not
    urllib: this runs before every tool call, and importing urllib's HTTP
    stack costs more than the whole request."""
    import socket
    evt["ssh_client"] = (os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_CLIENT") or "").split(" ")[0]
    body = json.dumps({"container": remote.get("container", ""), "event": evt}).encode()
    hostport = remote.get("url", "").split("://", 1)[-1].split("/", 1)[0]
    host, _, port = hostport.rpartition(":")
    head = ("POST /event HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\n"
            "X-CC-Pill: 1\r\nX-CC-Pill-Token: %s\r\nContent-Length: %d\r\n\r\n"
            % (hostport, remote.get("token", ""), len(body))).encode()
    try:
        with socket.create_connection((host.strip("[]"), int(port)), timeout=timeout) as s:
            s.sendall(head + body)
            # Read the short reply to its end: hanging up mid-reply would
            # leave the daemon a reset to log.
            while s.recv(4096):
                pass
    except (OSError, ValueError):
        pass


def load_remote():
    try:
        with open(REMOTE_CONFIG) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) and cfg.get("url") else None
    except (OSError, ValueError):
        return None


def main():
    if os.environ.get("PILL_INNER"):
        return
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    if payload.get("stop_hook_active"):
        return

    cwd = payload.get("cwd") or os.getcwd()
    evt = {
        "type": mode,
        "t": time.time(),
        "sid": payload.get("session_id", ""),
        "cwd": cwd,
        "repo": os.path.basename(cwd.rstrip("/")) or "?",
        "pid": claude_pid(),  # the claude process itself
        "remote": bool(os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_TTY")),
    }
    if mode == "notify":
        msg = payload.get("message", "")
        ntype = str(payload.get("notification_type", "")).lower()
        evt["msg"] = msg
        evt["idle"] = "idle" in ntype or "waiting" in msg.lower()

    if mode == "tool":
        label = tool_label(payload)
        if not label:
            return  # nothing worth showing for this tool
        evt["label"] = label[:44]

    remote = load_remote()
    if remote:
        speech = speech_for(mode, payload)
        if speech:
            evt["speech"] = speech
        post_to_host(evt, remote)
        return

    d = os.path.expanduser("~/.cc-pill/events")
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, f".tmp-{time.time_ns()}")
    with open(tmp, "w") as f:
        json.dump(evt, f)
    os.rename(tmp, os.path.join(d, f"evt-{time.time_ns()}.json"))


if __name__ == "__main__":
    main()
