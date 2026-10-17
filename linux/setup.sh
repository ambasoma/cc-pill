#!/bin/bash
# cc-pill interactive setup for Linux, KDE Plasma 6.
#   ./linux/setup.sh          full setup
#   ./linux/setup.sh voice    add (or reconfigure) the voice later
set -euo pipefail

# ---------- plain fallbacks (used until gum is installed, or without it) ----------
B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
GOLD=178; OLIVE=108; INKDIM=245
HASGUM=0

ok()   { printf "  %s✓%s %s\n" "$G" "$N" "$1"; }
warn() { printf "  %s!%s %s\n" "$Y" "$N" "$1"; }
die()  { printf "  %s✗ %s%s\n" "$R" "$1" "$N"; exit 1; }

banner() {
  if [ "$HASGUM" = 1 ]; then
    gum style --border rounded --border-foreground "$GOLD" --padding "0 3" --margin "1 0" --align center \
      "$(gum style --bold --foreground "$GOLD" 'cc-pill')" \
      "$(gum style --foreground "$INKDIM" 'a living panel for Claude Code · KDE Plasma')"
  else
    printf "\n%s── cc-pill ──%s a living panel for Claude Code · KDE Plasma\n\n" "$B" "$N"
  fi
}

head_() {  # head_ "Title" "subtitle"
  if [ "$HASGUM" = 1 ]; then
    echo
    gum style --bold --foreground "$GOLD" "$1"
    [ -n "${2:-}" ] && gum style --foreground "$INKDIM" "$2"
  else
    printf "\n%s%s%s\n%s%s%s\n" "$B" "$1" "$N" "$DIM" "${2:-}" "$N"
  fi
}

ui_input() {  # ui_input VAR "prompt" "default"
  local v
  if [ "$HASGUM" = 1 ]; then
    v=$(gum input --header "  $2" --prompt "  ❯ " --value "$3" --header.foreground "$INKDIM") || v="$3"
  else
    printf "  %s%s%s [%s]: " "$B" "$2" "$N" "$3"; read -r v
  fi
  eval "$1=\"\${v:-$3}\""
}

ui_write() {  # ui_write VAR "prompt"  (multiline via gum, single line fallback)
  local v
  if [ "$HASGUM" = 1 ]; then
    v=$(gum write --header "  $2 (ctrl+d to finish, esc to skip)" --placeholder "..." --header.foreground "$INKDIM") || v=""
  else
    printf "  %s%s%s (Enter to skip): " "$B" "$2" "$N"; read -r v
  fi
  eval "$1=\"\$v\""
}

ui_confirm() {  # ui_confirm "question" default(y/n) -> 0 yes / 1 no
  if [ "$HASGUM" = 1 ]; then
    if [ "$2" = "n" ]; then
      gum confirm --default=false --prompt.foreground "$GOLD" "$1"
    else
      gum confirm --prompt.foreground "$GOLD" "$1"
    fi
  else
    local a; printf "  %s%s%s (y/n) [%s]: " "$B" "$1" "$N" "$2"; read -r a
    [ "${a:-$2}" = "y" ]
  fi
}

ui_choose() {  # ui_choose VAR "header" "opt1" "opt2" ...  -> selected option text
  local v
  if [ "$HASGUM" = 1 ]; then
    v=$(gum choose --header "  $2" --cursor "  ❯ " --header.foreground "$INKDIM" \
         --cursor.foreground "$GOLD" --selected.foreground "$GOLD" "${@:3}") || v="$3"
  else
    local opts=("${@:3}") i
    printf "  %s%s%s\n" "$B" "$2" "$N"
    for i in "${!opts[@]}"; do printf "    %d. %s\n" "$((i+1))" "${opts[$i]}"; done
    printf "  choose [1]: "; read -r i; i="${i:-1}"
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#opts[@]}" ] || i=1
    v="${opts[$((i-1))]}"
  fi
  eval "$1=\"\$v\""
}

ui_spin() {  # ui_spin "title" command...
  if [ "$HASGUM" = 1 ]; then
    gum spin --spinner moon --title "$1" --spinner.foreground "$GOLD" -- "${@:2}"
  else
    printf "  %s…%s %s\n" "$DIM" "$N" "$1"
    "${@:2}"
  fi
}

# ---------- platform guard ----------
[ "$(uname -s)" = "Linux" ] || die "This is the Linux setup. On macOS run ./setup.sh from the repo root."

# resolve symlinks: the package installs /usr/bin/cc-pill-setup -> /usr/share/cc-pill/linux/setup.sh
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DATA="$HOME/.cc-pill"
MODE="${1:-full}"
# Installed by a distro package (the AUR PKGBUILD puts the tree under
# /usr/share/cc-pill, read-only): no install question, the widget and the
# systemd unit are already in place, and the voice runtime (venv, models,
# persona, spool) lives in ~/.cc-pill/voice with the scripts symlinked in.
PACKAGED=0
[ "$REPO" = "/usr/share/cc-pill" ] && PACKAGED=1
SHELL_RC="$HOME/.bashrc"
case "$(basename "${SHELL:-bash}")" in zsh) SHELL_RC="$HOME/.zshrc";; esac

command -v gum >/dev/null && HASGUM=1

# ---------- distro hints ----------
pkg_hint() {  # pkg_hint <pkg...>  -> prints the install command for this distro
  if command -v apt-get >/dev/null; then echo "sudo apt install $*"
  elif command -v dnf >/dev/null; then echo "sudo dnf install $*"
  elif command -v pacman >/dev/null; then echo "sudo pacman -S $*"
  elif command -v zypper >/dev/null; then echo "sudo zypper install $*"
  else echo "install with your package manager: $*"; fi
}

# ---------- shared helpers ----------
cfg_set() {  # cfg_set key json_value
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

register_hooks() {  # register_hooks <install> <voice_on: 1|0> <voice dir>
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, os, sys
install, voice_on, vdir = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
cfg = {}
try: cfg = json.load(open(p))
except Exception: pass
hooks = cfg.setdefault("hooks", {})
pill = install + "/hooks/hook.py"
voice = vdir + "/hook.py"
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

voice_dir() {  # voice_dir <install> -> the writable voice dir (venv, models, spool, persona)
  if [ "$PACKAGED" = 1 ]; then
    mkdir -p "$DATA/voice"
    local f
    for f in worker.py say.py hook.py pillctl prompt-template.txt; do
      ln -sfn "$REPO/voice/$f" "$DATA/voice/$f"
    done
    echo "$DATA/voice"
  else
    echo "$1/voice"
  fi
}

voice_runtime() {  # venv + models in <voice dir>
  cd "$1"
  if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv || die "python3 -m venv failed ($(pkg_hint python3-venv))"
    ui_spin "Installing the speech engine..." .venv/bin/pip -q install kokoro-onnx soundfile
    ok "venv ready"
  else
    ok "venv exists"
  fi
  mkdir -p models
  if [ ! -f models/kokoro-v1.0.onnx ]; then
    say_dl="Downloading voice model (310MB)..."
    [ "$HASGUM" = 1 ] && gum style --foreground "$INKDIM" "  $say_dl" || echo "  $say_dl"
    curl -L --progress-bar -o models/kokoro-v1.0.onnx \
      https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
  fi
  [ -f models/voices-v1.0.bin ] || curl -L --progress-bar -o models/voices-v1.0.bin \
    https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
  ok "models present"
}

play_sample() {  # play_sample <voice>   (runs in <install>/voice)
  .venv/bin/python - "$1" <<'PYEOF'
import sys
sys.path.insert(0, ".")
import worker
worker.speak("Hello. Your session just finished, and everything went beautifully.",
             {"voice": sys.argv[1], "speed": 1.05, "volume": 0.7}, announce=False)
PYEOF
}

voice_questions() {  # voice + name + personality + summarizer -> config + prompt.txt
  local vdir="$1"
  cd "$vdir"

  head_ "Pick a voice" "Every choice plays a sample before you commit."
  local OPTS=(
    "bm_george   · British, warm butler"
    "bm_fable    · British, storyteller"
    "bm_lewis    · British, deep"
    "am_michael  · American, even"
    "af_heart    · American, warm"
    "af_bella    · American, bright"
    "af_nicole   · American, soft"
    "bf_emma     · British, gentle"
  )
  VOICE="bm_george"
  while true; do
    local choice
    ui_choose choice "Pick a voice to hear" "${OPTS[@]}"
    VOICE="${choice%% *}"
    ui_spin "$VOICE is warming up..." true
    play_sample "$VOICE"
    ui_confirm "Keep $VOICE?" "y" && break
  done
  ok "voice: $VOICE"

  head_ "Name your assistant" "Spoken persona and card footer."
  ui_input NAME "Assistant name" "Jarvis"

  head_ "Personality" "How $NAME talks about your work."
  local P1="Playful butler       · cheeky, warm, quick with a tease"
  local P2="Calm professional    · crisp, factual, zero fluff"
  local P3="Describe it          · Claude writes the persona from your description"
  local P4="Write your own       · paste persona text"
  local pchoice
  ui_choose pchoice "Pick a personality" "$P1" "$P2" "$P3" "$P4"
  PERSONA=""
  case "$pchoice" in
    "$P2") PERSONA="- Tone: calm and professional. Crisp declarative sentences, no jokes, no filler. Think a great radio news editor: warm enough to be human, disciplined enough to never waste a word.";;
    "$P3") local PDESC=""
       ui_input PDESC "Describe the personality you want" "dry wit, encouraging, slightly dramatic"
       local GENPROMPT="Write a tone/personality instruction block for a spoken assistant named $NAME who verbally briefs a developer about their coding sessions. The personality wanted: $PDESC. Write 3-5 sentences of instruction in the second person (like 'Tone: ...'), starting with '- Tone:'. Output ONLY the instruction block, no preamble."
       if [ "$HASGUM" = 1 ]; then
         PERSONA=$(gum spin --spinner moon --title "Haiku is writing the persona..." --show-output -- \
           env PILL_INNER=1 claude -p --model haiku "$GENPROMPT") || PERSONA=""
       else
         PERSONA=$(PILL_INNER=1 claude -p --model haiku "$GENPROMPT" 2>/dev/null) || PERSONA=""
       fi
       if [ -z "$PERSONA" ]; then warn "generation failed, using playful default"; fi;;
    "$P4") ui_write PERSONA "Your persona text";;
  esac
  if [ -z "$PERSONA" ]; then
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

  ui_input SUMMODEL "Model for summarizing briefings" "haiku"

  cfg_set name "\"$NAME\""
  cfg_set voice "\"$VOICE\""
  cfg_set speed "1.05"
  cfg_set volume "0.7"
  cfg_set summarizer_model "\"$SUMMODEL\""
  cfg_set notify_throttle_seconds "120"
  cfg_set enabled "true"
  cfg_set speaker "\"$vdir\""

  local LNAME
  LNAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
  if [ -n "$LNAME" ] && ! grep -q "alias $LNAME=" "$SHELL_RC" 2>/dev/null; then
    echo "alias $LNAME='$vdir/pillctl'" >> "$SHELL_RC"
    ok "shell alias: $LNAME (mute/unmute/replay/voice)"
  fi
}

# ================= voice-later subcommand =================
if [ "$MODE" = "voice" ]; then
  [ -f "$DATA/config.json" ] || die "run ./linux/setup.sh (full) first"
  if [ "$PACKAGED" = 1 ]; then
    INSTALL="$REPO"
  else
    INSTALL=$(python3 -c "import json,os;print(os.path.dirname(json.load(open(os.path.expanduser('$DATA/config.json'))).get('speaker', '$REPO/voice')))" 2>/dev/null || echo "$REPO")
    [ -d "$INSTALL/voice" ] || INSTALL="$REPO"
  fi
  VOICE=$(voice_dir "$INSTALL")
  banner
  head_ "Adding the voice" "Local TTS runtime + persona, for the install at $INSTALL"
  command -v pw-play >/dev/null || command -v paplay >/dev/null || command -v aplay >/dev/null \
    || warn "no audio player found (pw-play / paplay / aplay); $(pkg_hint pipewire-utils)"
  voice_runtime "$VOICE"
  voice_questions "$VOICE"
  register_hooks "$INSTALL" 1 "$VOICE"
  ok "voice hooks registered"
  "$VOICE/.venv/bin/python" "$VOICE/say.py" "Voice is on. You'll hear from me when your sessions finish." >/dev/null 2>&1 &
  echo
  ok "${B}Done. New sessions will be spoken.${N}"
  echo
  exit 0
fi

# ================= full setup =================
banner

# ---------- dependencies ----------
head_ "Checking dependencies" "Plasma 6, python3, tmux, jq, claude CLI (gum optional)"
command -v plasmashell >/dev/null || die "plasmashell not found: this setup targets KDE Plasma 6"
command -v kpackagetool6 >/dev/null || die "kpackagetool6 not found ($(pkg_hint plasma-workspace))"
# plasmashell is a Qt app: `--version` needs a display and crashes without one
# (an ssh shell, for instance). kpackagetool6 only ships with Frameworks 6, so
# a Plasma 6 install is already implied; the version read is a sanity check.
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  PLASMA_MAJOR=$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$PLASMA_MAJOR" ] && [ "$PLASMA_MAJOR" -lt 6 ]; then
    die "KDE Plasma 6 or newer required (found plasmashell $PLASMA_MAJOR)"
  fi
  [ -n "$PLASMA_MAJOR" ] || warn "could not read the plasmashell version; continuing"
else
  warn "no display in this shell: skipping the plasmashell version check"
fi
command -v python3 >/dev/null || die "python3 not found ($(pkg_hint python3))"
python3 -c "import venv" 2>/dev/null || die "python3 venv module missing ($(pkg_hint python3-venv))"
command -v claude >/dev/null || die "claude CLI not found (install Claude Code first)"
command -v systemctl >/dev/null || die "systemctl not found: the daemon runs as a systemd user service"
MISSING=""
for dep in tmux jq; do command -v "$dep" >/dev/null || MISSING="$MISSING $dep"; done
[ -z "$MISSING" ] || die "missing:$MISSING ($(pkg_hint $MISSING))"
command -v gum >/dev/null || warn "gum not found: plain prompts instead of the TUI (github.com/charmbracelet/gum)"
command -v kdialog >/dev/null || warn "kdialog not found: the hotkey falls back to zenity/terminal ($(pkg_hint kdialog))"
command -v playerctl >/dev/null || warn "playerctl not found (audio ducking disabled): $(pkg_hint playerctl)"
command -v kdotool >/dev/null || warn "kdotool not found (silent-when-on-screen courtesy disabled): github.com/jinliu/kdotool"
command -v pw-play >/dev/null || command -v paplay >/dev/null || command -v aplay >/dev/null \
  || warn "no audio player found (pw-play / paplay / aplay); needed for the voice: $(pkg_hint pipewire-utils)"
ok "dependencies present"

# ---------- 1. where to install ----------
if [ "$PACKAGED" = 1 ]; then
  head_ "1 · Where cc-pill lives" "Installed by your package manager at $REPO; voice models and persona go to $DATA/voice."
  INSTALL="$REPO"
  ok "packaged install"
else
  head_ "1 · Where should cc-pill live?" "The daemon, widget, scripts, and (optional) voice models stay in this folder."
  ui_input INSTALL "Install directory" "$REPO"
  INSTALL="${INSTALL/#\~/$HOME}"
  if [ "$INSTALL" != "$REPO" ]; then
    mkdir -p "$INSTALL"
    rsync -a --exclude .git "$REPO/" "$INSTALL/"
    ok "copied to $INSTALL"
  fi
fi
mkdir -p "$DATA"
VOICE=$(voice_dir "$INSTALL")

# ---------- 2. terminal ----------
head_ "2 · Which terminal do you use?" "The card's open-terminal button opens or raises this one."
TERMNAMES=()
for t in konsole kitty alacritty wezterm ghostty foot gnome-terminal xterm; do
  command -v "$t" >/dev/null && TERMNAMES+=("$t")
done
TERMNAMES+=("other (type a command)")
TCHOICE=""
ui_choose TCHOICE "Your terminal" "${TERMNAMES[@]}"
if [ "$TCHOICE" = "other (type a command)" ]; then
  ui_input TERMINAL "Terminal command (must accept -e <command>)" "konsole"
else
  TERMINAL="$TCHOICE"
fi
ok "terminal: $TERMINAL"

# ---------- 3. hotkey ----------
head_ "3 · Ask-mode hotkey" "Press it anywhere to start a Claude session from a prompt box."
while true; do
  ui_input HOTKEY "Hotkey (modifiers+key, e.g. meta+alt+m, ctrl+shift+space)" "meta+alt+m"
  if KDEHOTKEY=$(python3 - "$HOTKEY" <<'PYEOF'
import sys
keys = {"a","s","d","f","h","g","z","x","c","v","b","q","w","e","r","y","t",
        "1","2","3","4","5","6","7","8","9","0","o","u","i","p","l","j","k",
        "n","m","space",chr(96)}
mods = {"meta": "Meta", "super": "Meta", "win": "Meta", "cmd": "Meta", "command": "Meta",
        "alt": "Alt", "opt": "Alt", "option": "Alt", "ctrl": "Ctrl", "control": "Ctrl", "shift": "Shift"}
toks = [t.strip() for t in sys.argv[1].lower().split("+")]
m = [mods[t] for t in toks if t in mods]
k = [t for t in toks if t in keys]
if not (len(m) >= 1 and len(k) == 1 and len(m) + len(k) == len(toks)):
    sys.exit(1)
key = {"space": "Space", chr(96): chr(96)}.get(k[0], k[0].upper())
order = ["Meta", "Ctrl", "Alt", "Shift"]
print("+".join([x for x in order if x in m] + [key]))
PYEOF
  ); then break; else warn "can't parse that; use modifiers+letter/digit/space"; fi
done
ok "hotkey: $HOTKEY ($KDEHOTKEY)"

# ---------- 4. pill sessions ----------
head_ "4 · Pill-launched sessions" "How hands-free should hotkey-started sessions be?"
M1="Auto-accept edits   · file edits proceed, other actions still ask (recommended)"
M2="Fully hands-free    · skip ALL permission prompts (only for restorable machines)"
M3="Normal              · every permission prompts, like your regular sessions"
PCHOICEM=""
ui_choose PCHOICEM "Permission mode" "$M1" "$M2" "$M3"
case "$PCHOICEM" in
  "$M2") PERM="bypass";;
  "$M3") PERM="default";;
  *) PERM="acceptEdits";;
esac
ui_input WORKDIR "Default working directory for pill sessions" "$HOME"
WORKDIR="${WORKDIR/#\~/$HOME}"
SYSPROMPT=""
if ui_confirm "Add extra system instructions for pill sessions?" "n"; then
  ui_write SYSPROMPT "System instructions"
fi

# ---------- 5. voice ----------
head_ "5 · Voice briefings" "A local neural voice speaks a short summary when each turn finishes. One-time ~350MB model download; skip now and add later with: ./linux/setup.sh voice"
WANTVOICE="n"
ui_confirm "Enable the voice?" "y" && WANTVOICE="y"

# ---------- write base config ----------
CCPILL_SP="$SYSPROMPT" python3 - "$DATA/config.json" "$WORKDIR" "$VOICE" "$PERM" "$TERMINAL" "$HOTKEY" <<'PYEOF'
import json, os, sys
p, workdir, vdir, perm, terminal, hotkey = sys.argv[1:7]
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
    "speaker": vdir,
})
cfg.setdefault("daemon_port", 17357)
cfg.setdefault("name", "Jarvis")
cfg.setdefault("enabled", False)
json.dump(cfg, open(p, "w"), indent=2)
PYEOF
ok "config written to $DATA/config.json"

# ---------- voice install ----------
if [ "$WANTVOICE" = "y" ]; then
  head_ "Voice runtime" "Python venv + Kokoro models."
  voice_runtime "$VOICE"
  voice_questions "$VOICE"
fi

# ---------- daemon (systemd user service) ----------
head_ "Installing the daemon" "systemd user service: starts at login, auto-restarts."
if [ "$PACKAGED" = 1 ]; then
  rm -f "$HOME/.config/systemd/user/cc-pill.service"   # the package ships /usr/lib/systemd/user/cc-pill.service
else
  chmod +x "$INSTALL/linux/daemon/ccpilld.py" "$INSTALL/linux/bin/ccpill-ask" "$INSTALL/linux/bin/cc-pill-place" "$INSTALL/voice/pillctl" 2>/dev/null || true
  mkdir -p "$HOME/.config/systemd/user"
  sed "s|__INSTALL__|$INSTALL|g" "$INSTALL/linux/systemd/cc-pill.service" > "$HOME/.config/systemd/user/cc-pill.service"
fi
systemctl --user daemon-reload
systemctl --user enable cc-pill.service >/dev/null 2>&1 || warn "could not enable cc-pill.service"
systemctl --user restart cc-pill.service || warn "could not start cc-pill.service"
sleep 1
if systemctl --user is-active --quiet cc-pill.service; then
  ok "ccpilld running (systemctl --user status cc-pill)"
else
  warn "daemon not active yet: journalctl --user -u cc-pill -n 30"
fi

# ---------- widget ----------
head_ "Installing the widget" "Plasma 6 applet com.ccpill.pill"
PLASMOID="$INSTALL/linux/plasmoid/com.ccpill.pill"
if [ "$PACKAGED" = 1 ]; then
  # /usr/share/plasma/plasmoids/com.ccpill.pill came with the package; a
  # per-user copy from an earlier source install would shadow it
  if [ -d "$HOME/.local/share/plasma/plasmoids/com.ccpill.pill" ]; then
    kpackagetool6 --type Plasma/Applet --remove com.ccpill.pill >/dev/null 2>&1 || true
    ok "removed the older per-user copy of the widget"
  fi
  ok "widget installed system-wide by the package"
  WIDGET_UPGRADED=1
elif [ -d "$HOME/.local/share/plasma/plasmoids/com.ccpill.pill" ]; then
  kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID" >/dev/null 2>&1 \
    || die "kpackagetool6 --upgrade failed"
  ok "widget upgraded"
  WIDGET_UPGRADED=1
else
  kpackagetool6 --type Plasma/Applet --install "$PLASMOID" >/dev/null 2>&1 \
    || die "kpackagetool6 --install failed"
  ok "widget installed"
  WIDGET_UPGRADED=0
fi

# ---------- placement ----------
# Only when plasmashell is reachable on this session bus (not from ssh).
PLACED=0
if qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "print(1)" >/dev/null 2>&1; then
  head_ "Placing the widget" "Pick a panel and a spot; Edit Mode lets you drag it anywhere later."
  HERE_NOW=$(python3 "$INSTALL/linux/bin/cc-pill-place" --status 2>/dev/null | head -1)
  OPTS=()
  if [ -n "$HERE_NOW" ] && [ "$HERE_NOW" != "not on any panel" ]; then
    OPTS+=("Keep it where it is ($HERE_NOW)")
  fi
  OPTS+=("Top panel · centre" "Top panel · right, before the tray" "Top panel · left"
         "Bottom panel · right, before the tray" "Bottom panel · centre" "Bottom panel · left"
         "Left panel" "Right panel" "I'll add it myself (Add Widgets…)")
  ui_choose PLACE "Where should the pill live?" "${OPTS[@]}"
  EDGE=""; ALIGN="end"
  case "$PLACE" in
    "Keep it where it is"*)  PLACED=1 ;;
    "Top panel · centre")    EDGE=top;    ALIGN=center ;;
    "Top panel · right"*)    EDGE=top ;;
    "Top panel · left")      EDGE=top;    ALIGN=start ;;
    "Bottom panel · centre") EDGE=bottom; ALIGN=center ;;
    "Bottom panel · right"*) EDGE=bottom ;;
    "Bottom panel · left")   EDGE=bottom; ALIGN=start ;;
    "Left panel")            EDGE=left ;;
    "Right panel")           EDGE=right ;;
  esac
  if [ -n "$EDGE" ]; then
    if python3 "$INSTALL/linux/bin/cc-pill-place" --edge "$EDGE" --align "$ALIGN"; then
      ok "pill placed: $PLACE"
      PLACED=1
    else
      warn "could not place the widget; add it by hand (right-click the panel → Add Widgets…)"
    fi
  fi
else
  warn "plasmashell not reachable from here; add the widget from the desktop (right-click the panel → Add Widgets…)"
fi

# ---------- hotkey ----------
head_ "Registering the hotkey" "$KDEHOTKEY opens the ask box (KDE global shortcut)."
mkdir -p "$HOME/.local/share/applications"
sed -e "s|__INSTALL__|$INSTALL|g" -e "s|__SHORTCUT__|$KDEHOTKEY|g" \
  "$INSTALL/linux/share/cc-pill-ask.desktop" > "$HOME/.local/share/applications/cc-pill-ask.desktop"
if command -v kwriteconfig6 >/dev/null; then
  kwriteconfig6 --file kglobalshortcutsrc --group services --group cc-pill-ask.desktop --key _launch "$KDEHOTKEY"
fi
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
ok "hotkey registered (System Settings → Shortcuts → cc-pill: Ask, if it needs adjusting)"

# ---------- register hooks ----------
head_ "Registering Claude Code hooks" "Global; existing settings are preserved."
if [ "$WANTVOICE" = "y" ]; then register_hooks "$INSTALL" 1 "$VOICE"; else register_hooks "$INSTALL" 0 "$VOICE"; fi
ok "hooks in ~/.claude/settings.json"

# ---------- optional tmux wrapper ----------
head_ "Optional · tmux wrapper" "Lets the pill send prompts to and open your own interactive claude sessions."
if ui_confirm "Add the claude tmux wrapper to $SHELL_RC?" "y"; then
  if ! grep -q "cc-pill claude wrapper" "$SHELL_RC" 2>/dev/null; then
    if [ "$SHELL_RC" = "$HOME/.zshrc" ]; then
      cat >> "$SHELL_RC" <<'ZRC'

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
    else
      cat >> "$SHELL_RC" <<'BRC'

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
  tmux new-session -s "$name" "command claude $(printf '%q ' "$@")"
}
BRC
    fi
    ok "wrapper added (open a new shell to use it)"
  else
    ok "wrapper already present"
  fi
else
  warn "skipped; card prompt-send and open-terminal need it"
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
  ok "the daemon saw the test event"
else
  warn "test event not confirmed yet, check $DATA/pill.log and: journalctl --user -u cc-pill"
fi
if [ "$WANTVOICE" = "y" ]; then
  NAME_NOW=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$DATA/config.json')))['name'])")
  "$VOICE/.venv/bin/python" "$VOICE/say.py" "Hello, I'm $NAME_NOW. Set up and ready. Your sessions will appear in the panel, and I'll keep you posted out loud." >/dev/null 2>&1 &
fi
python3 - <<'PYEOF'
import json, os, time
d = os.path.expanduser("~/.cc-pill/events")
with open(os.path.join(d, f"evt-{time.time_ns()}.json"), "w") as f:
    json.dump(dict(type="end", t=time.time(), sid="setup-test", cwd="", repo="setup-test", pid=1), f)
PYEOF

echo
VOICE_CMD="./linux/setup.sh"; [ "$PACKAGED" = 1 ] && VOICE_CMD="cc-pill-setup"
NEXT1="Add the widget: right-click your panel → Add Widgets… → search “cc-pill”."
NEXT2="$KDEHOTKEY anywhere: ask for something, a hands-free session starts."
NEXT3="Widget upgraded: restart plasmashell to load it (systemctl --user restart plasma-plasmashell)."
if [ "$HASGUM" = 1 ]; then
  DONE_LINES=("$(gum style --bold --foreground "$GOLD" 'Done. New Claude sessions feed the pill.')")
  [ "$PLACED" = 1 ] || DONE_LINES+=("$(gum style --foreground "$INKDIM" "$NEXT1")")
  DONE_LINES+=("$(gum style --foreground "$INKDIM" "$NEXT2")")
  [ "$WIDGET_UPGRADED" = 1 ] && [ "$PLACED" = 0 ] && DONE_LINES+=("$(gum style --foreground "$INKDIM" "$NEXT3")")
  [ "$WANTVOICE" = "y" ] || DONE_LINES+=("$(gum style --foreground "$INKDIM" "Add the voice later: $VOICE_CMD voice")")
  gum style --border rounded --border-foreground "$OLIVE" --padding "0 3" --margin "0 0 1 0" "${DONE_LINES[@]}"
else
  printf "%sDone.%s New Claude sessions feed the pill.\n" "$G$B" "$N"
  [ "$PLACED" = 1 ] || echo "  $NEXT1"
  echo "  $NEXT2"
  [ "$WIDGET_UPGRADED" = 1 ] && [ "$PLACED" = 0 ] && echo "  $NEXT3"
  [ "$WANTVOICE" = "y" ] || echo "  Add the voice later: $VOICE_CMD voice"
fi
