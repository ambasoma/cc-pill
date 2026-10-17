<div align="center">

<img src="linux/docs/panel-full.png" alt="A KDE Plasma top panel with the cc-pill widget centred between the pager and the system tray, narrating a working Claude Code session" width="100%">

# cc-pill for KDE Plasma

**A living panel widget for [Claude Code](https://claude.com/claude-code).**

Every Claude Code session on the machine at a glance, in your Plasma panel, in your panel's own font and colours. Live narration of what Claude is doing, an amber "needs you" when it wants permission, and a local neural voice that briefs you in one to three sentences when each turn finishes, blooming the words off the panel as it speaks. Press a hotkey, ask for something in plain language, and a hands-free session spins up in the background and reports back out loud.

*Built for people who run Claude Code while doing other things.*

![KDE Plasma 6](https://img.shields.io/badge/KDE%20Plasma-6-1D99F3?logo=kde&logoColor=white)
![Wayland and X11](https://img.shields.io/badge/Wayland-%26%20X11-2d8a4e)
![Python](https://img.shields.io/badge/Python-3.9%2B%2C%20stdlib%20daemon-3776AB?logo=python&logoColor=white)
![QML](https://img.shields.io/badge/widget-QML%20only-41CD52?logo=qt&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-b8860b)

*Looking for the macOS version? It lives on the [`main`](https://github.com/ambasoma/cc-pill/tree/main) branch.*

</div>

---

cc-pill grew out of running [Moon Kiln](https://moonkiln.com), my handmade clay store, with Claude Code: answering customers, managing orders, printing shipping labels, updating the storefront, planning the work in Linear. Sessions run all day while my hands are busy with clay, and I wanted to know what Claude was up to, and be asked for what it needs, without sitting at a screen. So: a widget that watches every session from the panel, a voice that briefs me when something finishes, and a hotkey to hand Claude the next job. It is a proper Plasma widget: it follows your colour scheme, sits wherever you put it on any panel, and keeps one width while the traces stream so the rest of your panel never shuffles.

**[Watch the demo](linux/docs/cc-pill-kde-demo.mp4)** (2½ minutes, narrated by the pill's own voice): the states, the bloom, the card and the peek, the settings, placement and ask mode.

## The pill

The widget is the signal. One dot per session in the colour scheme's accent, neutral and positive colours; words in the panel's font.

<table align="center">
  <tr>
    <td align="center">
      <img src="linux/docs/panel-working.png" alt="Working: one dot per session and the current narration" width="310"><br>
      <sub><b>Working.</b> Live narration of what Claude is doing, in a fixed-width slot that never shoves its neighbours.</sub>
    </td>
    <td align="center">
      <img src="linux/docs/panel-needs-you.png" alt="Needs you: amber dot and the words needs you" width="310"><br>
      <sub><b>Needs you.</b> A real permission prompt: the scheme's neutral colour and a pulsing dot.</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="linux/docs/bloom.png" alt="The briefing bloom: a window hanging under the panel with the whole spoken summary" width="380"><br>
      <sub><b>Briefing.</b> A window blooms off the panel as the voice starts; the words light up as they are spoken.</sub>
    </td>
    <td align="center">
      <img src="linux/docs/idle-dot.png" alt="No sessions: a single faint dot" width="310"><br>
      <sub><b>No sessions.</b> A faint dot keeps the widget findable and clickable (or hide it entirely).</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="linux/docs/card.png" alt="The session card: rows with state, last briefing and replay, prompt, terminal buttons" width="380"><br>
      <sub><b>The card.</b> Click the pill: one row per session, its last briefing, replay, send-a-prompt and open-terminal buttons, <code>+ NEW</code>, mute.</sub>
    </td>
    <td align="center">
      <img src="linux/docs/peek.png" alt="The peek: the same card in a no-focus window on hover" width="380"><br>
      <sub><b>The peek.</b> Hover (optional): the same card in a window that takes no keyboard focus, so it never interrupts typing.</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="linux/docs/look-porcelain.png" alt="Porcelain look: cream capsule, sun glyph" width="310"><br>
      <sub><b>Porcelain.</b> cc-pill's original look (cream by day, kiln at night, sun and moon, tapping paw), one setting away.</sub>
    </td>
    <td align="center">
      <img src="linux/docs/look-custom.png" alt="Custom look: dark capsule, violet border, serif bold italic" width="310"><br>
      <sub><b>Custom.</b> Your own font, colours, capsule, border and corner radius.</sub>
    </td>
  </tr>
</table>

## What it does

- **Every session.** Keyed by Claude Code's real lifecycle hooks, dead sessions reaped automatically, SSH sessions tagged. One dot each.
- **Live narration.** While Claude works the pill alternates between the project name and what Claude is doing right now ("editing worker.py", "running the tests", "using GitHub"), with elapsed minutes on long turns.
- **Needs you.** Real permission prompts get the amber ping. Idle "waiting for input" nags are filtered out.
- **Spoken briefings.** Your named assistant (default: Jarvis) speaks a 1-3 sentence summary when a turn ends. Never a transcript: code, paths and IDs are described in plain speech, and the persona is yours to choose or generate. Local TTS ([Kokoro](https://github.com/thewh1teagle/kokoro-onnx)), summarized by Haiku through your existing Claude Code login. Plays through PipeWire or PulseAudio; if your music is playing it ducks over MPRIS, speaks, and resumes.
- **The bloom.** The briefing hangs off the panel in a window that takes no focus, words paced to the audio, gone a few seconds after the voice stops. Or widen the pill to fit it, or crawl it through the slot.
- **Courtesy layer.** Silent (text-only bloom) when you are already looking at that session's terminal. Silent for SSH sessions. Re-orients you ("On the api work, ...") when the last briefing you heard was a while ago or from another project.
- **Ask mode.** <kbd>Meta</kbd><kbd>Alt</kbd><kbd>M</kbd> anywhere: a prompt box. Hit <kbd>Enter</kbd> and a detached Claude session starts in your configured directory (permission mode of your choosing, optional extra system instructions), works, and briefs you out loud when done. Idle pill-launched sessions are garbage collected after 30 minutes.
- **Native and configurable.** Panel font and colour scheme by default; every colour, the font, capsule, border, corners, hit area, hover behaviour and placement are yours to change.

## Install

```sh
git clone -b linux-kde https://github.com/ambasoma/cc-pill
cd cc-pill
./linux/setup.sh
```

Setup is a [gum](https://github.com/charmbracelet/gum) powered interactive TUI (with a plain prompt fallback). It asks where to install, which terminal you use, your ask-mode hotkey, how hands-free pill-launched sessions should be (auto-accept edits by default, fully hands-free or normal prompting if you prefer), whether you want the voice, and where on which panel the pill should live. Saying yes to the voice adds the voice picker (with live previews), your assistant's name, its personality (presets, your own text, or described-and-generated by Haiku), and the summarizer model.

It then installs the daemon as a systemd user service (starts at login, auto-restarts), installs the widget, places it on the panel you chose, registers the Claude Code hooks globally and the KDE global shortcut, and optionally adds a tmux wrapper for your interactive sessions so the pill can talk to them.

### Arch Linux

A PKGBUILD lives in `linux/arch` (`cc-pill-kde-git`, built from this branch). It is small on purpose: the daemon, the scripts and the hooks under `/usr/share/cc-pill`, the widget system-wide under `/usr/share/plasma/plasmoids`, a systemd user unit, the ask-mode launcher, and two commands, `cc-pill-setup` and `cc-pill-place`. About 60 KB packed, 213 KiB installed. No Python packages beyond the standard library.

```sh
git clone -b linux-kde https://github.com/ambasoma/cc-pill
cd cc-pill/linux/arch
makepkg -si              # builds and installs with pacman, pulling the dependencies
cc-pill-setup            # then, as your user: config, hooks, hotkey, placement, optional voice
```

`cc-pill-setup` is the same setup as above in packaged mode: no install-location question, the widget and the unit are already in place, and if you say yes to the voice its venv and the Kokoro model go to `~/.cc-pill/voice` (the only part of the install that is not owned by pacman).

| | |
| --- | --- |
| Dependencies | `plasma-workspace` `python` `tmux` `jq` `curl` `bash` |
| Optional | `kdialog` (ask box; `zenity` works too), `gum` (setup TUI), `playerctl` (ducks your music), `pipewire-audio` (voice playback), [`kdotool`](https://aur.archlinux.org/packages/kdotool) from the AUR (silent when that terminal is on screen, raises terminals) |
| Add the voice later | `cc-pill-setup voice` |
| Upgrade | `makepkg -si` again in `linux/arch` (after `git pull`), then `systemctl --user restart cc-pill plasma-plasmashell` |
| Remove | `pacman -R cc-pill-kde-git`; the post-remove note lists the per-user leftovers (`~/.cc-pill`, the hooks in `~/.claude/settings.json`) |

Verified with `makepkg -s`, `namcap` and `pacman -U` against the Arch repositories (Arch Linux ARM, aarch64). The package is not on the AUR yet; `linux/arch` holds the `.SRCINFO` ready for it.

> [!TIP]
> Not sure about the voice? Say no. The install stays small and silent, and `./linux/setup.sh voice` (or `cc-pill-setup voice` from the package) adds the whole voice system any time later.

### Requirements

- **KDE Plasma 6** (Wayland or X11), with `kpackagetool6`
- [Claude Code](https://claude.com/claude-code) installed and logged in
- `python3` (3.9+, with the `venv` module), `tmux`, `jq`, `systemd` user sessions
- Audio for the voice: PipeWire (`pw-play`) or PulseAudio (`paplay`), or ALSA (`aplay`)

Optional, each one unlocks a courtesy:

| Tool | What it adds | Install |
| --- | --- | --- |
| [gum](https://github.com/charmbracelet/gum) | The setup TUI (plain prompts otherwise) | charm repo / `pacman -S gum` |
| `kdialog` | The ask-mode prompt box (falls back to `zenity`) | `kdialog` package |
| `playerctl` | Ducks your music while the voice speaks (MPRIS) | `playerctl` package |
| [kdotool](https://github.com/jinliu/kdotool) | Stays silent when that session's terminal is already focused; raises terminals from the card | from source |

> [!NOTE]
> No accounts, no cloud. Everything runs locally; the only network calls are your own Claude Code sessions and the one-time voice model download (~310 MB, only if you enable the voice). The daemon listens on 127.0.0.1 only and refuses requests from browsers.

## Controls

| Control | What it does |
| --- | --- |
| <kbd>Meta</kbd><kbd>Alt</kbd><kbd>M</kbd> (your choice) | Ask mode: a prompt box; <kbd>Enter</kbd> starts a detached session that is tracked and briefed. |
| Click the pill | The card: one row per session with its last briefing and replay-briefing, send-a-prompt and open-terminal buttons, `+ NEW`, and the mute toggle. |
| Hover the pill | Tooltip with the session summary, or with *peek on hover* the card itself in a no-focus window. |
| <kbd>Enter</kbd> / <kbd>Space</kbd> on the focused widget | Opens the card (the panel can focus widgets from the keyboard). |
| `<yourname>` in the shell | Alias created by setup: `mute`, `on`, `stop`, `last` (replay briefing), `say <text>`, `voice <name>`, `vol`, `speed`. |

## Settings

Right-click the widget → *Configure…*

<p align="center">
  <img src="linux/docs/settings-general.png" alt="General settings: text width, activation, idle dot, daemon port, cats" width="32%">
  <img src="linux/docs/settings-appearance.png" alt="Appearance settings: look, briefing, font, colours, capsule, border" width="32%">
  <img src="linux/docs/settings-placement.png" alt="Placement settings: panel edge, position, Move button" width="32%">
</p>

- **General**: the text width (the widget keeps this many characters while sessions run; longer text glides inside it); activation (a click opens the card; optionally a pointer resting on the widget for a delay you set opens a *peek*, the card in a window that takes no keyboard focus; extra hit area around the pill); whether a faint dot stays when there are no sessions; the daemon port; the cats (Charlie and Lily run laps while Claude works, off by default).
- **Appearance**: the look (**Plasma**, or **Porcelain**: cc-pill's original capsule); how a briefing shows (bloom window, widen the pill, crawl in the slot); the font (the panel's, or any family, size, weight and italic from a font dialog); the colours (follow the scheme, or custom text, accent, needs-you, done, capsule fill and border colours); a tinted capsule behind the words; the border width and the corner radius.
- **Placement**: a panel edge (top, bottom, left, right) and a position (left, centre between two spacers, right before the system tray), then *Move*. Plasma's own way always works too: right-click a panel → *Enter Edit Mode* and drag the widget anywhere.

Switching the Plasma colour scheme restyles the widget instantly. A vertical panel shows the dots only; the words and the card are a click away.

<details>
<summary><b>How placement works</b></summary>
<br>

Setup's placement question and the Placement page both run `linux/bin/cc-pill-place`:

```sh
linux/bin/cc-pill-place --edge top --align center      # also: bottom/left/right, start/end
linux/bin/cc-pill-place --status
```

It drives plasmashell over D-Bus: a new pill is added to the chosen panel (a panel is created at that edge if there is none, and removed again when the pill leaves it), your settings are copied over, the old pill goes away, and "centre" brackets the pill with two spacers. Plasma reads a panel's widget order only at startup, so when the pill has to go anywhere but the end of the panel the shell restarts for a couple of seconds.

A panel that also holds an expanding task manager shares its free space with the spacers, so a true centre needs the task manager on another panel or the pill next to the clock instead.

</details>

## How it works

Two small parts, so any desktop could render the same state:

```mermaid
flowchart LR
    S["every Claude Code session<br/>(any repo, any terminal)"] -- "global hooks" --> E[("~/.cc-pill/events/")]
    E --> D["ccpilld (python, systemd --user)<br/>sessions · narration · moments · GC"]
    D -- "127.0.0.1:17357" --> W["Plasma widget<br/>pill in the panel, bloom, card"]
    D --> J[("~/.cc-pill/state.json")]
    S -- "turn ends" --> H["Haiku rewrites the final<br/>message as a spoken line"]
    H --> K["Kokoro TTS<br/>(local, on-device) → pw-play"]
    K -- "briefing event, bloom synced to audio" --> E
    A["hotkey (kdialog)"] -- "POST /ask" --> D
    D -- "tmux" --> T["detached claude session"]
    T --> S
```

- **`linux/daemon/ccpilld.py`** is the brain: a one-for-one port of the Swift `Store` (session states, needs-you filtering, narration cadence, bloom timing, star and sad moments, dead-process reaping, idle pill-session GC). Stdlib only. Runs as the `cc-pill.service` user unit.
- **`linux/plasmoid/com.ccpill.pill`** is the renderer: a QML-only Plasma 6 applet. The compact representation is the pill, the full representation is the card, and two tooltip-type windows hold the bloom and the peek. It polls the daemon twice a second and draws everything from that state.
- **`voice/`** is the voice worker: Haiku summary, Kokoro synthesis, `pw-play`/`paplay`/`aplay` playback, `playerctl` ducking, `kdotool` for the on-screen courtesy.
- **`linux/bin/ccpill-ask`** is ask mode: a `kdialog` box bound to a KDE global shortcut, posting to the daemon. **`linux/bin/cc-pill-place`** moves the widget between panels.

<details>
<summary><b>The daemon's API</b></summary>
<br>

Localhost only. Every request must carry the header `X-CC-Pill: 1`, and any request with an `Origin` header is refused, so a web page in your browser cannot drive the pill.

| Route | Body | Does |
| --- | --- | --- |
| `GET /state` | | The whole renderer state: `pill`, `sessions`, `briefing`, `moment`, `voice`, `toast`, daemon clock `t` |
| `POST /ask` | `{"text"}` | Start a hands-free session in `home_repo` with the prompt |
| `POST /recap` | `{"sid"}` | Replay that session's last briefing |
| `POST /prompt` | `{"sid","text"}` | Type a prompt into that session's tmux pane |
| `POST /terminal` | `{"sid"}` | Switch/raise/open the terminal for that session |
| `POST /mute` | | Toggle the voice, returns `{"muted"}` |
| `POST /stop` | | Cut the current speech |
| `POST /place` | `{"edge","align"}` | Move the widget (runs `cc-pill-place` detached) |

```sh
curl -s -H 'X-CC-Pill: 1' localhost:17357/state | jq .pill
```

The same state is mirrored to `~/.cc-pill/state.json` on every change, for status bars and scripts that would rather read a file.

</details>

<details>
<summary><b>Configuration reference</b> (<code>~/.cc-pill/config.json</code>)</summary>
<br>

Setup writes this for you; edit and restart the daemon (`systemctl --user restart cc-pill`) to pick it up.

| Key | Default | Meaning |
| --- | --- | --- |
| `name` | `"Jarvis"` | Your assistant's name (spoken, shown in the card, shell alias). |
| `home_repo` | your home | Directory ask-mode sessions start in. |
| `permission_mode` | `"acceptEdits"` | How pill-launched sessions run: `acceptEdits` (file edits auto-approved), `bypass` (fully hands-free), `default` (normal prompting). |
| `terminal` | `konsole` | Terminal command for the card's open-terminal button (`konsole`, `kitty`, `alacritty`, `wezterm`, `ghostty`, `foot`, `gnome-terminal`, `xterm`, or any command that takes `-e`). |
| `daemon_port` | `17357` | Port the daemon binds on 127.0.0.1. Change the widget's port in its settings to match. |
| `hotkey` | `"meta+alt+m"` | Ask-mode shortcut (written to KDE global shortcuts by setup). |
| `pill_gc_minutes` | `30` | Minutes before an idle pill-launched session is collected (`0` disables). |
| `pill_system_prompt` | `""` | Extra system instructions appended to pill-launched sessions. |
| `enabled` | | Voice on/off (what `mute`/`on` toggle). |
| `voice`, `speed`, `volume` | | Kokoro voice and delivery. |
| `summarizer_model` | `haiku` | Model that writes the spoken line. |
| `claude_bin` | auto | Path to the `claude` binary if not on the default PATH. |

The widget's own settings (look, font, colours, placement, activation) live in Plasma's applet config, through the widget's *Configure…* dialog.

Logs live at `~/.cc-pill/pill.log` (the daemon narrates everything it does) and `voice/spool/voice.log`.

</details>

<details>
<summary><b>Troubleshooting</b></summary>
<br>

```sh
systemctl --user status cc-pill          # is the daemon up
journalctl --user -u cc-pill -n 50        # its stderr
tail -f ~/.cc-pill/pill.log               # every event it applied
tail -f <install>/voice/spool/voice.log   # what the voice said, or why it stayed quiet
```

- **Widget shows only a faint dot.** No sessions yet. Start `claude` somewhere; the dot takes the session's colour. (Untick *No sessions: keep a faint dot* to hide it entirely.) If the tooltip says the daemon isn't running, see the service status above.
- **Widget port mismatch.** Right-click the widget → Configure → Daemon port must equal `daemon_port` in the config.
- **Card buttons do nothing for your own sessions.** Prompt-send and open-terminal need the session inside tmux: accept the tmux wrapper in setup, then open a new shell.
- **No audio.** `pw-play`, `paplay` or `aplay` must be on the PATH of the voice worker (which runs from the Claude Code hook, in your login environment).
- **Hotkey doesn't fire.** System Settings → Shortcuts → look for *cc-pill: Ask* and assign it there. Setup registers it through `kglobalshortcutsrc` and the `.desktop` file's `X-KDE-Shortcuts`; a fresh login always picks it up.
- **Terminal doesn't come to the front.** Wayland lets only the compositor raise windows. Install `kdotool`; without it the daemon opens a new terminal window attached to the tmux session instead.
- **After upgrading the widget**, restart the shell: `systemctl --user restart plasma-plasmashell`.

</details>

<details>
<summary><b>Uninstall</b></summary>
<br>

```sh
systemctl --user disable --now cc-pill.service
rm ~/.config/systemd/user/cc-pill.service
kpackagetool6 --type Plasma/Applet --remove com.ccpill.pill
rm ~/.local/share/applications/cc-pill-ask.desktop
rm -rf ~/.cc-pill            # events, state, config, logs
```

Then remove the `cc-pill` hook entries from `~/.claude/settings.json` and, if you accepted it, the tmux wrapper line from your shell rc.

</details>

## Not yet

- **No voice input in ask mode.** Ask mode is typed. A local speech-to-text model is a candidate for a later version.
- **Verified so far** in a Plasma 6.6 session (Ubuntu 26.04, Frameworks 6.24, X11): every pill state and look, the bloom, the card and peek, placement on every edge, the settings pages, the systemd service, hooks and hotkey registration, and `linux/setup.sh` end to end. Not yet exercised on real hardware: the Wayland global shortcut, audio playback and ducking.

## Developing

```sh
python3 -m unittest discover linux/daemon/tests        # daemon, hook and placement tests (no tmux, no audio needed)
CC_PILL_HOME=/tmp/pill python3 linux/daemon/ccpilld.py # run against a scratch data dir
kpackagetool6 --type Plasma/Applet --upgrade linux/plasmoid/com.ccpill.pill && systemctl --user restart plasma-plasmashell
```

## License

MIT
