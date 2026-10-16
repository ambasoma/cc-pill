#!/usr/bin/env python3
"""Speak arbitrary text in the assistant's voice: say.py <text...>

Used by pillctl (say / last / voice-change confirmations) and the pill's
recap button. Bypasses the mute flag on purpose, an explicit ask to speak
should always speak.

    say.py --stop     cut whatever is being spoken right now, say nothing
"""
import sys

import worker

if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--stop":
        worker.stop_playback()
        sys.exit(0)
    text = " ".join(args).strip()
    if text:
        # An explicit ask preempts whatever is currently playing.
        worker.stop_playback()
        worker.speak(text, worker.load_config())
