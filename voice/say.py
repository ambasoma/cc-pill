#!/usr/bin/env python3
"""Speak arbitrary text in the assistant's voice: say.py <text...>

Used by pillctl (say / last / voice-change confirmations) and the pill app's
recap button. Bypasses the mute flag on purpose, an explicit ask to speak
should always speak.
"""
import subprocess
import sys

import worker

if __name__ == "__main__":
    text = " ".join(sys.argv[1:]).strip()
    if text:
        # An explicit ask preempts whatever is currently playing.
        subprocess.run(["killall", "afplay"], capture_output=True)
        worker.speak(text, worker.load_config())
