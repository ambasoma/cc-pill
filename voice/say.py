#!/usr/bin/env python3
"""Speak arbitrary text in the assistant's voice: say.py <text...>

Used by pillctl (say / last / voice-change confirmations) and the pill's
recap button. Bypasses the mute flag on purpose, an explicit ask to speak
should always speak.

    say.py --stop     cut whatever is being spoken right now, say nothing
    say.py --sid <id> <text...>   tag the briefing with its session (the
                                  card shows that row's stop button)
"""
import sys

import worker

if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--stop":
        worker.claim_ask()        # also cancels replays still waiting their turn
        worker.stop_playback()
        sys.exit(0)
    meta = None
    if len(args) >= 2 and args[0] == "--sid":
        meta = {"sid": args[1]}
        args = args[2:]
    text = " ".join(args).strip()
    if text:
        # An explicit ask preempts whatever is playing, and any earlier ask
        # that has not played yet (clicking replay on one row, then another).
        token = worker.claim_ask()
        worker.stop_playback()
        worker.speak(text, worker.load_config(), meta, ask=token)
