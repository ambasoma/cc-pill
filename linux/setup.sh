#!/bin/bash
# cc-pill interactive setup for Linux, KDE Plasma 6.
#   ./linux/setup.sh          full setup
#   ./linux/setup.sh voice    add (or reconfigure) the voice later
#   ./linux/setup.sh containers [name...]
#                             wire Claude Code inside LXD containers to the pill
#   ./linux/setup.sh update   bring the install up to date with this checkout
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
cfg_merge() {  # cfg_merge <json object to set> [<json object of defaults>]
  python3 - "$DATA/config.json" "$1" "${2:-null}" <<'PYEOF'
import json, os, sys
p, updates, defaults = sys.argv[1:4]
cfg = {}
if os.path.exists(p):
    try:
        with open(p) as f:
            cfg = json.load(f)
    except ValueError as e:
        sys.exit(f"{p} is not valid JSON ({e}); fix it and run setup again")
cfg.update(json.loads(updates))
for k, v in (json.loads(defaults) or {}).items():
    cfg.setdefault(k, v)
# Readable by this user only, from the first byte: it holds the container tokens.
tmp = p + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PYEOF
}

cfg_set() {  # cfg_set key json_value
  cfg_merge "{\"$1\": $2}"
}

register_hooks() {  # register_hooks <install> <voice_on: 1|0> <voice dir>
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, os, sys
install, voice_on, vdir = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
if os.path.exists(p) and not os.path.exists(p + ".pre-cc-pill"):
    import shutil
    shutil.copy2(p, p + ".pre-cc-pill")   # the first time only: the untouched original
cfg = {}
if os.path.exists(p):
    try:
        with open(p) as f:
            cfg = json.load(f)
    except ValueError as e:
        sys.exit(f"~/.claude/settings.json is not valid JSON ({e}); fix it and run setup again")
    if not isinstance(cfg, dict):
        sys.exit("~/.claude/settings.json is not a JSON object; fix it and run setup again")
hooks = cfg.setdefault("hooks", {})
pill = install + "/hooks/hook.py"
voice = vdir + "/hook.py"
# 5 s, like the container hooks (cc-pill-containers): both return in milliseconds
def cmd(script, mode): return {"type": "command", "command": f'python3 "{script}" {mode}', "timeout": 5}
ours = {
    "SessionStart": [cmd(pill, "start")],
    "UserPromptSubmit": [cmd(pill, "prompt")],
    "PreToolUse": [cmd(pill, "tool")],
    "SessionEnd": [cmd(pill, "end")],
    "Stop": [cmd(pill, "stop")] + ([cmd(voice, "stop")] if voice_on else []),
    "Notification": [cmd(pill, "notify")] + ([cmd(voice, "notify")] if voice_on else []),
}
# Keep every hook that isn't ours; replace earlier copies of ours (a re-run,
# the voice switched on or off, an install that moved) instead of piling
# them up. Ours: a hook.py that sits in a cc-pill install (one with the
# daemon two levels up), not any script that happens to share the name.
import re
def is_ours(h):
    m = re.fullmatch(r'python3 "(.+)/(hooks|voice)/hook\.py" (start|prompt|tool|end|stop|notify)',
                     str(h.get("command", "")))
    if not m:
        return False
    root = m.group(1)
    return root == install or os.path.exists(os.path.join(root, "linux", "daemon", "ccpilld.py")) \
        or os.path.realpath(os.path.join(root, "voice")) == os.path.realpath(vdir)
for event, cmds in ours.items():
    groups = []
    for g in hooks.get(event) or []:
        inner = [h for h in g.get("hooks", []) if not is_ours(h)]
        if inner:
            groups.append(dict(g, hooks=inner))
    groups.append({"hooks": cmds})
    hooks[event] = groups
# Through a temp file with the original's mode: never a half-written settings.json.
tmp = p + ".cc-pill-tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
if os.path.exists(p):
    os.chmod(tmp, os.stat(p).st_mode & 0o7777)
os.replace(tmp, p)
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
  # Check for the packages, not just the interpreter: a venv whose creation
  # was cut short has bin/python but no pip and nothing installed. Running
  # venv again over it fills in what is missing.
  if .venv/bin/python -c "import kokoro_onnx, soundfile" 2>/dev/null; then
    ok "venv exists"
  else
    python3 -m venv .venv || die "python3 -m venv failed ($(pkg_hint python3-venv))"
    ui_spin "Installing the speech engine..." .venv/bin/pip -q install kokoro-onnx soundfile \
      || die "installing kokoro-onnx and soundfile failed; re-run: ./linux/setup.sh voice"
    .venv/bin/python -c "import kokoro_onnx, soundfile" 2>/dev/null \
      || die "the speech engine did not import after installing; re-run: ./linux/setup.sh voice"
    ok "venv ready"
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
  local VNAME="bm_george"   # the voice name; the caller keeps the voice dir in its own variable
  while true; do
    local choice
    ui_choose choice "Pick a voice to hear" "${OPTS[@]}"
    VNAME="${choice%% *}"
    ui_spin "$VNAME is warming up..." true
    play_sample "$VNAME"
    ui_confirm "Keep $VNAME?" "y" && break
  done
  ok "voice: $VNAME"

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
  CCPILL_PERSONA="$PERSONA" python3 - "$vdir" "$NAME" <<'PYEOF'
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
  cfg_set voice "\"$VNAME\""
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

lxd_containers() {  # running LXD containers with a Claude Code install, one per line
  command -v lxc >/dev/null || return 0
  local c
  for c in $(lxc list --format csv -c n,s 2>/dev/null | awk -F, '$2=="RUNNING"{print $1}'); do
    # root only: that is the user the wiring (and the card's tmux actions) use
    lxc exec "$c" -- test -d /root/.claude 2>/dev/null && echo "$c"
  done
}

wire_containers() {  # wire_containers <install> [name...]  (asks per container when none given)
  local install="$1"; shift
  local picked=("$@") c
  if [ "${#picked[@]}" = 0 ]; then
    for c in ${CONTAINERS-$(lxd_containers)}; do   # the list found already, if any
      ui_confirm "Wire the Claude sessions in container $c?" "y" && picked+=("$c")
    done
  fi
  if [ "${#picked[@]}" = 0 ]; then
    warn "no containers wired"
    return 0
  fi
  if python3 "$install/linux/bin/cc-pill-containers" add "${picked[@]}"; then
    ok "containers wired: ${picked[*]}"
  else
    warn "could not wire every container; retry with: ./linux/setup.sh containers"
  fi
}

# ================= update subcommand =================
# Bring an install up to date with this checkout: copy the code over (never
# deleting, never touching config, logs or the voice runtime), then upgrade
# the widget, restart the daemon and re-push the container hook, each only
# when its files changed.
installed_at() {  # the install dir the running service uses
  local unit="$HOME/.config/systemd/user/cc-pill.service" p
  p=$(sed -n 's|^ExecStart=.* \(/.*\)/linux/daemon/ccpilld\.py.*|\1|p' "$unit" 2>/dev/null | head -1)
  [ -n "$p" ] || p=$(python3 -c "import json,os;print(os.path.dirname(json.load(open(os.path.expanduser('$DATA/config.json'))).get('speaker','')))" 2>/dev/null || true)
  echo "$p"
}

if [ "$MODE" = "update" ]; then
  [ -f "$DATA/config.json" ] || die "run ./linux/setup.sh (full) first"
  banner
  if [ "$PACKAGED" = 1 ]; then
    INSTALL="$REPO"
  else
    INSTALL=$(installed_at)
    [ -n "$INSTALL" ] && [ -d "$INSTALL/linux" ] || die "can't find the install (no cc-pill.service); run ./linux/setup.sh"
  fi
  head_ "Updating cc-pill" "From $REPO to $INSTALL"
  CHANGED=""
  if [ "$INSTALL" != "$REPO" ]; then
    command -v rsync >/dev/null || die "rsync is needed ($(pkg_hint rsync))"
    # Code only: the install dir is also the data dir (config, events,
    # state, logs) and holds the voice runtime; none of that is touched,
    # and nothing there is ever deleted.
    CHANGED=$(rsync -a --checksum --itemize-changes \
      --exclude .git --exclude '__pycache__' --exclude 'app/.build' --exclude 'app/Pill.app' \
      --exclude '/config.json' --exclude '/events' --exclude '/state.json' --exclude '/pill.log' \
      --exclude 'voice/.venv' --exclude 'voice/models' --exclude 'voice/spool' \
      --exclude 'voice/prompt.txt' --exclude 'voice/.off' \
      "$REPO/" "$INSTALL/" | awk '$1 ~ /^>f/ {print $2}')
    if [ -n "$CHANGED" ]; then
      ok "copied $(echo "$CHANGED" | wc -l) changed file(s)"
    else
      ok "the install already matches this checkout"
    fi
  else
    # Installed in place: everything in the checkout is live; act on all of it.
    CHANGED=$(printf '%s\n' linux/plasmoid/ linux/daemon/ hooks/hook.py)
    ok "installed in place: nothing to copy"
  fi
  changed() { echo "$CHANGED" | grep -q "^$1"; }

  WIDGET_DONE=0
  if changed linux/plasmoid/; then
    if [ "$PACKAGED" = 1 ]; then
      ok "widget: updated by your package manager"
    elif kpackagetool6 --type Plasma/Applet --upgrade "$INSTALL/linux/plasmoid/com.ccpill.pill" >/dev/null 2>&1 \
       || kpackagetool6 --type Plasma/Applet --install "$INSTALL/linux/plasmoid/com.ccpill.pill" >/dev/null 2>&1; then
      ok "widget upgraded"
      WIDGET_DONE=1
    else
      warn "widget upgrade failed: kpackagetool6 --type Plasma/Applet --upgrade $INSTALL/linux/plasmoid/com.ccpill.pill"
    fi
  fi

  # The voice worker and the host hook start fresh for every event: only the
  # daemon holds old code until restarted.
  if changed linux/daemon/; then
    if systemctl --user restart cc-pill.service; then ok "daemon restarted"; else warn "could not restart cc-pill.service"; fi
  fi

  if changed hooks/hook.py; then
    WIRED=$(python3 -c "import json,os;print(' '.join(sorted(json.load(open(os.path.expanduser('$DATA/config.json'))).get('containers') or {})))" 2>/dev/null || true)
    if [ -n "$WIRED" ]; then
      # shellcheck disable=SC2086
      if python3 "$INSTALL/linux/bin/cc-pill-containers" add $WIRED --no-restart; then
        ok "hook re-pushed to: $WIRED"
      else
        warn "could not re-push the hook; retry: ./linux/setup.sh containers $WIRED"
      fi
    fi
  fi

  if [ "$WIDGET_DONE" = 1 ]; then
    # Plasma loads widget code once: the new widget shows after a shell restart.
    if ui_confirm "Restart plasmashell now to load the new widget? (the panel blinks for a couple of seconds)" "y"; then
      systemctl --user restart plasma-plasmashell && ok "plasmashell restarted"
    else
      warn "the new widget loads at the next login, or: systemctl --user restart plasma-plasmashell"
    fi
  fi
  echo
  ok "${B}Up to date.${N}"
  echo
  exit 0
fi

# ================= containers subcommand =================
if [ "$MODE" = "containers" ]; then
  [ -f "$DATA/config.json" ] || die "run ./linux/setup.sh (full) first"
  command -v lxc >/dev/null || die "the lxc client is not installed"
  banner
  head_ "LXD containers" "Claude Code sessions inside containers report to the pill over the LXD bridge."
  # the installed copy's hook, the one the running daemon matches
  WIRE_FROM=$(installed_at); [ -n "$WIRE_FROM" ] && [ -d "$WIRE_FROM/hooks" ] || WIRE_FROM="$REPO"
  wire_containers "$WIRE_FROM" "${@:2}"
  exit 0
fi

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

# ---------- 2. hotkey ----------
head_ "2 · Alfred hotkey" "Press it anywhere to ask Alfred about your sessions, or to pass a message to one."
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

# ---------- 3. pill sessions ----------
head_ "3 · Sessions started through the API" "How hands-free should sessions started with POST /ask be?"
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

# ---------- 4. voice ----------
head_ "4 · Voice briefings" "A local neural voice speaks a short summary when each turn finishes. One-time ~350MB model download; skip now and add later with: ./linux/setup.sh voice"
WANTVOICE="n"
ui_confirm "Enable the voice?" "y" && WANTVOICE="y"

# ---------- write base config ----------
BASE_CFG=$(CCPILL_SP="$SYSPROMPT" python3 - "$WORKDIR" "$VOICE" "$PERM" "$HOTKEY" <<'PYEOF'
import json, os, sys
workdir, vdir, perm, hotkey = sys.argv[1:5]
print(json.dumps({
    "home_repo": workdir,
    "permission_mode": perm,
    "hotkey": hotkey,
    "pill_gc_minutes": 30,
    "pill_system_prompt": os.environ.get("CCPILL_SP", ""),
    "speaker": vdir,
}))
PYEOF
)
cfg_merge "$BASE_CFG" '{"daemon_port": 17357, "name": "Jarvis", "enabled": false}'
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
  chmod +x "$INSTALL/linux/daemon/ccpilld.py" "$INSTALL/linux/bin/ccpill-ask" "$INSTALL/linux/bin/cc-pill-place" "$INSTALL/linux/bin/cc-pill-containers" "$INSTALL/voice/pillctl" 2>/dev/null || true
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

# ---------- LXD containers ----------
CONTAINERS=$(lxd_containers)
if [ -n "$CONTAINERS" ]; then
  head_ "LXD containers" "Claude Code inside these containers can report to the pill over the LXD bridge. Later: ./linux/setup.sh containers"
  wire_containers "$INSTALL"
fi

# ---------- optional tmux wrapper ----------
head_ "Optional · tmux wrapper" "Lets the pill send prompts to your own interactive claude sessions."
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
  warn "skipped; the card's send-a-prompt needs it"
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
