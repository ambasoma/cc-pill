#!/usr/bin/env python3
"""Pill event hook. Registered GLOBALLY in ~/.claude/settings.json so every
Claude Code session on this machine reports its lifecycle to the pill.

Modes (argv[1]): start | prompt | stop | notify | end | tool
Writes one small JSON event file into ~/.cc-pill/events/; the Pill app
watches that directory, applies the event, and deletes the file. Stdlib only,
exits in milliseconds, never blocks the session.
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
        "pid": os.getppid(),  # the claude process itself
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

    d = os.path.expanduser("~/.cc-pill/events")
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, f".tmp-{time.time_ns()}")
    with open(tmp, "w") as f:
        json.dump(evt, f)
    os.rename(tmp, os.path.join(d, f"evt-{time.time_ns()}.json"))


if __name__ == "__main__":
    main()
