#!/bin/bash
# cc-pill interactive setup. macOS on Apple Silicon only.
# Run from the cloned repo: ./setup.sh
set -euo pipefail

# ---------- pretty printing ----------
B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[31m'; N=$'\033[0m'
say()  { printf "%s\n" "$1"; }
head_() { printf "\n%s%s%s\n%s\n" "$B$C" "$1" "$N" "${DIM}$2${N}"; }
ok()   { printf "  %s✓%s %s\n" "$G" "$N" "$1"; }
warn() { printf "  %s!%s %s\n" "$Y" "$N" "$1"; }
die()  { printf "  %s✗ %s%s\n" "$R" "$1" "$N"; exit 1; }
ask()  { local __v="$1" __p="$2" __d="$3"; local a;
         printf "  %s%s%s [%s]: " "$B" "$__p" "$N" "$__d"; read -r a
         eval "$__v=\"\${a:-$__d}\""; }

printf "\n%s╭──────────────────────────────────────────────╮%s\n" "$C" "$N"
printf "%s│%s   %scc-pill%s · a living menu bar for Claude Code  %s│%s\n" "$C" "$N" "$B" "$N" "$C" "$N"
printf "%s╰──────────────────────────────────────────────╯%s\n" "$C" "$N"

# ---------- platform guard ----------
[ "$(uname -s)" = "Darwin" ] || die "macOS only."
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon only (arm64)."
sw_vers -productVersion | grep -qE '^(1[4-9]|[2-9][0-9])' || die "macOS 14 or newer required."

REPO="$(cd "$(dirname "$0")" && pwd)"

# ---------- 1. where to install ----------
head_ "1 · Where should cc-pill live?" "The app, voice models (~350MB), and scripts stay in this folder."
ask INSTALL "Install directory" "$REPO"
INSTALL="${INSTALL/#\~/$HOME}"
if [ "$INSTALL" != "$REPO" ]; then
  mkdir -p "$INSTALL"
  rsync -a --exclude .git "$REPO/" "$INSTALL/"
  ok "copied to $INSTALL"
fi
DATA="$HOME/.cc-pill"
mkdir -p "$DATA"

# ---------- dependencies ----------
head_ "Checking dependencies" "swift toolchain, python3, tmux, jq (claude CLI for summaries)"
command -v swift  >/dev/null || die "swift not found: xcode-select --install"
command -v python3 >/dev/null || die "python3 not found"
command -v claude >/dev/null || die "claude CLI not found (install Claude Code first)"
MISSING=""
for dep in tmux jq; do command -v "$dep" >/dev/null || MISSING="$MISSING $dep"; done
if [ -n "$MISSING" ]; then
  if command -v brew >/dev/null; then
    warn "installing:$MISSING"
    brew install $MISSING
  else
    die "missing:$MISSING (install Homebrew or these packages, then re-run)"
  fi
fi
command -v media-control >/dev/null || warn "media-control not found (audio ducking disabled): brew install media-control"
ok "dependencies present"

# ---------- voice runtime ----------
head_ "Voice runtime" "Local neural TTS (Kokoro): python venv + two model files."
cd "$INSTALL/voice"
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
  .venv/bin/pip -q install kokoro-onnx soundfile
  ok "venv ready"
else
  ok "venv exists"
fi
mkdir -p models
[ -f models/kokoro-v1.0.onnx ] || curl -L --progress-bar -o models/kokoro-v1.0.onnx \
  https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
[ -f models/voices-v1.0.bin ] || curl -L --progress-bar -o models/voices-v1.0.bin \
  https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
ok "models present"

# ---------- 2. voice ----------
head_ "2 · Pick a voice" "Each option plays a short sample."
VOICES=(bm_george bm_fable bm_lewis am_michael af_heart af_bella af_nicole bf_emma)
DESCS=("British, warm butler" "British, storyteller" "British, deep" "American, even" "American, warm" "American, bright" "American, soft" "British, gentle")
VOICE="bm_george"
while true; do
  for i in "${!VOICES[@]}"; do
    printf "    %s%d%s. %-11s %s%s%s\n" "$B" "$((i+1))" "$N" "${VOICES[$i]}" "$DIM" "${DESCS[$i]}" "$N"
  done
  printf "  %sChoose 1-%d (p<num> to preview, Enter for 1)%s: " "$B" "${#VOICES[@]}" "$N"; read -r pick
  pick="${pick:-1}"
  if [[ "$pick" =~ ^p([0-9]+)$ ]]; then
    idx=$(( ${BASH_REMATCH[1]} - 1 ))
    VOICE_SAMPLE="${VOICES[$idx]:-}"
    [ -n "$VOICE_SAMPLE" ] || continue
    .venv/bin/python - <<PYEOF
import soundfile as sf, subprocess, tempfile
from kokoro_onnx import Kokoro
k = Kokoro("models/kokoro-v1.0.onnx", "models/voices-v1.0.bin")
s, sr = k.create("Hello. Your session just finished, and everything went beautifully.", voice="$VOICE_SAMPLE", speed=1.05)
f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
sf.write(f.name, s, sr)
subprocess.run(["afplay", f.name])
PYEOF
    continue
  fi
  if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#VOICES[@]}" ]; then
    VOICE="${VOICES[$((pick-1))]}"
    break
  fi
done
ok "voice: $VOICE"

# ---------- 3. name ----------
head_ "3 · Name your assistant" "The voice persona and the card footer use this."
ask NAME "Assistant name" "Jarvis"

# ---------- 4. personality ----------
head_ "4 · Personality" "How $NAME talks about your work."
say "    ${B}1${N}. Playful butler ${DIM}(cheeky, warm, quick with a tease)${N}"
say "    ${B}2${N}. Calm professional ${DIM}(crisp, factual, zero fluff)${N}"
say "    ${B}3${N}. Describe it, let Claude write it ${DIM}(generated with Haiku)${N}"
say "    ${B}4${N}. Paste your own persona text"
ask PCHOICE "Choose 1-4" "1"
case "$PCHOICE" in
  2) PERSONA="- Tone: calm and professional. Crisp declarative sentences, no jokes, no filler. Think a great radio news editor: warm enough to be human, disciplined enough to never waste a word.";;
  3) printf "  %sDescribe the personality you want%s (one line): " "$B" "$N"; read -r PDESC
     say "  ${DIM}asking Haiku...${N}"
     PERSONA=$(PILL_INNER=1 claude -p --model haiku "Write a tone/personality instruction block for a spoken assistant named $NAME who verbally briefs a developer about their coding sessions. The personality wanted: $PDESC. Write 3-5 sentences of instruction in the second person (like 'Tone: ...'), starting with '- Tone:'. Output ONLY the instruction block, no preamble." 2>/dev/null) || PERSONA=""
     if [ -z "$PERSONA" ]; then warn "generation failed, using playful default"; PCHOICE=1; fi;;
  4) say "  Paste persona lines, end with an empty line:"; PERSONA=""
     while IFS= read -r l; do [ -z "$l" ] && break; PERSONA="$PERSONA$l"$'\n'; done;;
esac
if [ "$PCHOICE" = "1" ]; then
  PERSONA="- Tone: playful and warm, with real wit. Think a cheeky best-friend-slash-butler who is genuinely good at their job: quick with a tease, delighted when things go well (\"the tests passed on the first try, I know, I'm shocked too\"), theatrically mournful about tedium (\"I renamed forty files, pray for me\")."
fi
ok "personality set"

# render prompt.txt
CCPILL_PERSONA="$PERSONA" python3 - "$INSTALL/voice" "$NAME" <<'PYEOF'
import sys, os
d, name = sys.argv[1], sys.argv[2]
persona = os.environ.get("CCPILL_PERSONA", "")
t = open(os.path.join(d, "prompt-template.txt")).read()
open(os.path.join(d, "prompt.txt"), "w").write(
    t.replace("__NAME__", name).replace("__PERSONA__", persona.strip()))
PYEOF
ok "persona rendered into voice/prompt.txt"

# ---------- 5. pill sessions ----------
head_ "5 · Pill-launched sessions" "Cmd+Alt+M starts a hands-free Claude session. Where and how?"
ask WORKDIR "Default working directory for pill sessions" "$HOME"
WORKDIR="${WORKDIR/#\~/$HOME}"
say "  ${B}Extra system instructions for pill sessions${N} ${DIM}(optional, Enter to skip)${N}:"
printf "  > "; read -r SYSPROMPT

# ---------- write config ----------
python3 - "$DATA/config.json" "$NAME" "$VOICE" "$WORKDIR" "$INSTALL" "$SYSPROMPT" <<'PYEOF'
import json, sys
p, name, voice, workdir, install, sysprompt = sys.argv[1:7]
cfg = {}
try: cfg = json.load(open(p))
except Exception: pass
cfg.update({
    "name": name, "voice": voice, "speed": 1.05, "volume": 0.7,
    "summarizer_model": "haiku", "notify_throttle_seconds": 120,
    "speaker": install + "/voice",
    "home_repo": workdir, "auto_mode": True, "pill_gc_minutes": 30,
    "pill_system_prompt": sysprompt,
})
json.dump(cfg, open(p, "w"), indent=2)
PYEOF
ok "config written to $DATA/config.json"

# ---------- build + install app ----------
head_ "Building the pill" "Swift build, app bundle, launchd agent (starts at login, auto-restarts)."
"$INSTALL/app/build.sh" >/dev/null
"$INSTALL/app/install-agent.sh" >/dev/null
ok "Pill.app running (supervised by launchd)"

# ---------- register hooks ----------
head_ "Registering Claude Code hooks" "Global hooks feed the pill; Stop/Notification feed the voice."
python3 - "$INSTALL" <<'PYEOF'
import json, os, sys
install = sys.argv[1]
p = os.path.expanduser("~/.claude/settings.json")
cfg = {}
try: cfg = json.load(open(p))
except Exception: pass
hooks = cfg.setdefault("hooks", {})
pill = install + "/hooks/hook.py"
voice = install + "/voice/hook.py"
def cmd(script, mode): return {"type": "command", "command": f'python3 "{script}" {mode}', "timeout": 15}
def entry(*cmds): return [{"hooks": list(cmds)}]
hooks["SessionStart"] = entry(cmd(pill, "start"))
hooks["UserPromptSubmit"] = entry(cmd(pill, "prompt"))
hooks["PreToolUse"] = entry(cmd(pill, "tool"))
hooks["SessionEnd"] = entry(cmd(pill, "end"))
hooks["Stop"] = entry(cmd(pill, "stop"), cmd(voice, "stop"))
hooks["Notification"] = entry(cmd(pill, "notify"), cmd(voice, "notify"))
json.dump(cfg, open(p, "w"), indent=2)
print("hooks registered")
PYEOF
ok "hooks in ~/.claude/settings.json (existing settings preserved)"

# ---------- optional tmux wrapper ----------
head_ "Optional · tmux wrapper for interactive sessions" "Lets the pill send prompts to and open your own claude sessions."
ask WRAP "Add the claude tmux wrapper to ~/.zshrc? (y/n)" "y"
if [ "$WRAP" = "y" ] && ! grep -q "cc-pill claude wrapper" ~/.zshrc 2>/dev/null; then
  cat >> ~/.zshrc <<'ZRC'

# --- cc-pill claude wrapper: interactive claude runs inside tmux so the
# pill can target it. Scripted calls and in-tmux runs pass straight through.
claude() {
  if [[ -n "$PILL_INNER" || -n "$TMUX" || ! -t 0 || ! -t 1 ]] \
     || [[ " $* " == *" -p "* || " $* " == *" --print "* ]]; then
    command claude "$@"
    return
  fi
  local base="cc-$(basename "$PWD" | tr -cs 'A-Za-z0-9_-' '-')"
  base="${base%-}"
  local name="$base" n=2
  while tmux has-session -t "=$name" 2>/dev/null; do
    if [[ "$(tmux display-message -p -t "=$name" '#{session_attached}')" == "0" ]]; then
      tmux attach -t "=$name"
      return
    fi
    name="$base-$((n++))"
  done
  tmux new-session -s "$name" "command claude ${(q)@}"
}
ZRC
  ok "wrapper added (open a new shell to use it)"
else
  [ "$WRAP" = "y" ] && ok "wrapper already present" || warn "skipped; card prompt-send and open-terminal need it"
fi

# ---------- alias ----------
LNAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
if ! grep -q "alias $LNAME=" ~/.zshrc 2>/dev/null; then
  echo "alias $LNAME='$INSTALL/voice/pillctl'" >> ~/.zshrc
  ok "shell alias: $LNAME (mute/unmute/replay/voice)"
fi

# ---------- verify ----------
head_ "Verification" "A test event and a spoken hello."
python3 - <<'PYEOF'
import json, os, time
d = os.path.expanduser("~/.cc-pill/events")
os.makedirs(d, exist_ok=True)
evt = dict(type="prompt", t=time.time(), sid="setup-test", cwd=os.path.expanduser("~"),
           repo="setup-test", pid=1, remote=False)
with open(os.path.join(d, f"evt-{time.time_ns()}.json"), "w") as f: json.dump(evt, f)
PYEOF
sleep 2
if grep -q "setup-test" "$DATA/pill.log" 2>/dev/null; then
  ok "the pill saw the test event (look at your menu bar!)"
else
  warn "test event not confirmed yet, check $DATA/pill.log"
fi
"$INSTALL/voice/.venv/bin/python" "$INSTALL/voice/say.py" "Hello, I'm $NAME. Set up and ready. Your sessions will appear in the menu bar, and I'll keep you posted out loud." >/dev/null 2>&1 &
python3 - <<'PYEOF'
import json, os, time
d = os.path.expanduser("~/.cc-pill/events")
with open(os.path.join(d, f"evt-{time.time_ns()}.json"), "w") as f:
    json.dump(dict(type="end", t=time.time(), sid="setup-test", cwd="", repo="setup-test", pid=1), f)
PYEOF

printf "\n%s╭──────────────────────────────────────────────╮%s\n" "$G" "$N"
printf "%s│%s  Done. New Claude sessions feed the pill.     %s│%s\n" "$G" "$N" "$G" "$N"
printf "%s│%s  ⌥⌘M anywhere: ask %s by voice or text.  %s│%s\n" "$G" "$N" "$NAME" "$G" "$N"
printf "%s╰──────────────────────────────────────────────╯%s\n\n" "$G" "$N"
