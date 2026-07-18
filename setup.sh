#!/bin/bash
# cc-pill interactive setup. macOS on Apple Silicon only.
#   ./setup.sh          full setup
#   ./setup.sh voice    add (or reconfigure) the voice later
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

# ---------- platform guard ----------
[ "$(uname -s)" = "Darwin" ] || die "macOS only."
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon only (arm64)."
sw_vers -productVersion | grep -qE '^(1[4-9]|[2-9][0-9])' || die "macOS 14 or newer required."

REPO="$(cd "$(dirname "$0")" && pwd)"
DATA="$HOME/.cc-pill"
MODE="${1:-full}"

cfg_set() {  # cfg_set key json_value  (value must already be JSON-encoded)
  python3 - "$DATA/config.json" "$1" "$2" <<'PYEOF'
import json, sys
p, key, val = sys.argv[1:4]
cfg = {}
try: cfg = json.load(open(p))
except Exception: pass
cfg[key] = json.loads(val)
json.dump(cfg, open(p, "w"), indent=2)
PYEOF
}

register_hooks() {  # register_hooks <install> <voice_on: 1|0>
  python3 - "$1" "$2" <<'PYEOF'
import json, os, sys
install, voice_on = sys.argv[1], sys.argv[2] == "1"
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
if voice_on:
    hooks["Stop"] = entry(cmd(pill, "stop"), cmd(voice, "stop"))
    hooks["Notification"] = entry(cmd(pill, "notify"), cmd(voice, "notify"))
else:
    hooks["Stop"] = entry(cmd(pill, "stop"))
    hooks["Notification"] = entry(cmd(pill, "notify"))
json.dump(cfg, open(p, "w"), indent=2)
PYEOF
}

voice_runtime() {  # install venv + models in $1/voice
  cd "$1/voice"
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
}

voice_questions() {  # voice + name + personality + summarizer; writes config + prompt.txt
  local install="$1"
  cd "$install/voice"

  head_ "Pick a voice" "Type p<num> to hear a sample, the number to choose."
  local VOICES=(bm_george bm_fable bm_lewis am_michael af_heart af_bella af_nicole bf_emma)
  local DESCS=("British, warm butler" "British, storyteller" "British, deep" "American, even" "American, warm" "American, bright" "American, soft" "British, gentle")
  VOICE="bm_george"
  while true; do
    for i in "${!VOICES[@]}"; do
      printf "    %s%d%s. %-11s %s%s%s\n" "$B" "$((i+1))" "$N" "${VOICES[$i]}" "$DIM" "${DESCS[$i]}" "$N"
    done
    printf "  %sChoose 1-%d (p<num> to preview, Enter for 1)%s: " "$B" "${#VOICES[@]}" "$N"; read -r pick
    pick="${pick:-1}"
    if [[ "$pick" =~ ^p([0-9]+)$ ]]; then
      idx=$(( ${BASH_REMATCH[1]} - 1 ))
      VS="${VOICES[$idx]:-}"
      [ -n "$VS" ] || continue
      .venv/bin/python - <<PYEOF
import soundfile as sf, subprocess, tempfile
from kokoro_onnx import Kokoro
k = Kokoro("models/kokoro-v1.0.onnx", "models/voices-v1.0.bin")
s, sr = k.create("Hello. Your session just finished, and everything went beautifully.", voice="$VS", speed=1.05)
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

  head_ "Name your assistant" "The voice persona and the card footer use this."
  ask NAME "Assistant name" "Jarvis"

  head_ "Personality" "How $NAME talks about your work."
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
  CCPILL_PERSONA="$PERSONA" python3 - "$install/voice" "$NAME" <<'PYEOF'
import sys, os
d, name = sys.argv[1], sys.argv[2]
persona = os.environ.get("CCPILL_PERSONA", "")
t = open(os.path.join(d, "prompt-template.txt")).read()
open(os.path.join(d, "prompt.txt"), "w").write(
    t.replace("__NAME__", name).replace("__PERSONA__", persona.strip()))
PYEOF
  ok "persona rendered"

  ask SUMMODEL "Model for summarizing briefings" "haiku"

  cfg_set name "\"$NAME\""
  cfg_set voice "\"$VOICE\""
  cfg_set speed "1.05"
  cfg_set volume "0.7"
  cfg_set summarizer_model "\"$SUMMODEL\""
  cfg_set notify_throttle_seconds "120"
  cfg_set enabled "true"
  cfg_set speaker "\"$install/voice\""

  # shell alias named after the assistant
  local LNAME
  LNAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
  if [ -n "$LNAME" ] && ! grep -q "alias $LNAME=" ~/.zshrc 2>/dev/null; then
    echo "alias $LNAME='$install/voice/pillctl'" >> ~/.zshrc
    ok "shell alias: $LNAME (mute/unmute/replay/voice)"
  fi
}

# ================= voice-later subcommand =================
if [ "$MODE" = "voice" ]; then
  [ -f "$DATA/config.json" ] || die "run ./setup.sh (full) first"
  INSTALL=$(python3 -c "import json,os;print(os.path.dirname(json.load(open(os.path.expanduser('$DATA/config.json'))).get('speaker', '$REPO/voice')))" 2>/dev/null || echo "$REPO")
  [ -d "$INSTALL/voice" ] || INSTALL="$REPO"
  head_ "Adding the voice" "Local TTS runtime + persona for your existing install at $INSTALL"
  voice_runtime "$INSTALL"
  voice_questions "$INSTALL"
  register_hooks "$INSTALL" 1
  ok "voice hooks registered"
  "$INSTALL/voice/.venv/bin/python" "$INSTALL/voice/say.py" "Voice is on. You'll hear from me when your sessions finish." >/dev/null 2>&1 &
  say "\n  ${G}${B}Done. New sessions will be spoken.${N}\n"
  exit 0
fi

# ================= full setup =================
printf "\n%s╭──────────────────────────────────────────────╮%s\n" "$C" "$N"
printf "%s│%s   %scc-pill%s · a living menu bar for Claude Code  %s│%s\n" "$C" "$N" "$B" "$N" "$C" "$N"
printf "%s╰──────────────────────────────────────────────╯%s\n" "$C" "$N"

# ---------- 1. where to install ----------
head_ "1 · Where should cc-pill live?" "The app, scripts, and (optional) voice models stay in this folder."
ask INSTALL "Install directory" "$REPO"
INSTALL="${INSTALL/#\~/$HOME}"
if [ "$INSTALL" != "$REPO" ]; then
  mkdir -p "$INSTALL"
  rsync -a --exclude .git "$REPO/" "$INSTALL/"
  ok "copied to $INSTALL"
fi
mkdir -p "$DATA"

# ---------- dependencies ----------
head_ "Checking dependencies" "swift toolchain, python3, tmux, jq, claude CLI"
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

# ---------- 2. terminal ----------
head_ "2 · Which terminal do you use?" "The card's open-terminal button focuses this app."
TERMS=(); TERMNAMES=()
add_term() {
  if [ -d "/Applications/$2.app" ] || [ -d "$HOME/Applications/$2.app" ]; then
    TERMS+=("$1"); TERMNAMES+=("$2")
  fi
}
add_term "com.mitchellh.ghostty" "Ghostty"
add_term "com.googlecode.iterm2" "iTerm"
add_term "com.github.wez.wezterm" "WezTerm"
add_term "net.kovidgoyal.kitty" "kitty"
add_term "org.alacritty" "Alacritty"
TERMS+=("com.apple.Terminal"); TERMNAMES+=("Terminal")
for i in "${!TERMS[@]}"; do
  printf "    %s%d%s. %s\n" "$B" "$((i+1))" "$N" "${TERMNAMES[$i]}"
done
ask TPICK "Choose 1-${#TERMS[@]}" "1"
[[ "$TPICK" =~ ^[0-9]+$ ]] && [ "$TPICK" -ge 1 ] && [ "$TPICK" -le "${#TERMS[@]}" ] || TPICK=1
TERMINAL="${TERMS[$((TPICK-1))]}"
ok "terminal: ${TERMNAMES[$((TPICK-1))]}"

# ---------- 3. hotkey ----------
head_ "3 · Ask-mode hotkey" "Press it anywhere to start a Claude session by voice or text."
while true; do
  ask HOTKEY "Hotkey (modifiers+key, e.g. cmd+alt+m, ctrl+shift+space)" "cmd+alt+m"
  if python3 - "$HOTKEY" <<'PYEOF'
import sys
keys = {"a","s","d","f","h","g","z","x","c","v","b","q","w","e","r","y","t",
        "1","2","3","4","5","6","7","8","9","0","o","u","i","p","l","j","k",
        "n","m","space","`"}
mods = {"cmd","command","alt","opt","option","ctrl","control","shift"}
toks = [t.strip() for t in sys.argv[1].lower().split("+")]
m = [t for t in toks if t in mods]
k = [t for t in toks if t in keys]
sys.exit(0 if (len(m) >= 1 and len(k) == 1 and len(m) + len(k) == len(toks)) else 1)
PYEOF
  then break; else warn "can't parse that; use modifiers+letter/digit/space"; fi
done
ok "hotkey: $HOTKEY"

# ---------- 4. pill sessions ----------
head_ "4 · Pill-launched sessions" "How hands-free should hotkey-started sessions be?"
say "    ${B}1${N}. Auto-accept edits ${DIM}(file edits proceed; other actions still ask, the paw taps you)${N}"
say "    ${B}2${N}. Fully hands-free ${DIM}(skip ALL permission prompts; only for machines you can restore)${N}"
say "    ${B}3${N}. Normal ${DIM}(every permission prompts, like your regular sessions)${N}"
ask PMODE "Choose 1-3" "1"
case "$PMODE" in
  2) PERM="bypass";;
  3) PERM="default";;
  *) PERM="acceptEdits";;
esac
ask WORKDIR "Default working directory for pill sessions" "$HOME"
WORKDIR="${WORKDIR/#\~/$HOME}"
say "  ${B}Extra system instructions for pill sessions${N} ${DIM}(optional, Enter to skip)${N}:"
printf "  > "; read -r SYSPROMPT

# ---------- 5. voice ----------
head_ "5 · Voice briefings" "A local neural voice speaks a short summary when each turn finishes."
say "    ${DIM}Needs a one-time ~350MB model download. Skip it and the island still works;${N}"
say "    ${DIM}add it any time later with: ./setup.sh voice${N}"
ask WANTVOICE "Enable the voice? (y/n)" "y"

# ---------- write base config ----------
CCPILL_SP="$SYSPROMPT" python3 - "$DATA/config.json" "$WORKDIR" "$INSTALL" "$PERM" "$TERMINAL" "$HOTKEY" <<'PYEOF'
import json, os, sys
p, workdir, install, perm, terminal, hotkey = sys.argv[1:7]
cfg = {}
try: cfg = json.load(open(p))
except Exception: pass
cfg.update({
    "home_repo": workdir,
    "permission_mode": perm,
    "terminal": terminal,
    "hotkey": hotkey,
    "pill_gc_minutes": 30,
    "pill_system_prompt": os.environ.get("CCPILL_SP", ""),
    "speaker": install + "/voice",
})
cfg.setdefault("name", "Jarvis")
cfg.setdefault("enabled", False)
json.dump(cfg, open(p, "w"), indent=2)
PYEOF
ok "config written to $DATA/config.json"

# ---------- voice install ----------
if [ "$WANTVOICE" = "y" ]; then
  head_ "Voice runtime" "Python venv + Kokoro models."
  voice_runtime "$INSTALL"
  voice_questions "$INSTALL"
fi

# ---------- build + install app ----------
head_ "Building the pill" "Swift build, app bundle, launchd agent (starts at login, auto-restarts)."
"$INSTALL/app/build.sh" >/dev/null
"$INSTALL/app/install-agent.sh" >/dev/null
ok "Pill.app running (supervised by launchd)"

# ---------- register hooks ----------
head_ "Registering Claude Code hooks" "Global; existing settings are preserved."
if [ "$WANTVOICE" = "y" ]; then register_hooks "$INSTALL" 1; else register_hooks "$INSTALL" 0; fi
ok "hooks in ~/.claude/settings.json"

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

# ---------- verify ----------
head_ "Verification" "A test event through the pipeline."
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
if [ "$WANTVOICE" = "y" ]; then
  NAME_NOW=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$DATA/config.json')))['name'])")
  "$INSTALL/voice/.venv/bin/python" "$INSTALL/voice/say.py" "Hello, I'm $NAME_NOW. Set up and ready. Your sessions will appear in the menu bar, and I'll keep you posted out loud." >/dev/null 2>&1 &
fi
python3 - <<'PYEOF'
import json, os, time
d = os.path.expanduser("~/.cc-pill/events")
with open(os.path.join(d, f"evt-{time.time_ns()}.json"), "w") as f:
    json.dump(dict(type="end", t=time.time(), sid="setup-test", cwd="", repo="setup-test", pid=1), f)
PYEOF

printf "\n%s╭──────────────────────────────────────────────╮%s\n" "$G" "$N"
printf "%s│%s  Done. New Claude sessions feed the pill.    %s│%s\n" "$G" "$N" "$G" "$N"
printf "%s│%s  %s anywhere: ask by voice or text.%s\n" "$G" "$N" "$HOTKEY" "$N"
[ "$WANTVOICE" = "y" ] || printf "%s│%s  Add the voice later: ./setup.sh voice%s\n" "$G" "$N" "$N"
printf "%s╰──────────────────────────────────────────────╯%s\n\n" "$G" "$N"
