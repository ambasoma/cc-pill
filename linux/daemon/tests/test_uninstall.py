"""setup.sh uninstall, in a scratch home: it removes what setup put there and
nothing else. Every system tool it calls is a stub first on PATH (systemctl,
qdbus6, kpackagetool6, kbuildsycoca6), so the real daemon, panel and widget
are never touched; kwriteconfig6 is the real one, on the scratch config."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

WRAPPER = """
# --- cc-pill claude wrapper: interactive claude runs inside tmux so the
# pill can target it. Scripted calls and in-tmux runs pass straight through.
claude() {
  if [[ -n "$PILL_INNER" || -n "$TMUX" || ! -t 0 || ! -t 1 ]] \\
     || [[ " $* " == *" -p "* || " $* " == *" --print "* ]]; then
    command claude "$@"
    return
  fi
  local base="cc-$(basename "$PWD" | tr -cs 'A-Za-z0-9_-' '-')"
  base="${base%-}"
  local name="$base" n=2
  while tmux has-session -t "=$name" 2>/dev/null; do
    name="$base-$((n++))"
  done
  tmux new-session -s "$name" "command claude $(printf '%q ' "$@")"
}"""


def read(path):
    with open(path) as f:
        return f.read()


class UninstallSandbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ccpill-uninstall-")
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.tmp, "bin")
        self.calls = os.path.join(self.tmp, "calls.log")
        os.makedirs(self.bin)
        for tool, body in (("systemctl", ""), ("kpackagetool6", 'rm -rf "$HOME/.local/share/plasma/plasmoids/com.ccpill.pill"'),
                           ("qdbus6", 'echo "${CCPILL_STUB_WIDGETS:-3}"'), ("kbuildsycoca6", "")):
            path = os.path.join(self.bin, tool)
            with open(path, "w") as f:
                f.write(f'#!/bin/sh\necho "{tool} $*" >> "{self.calls}"\n{body}\n')
            os.chmod(path, 0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def path(self, *p):
        return os.path.join(self.home, *p)

    def write(self, rel, text):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        return p

    def installed(self, install):
        """A home as setup leaves it, plus things of the user's that must stay."""
        stub = os.path.join(install, "linux", "bin", "cc-pill-containers")
        os.makedirs(os.path.dirname(stub), exist_ok=True)
        with open(stub, "w") as f:   # records the call instead of running lxc
            f.write(f'import sys\nopen("{self.calls}", "a").write("cc-pill-containers " + " ".join(sys.argv[1:]) + "\\n")\n')
        os.makedirs(os.path.join(install, "linux", "daemon"), exist_ok=True)
        open(os.path.join(install, "linux", "daemon", "ccpilld.py"), "a").close()
        os.makedirs(self.path(".cc-pill", "voice", ".venv"), exist_ok=True)
        self.write(".cc-pill/config.json", json.dumps({"containers": {"web-dev": "t", "play-dev": "u"}}))
        self.write(".config/systemd/user/cc-pill.service",
                   f"[Service]\nExecStart=/usr/bin/env python3 {install}/linux/daemon/ccpilld.py\n")
        self.write(".local/share/applications/cc-pill-ask.desktop", "[Desktop Entry]\n")
        os.makedirs(self.path(".local/share/plasma/plasmoids/com.ccpill.pill"), exist_ok=True)
        self.write(".config/kglobalshortcutsrc", "[services][cc-pill-ask.desktop]\n_launch=Ctrl+Shift+Space\n\n"
                                                "[services][org.kde.konsole.desktop]\n_launch=Ctrl+Alt+T\n")
        ours = {e: [{"hooks": [{"type": "command", "command": f'python3 "{install}/hooks/hook.py" {m}', "timeout": 5}]}]
                for e, m in (("SessionStart", "start"), ("PreToolUse", "tool"), ("Stop", "stop"))}
        ours["Stop"][0]["hooks"].append({"type": "command", "command": f'python3 "{install}/voice/hook.py" stop'})
        ours["PreToolUse"].insert(0, {"matcher": "Edit", "hooks": [{"type": "command", "command": "ruby guard.rb"}]})
        ours["Notification"] = [{"hooks": [{"type": "command", "command": 'python3 "/home/u/dotfiles/hooks/hook.py" notify'}]}]
        self.write(".claude/settings.json", json.dumps({"model": "opus", "hooks": ours}))
        os.chmod(self.path(".claude/settings.json"), 0o600)
        self.write(".claude/settings.json.pre-cc-pill", "{}")
        self.write(".bashrc", f"export EDITOR=vim\nalias ll='ls -l'\nalias alfred='{self.path('.cc-pill', 'voice')}/pillctl'"
                              f"\n{WRAPPER}\nalias gs='git status'\n")

    def run_setup(self, setup, *args, widgets=3):
        env = dict(os.environ, HOME=self.home, CCPILL_STUB_WIDGETS=str(widgets), XDG_CONFIG_HOME=self.path(".config"),
                   XDG_DATA_HOME=self.path(".local/share"), SHELL="/bin/bash",
                   PATH=self.bin + ":" + os.environ["PATH"])
        # never let the real tools run: the stubs must win
        for tool in ("systemctl", "qdbus6", "kpackagetool6", "kbuildsycoca6"):
            found = shutil.which(tool, path=env["PATH"])
            self.assertEqual(found, os.path.join(self.bin, tool), f"{tool} is not the stub")
        return subprocess.run(["bash", setup, "uninstall", *args], env=env, capture_output=True, text=True,
                              timeout=60, input="")

    def calls_made(self):
        return read(self.calls) if os.path.exists(self.calls) else ""

    def test_dry_run_changes_nothing(self):
        self.installed(self.path(".cc-pill"))
        before = {p: open(self.path(p)).read() for p in (".bashrc", ".claude/settings.json", ".config/kglobalshortcutsrc")}
        p = self.run_setup(os.path.join(REPO, "linux", "setup.sh"), "--dry-run")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("4 cc-pill hook entries", p.stdout)   # 3 pill hooks and the voice hook
        self.assertIn("the 'alfred' alias and the claude tmux wrapper", p.stdout)
        self.assertIn("container web-dev", p.stdout)
        for rel, text in before.items():
            self.assertEqual(read(self.path(rel)), text, rel)
        self.assertTrue(os.path.isdir(self.path(".cc-pill")))
        self.assertNotIn("systemctl", self.calls_made())
        self.assertNotIn("cc-pill-containers", self.calls_made())

    def test_no_answer_means_no(self):
        self.installed(self.path(".cc-pill"))
        p = self.run_setup(os.path.join(REPO, "linux", "setup.sh"))      # empty stdin: the default, no
        self.assertIn("nothing changed", p.stdout)
        self.assertTrue(os.path.isdir(self.path(".cc-pill")))
        self.assertTrue(os.path.exists(self.path(".config/systemd/user/cc-pill.service")))

    def test_removes_ours_and_keeps_everything_else(self):
        install = self.path(".cc-pill")
        self.installed(install)
        p = self.run_setup(os.path.join(REPO, "linux", "setup.sh"), "--yes")
        out = p.stdout + p.stderr
        self.assertEqual(p.returncode, 0, out)
        calls = self.calls_made()
        # the containers, through cc-pill-containers remove
        self.assertIn("cc-pill-containers remove play-dev web-dev --no-restart", calls)
        # the daemon
        self.assertIn("systemctl --user disable --now cc-pill.service", calls)
        self.assertFalse(os.path.exists(self.path(".config/systemd/user/cc-pill.service")))
        # the widget: removed from the panels (the script asked to apply), then the package
        self.assertIn("evaluateScript", calls)
        self.assertIn("if (1)", calls.replace("\n", " "))
        self.assertIn("kpackagetool6 --type Plasma/Applet --remove com.ccpill.pill", calls)
        # the hotkey: desktop file, and only our shortcut entry (real kwriteconfig6)
        self.assertFalse(os.path.exists(self.path(".local/share/applications/cc-pill-ask.desktop")))
        shortcuts = read(self.path(".config/kglobalshortcutsrc"))
        if shutil.which("kwriteconfig6"):
            self.assertNotIn("Ctrl+Shift+Space", shortcuts)
        self.assertIn("_launch=Ctrl+Alt+T", shortcuts)
        # Claude settings: only our four entries went; the user's hooks and keys stay; mode kept
        with open(self.path(".claude/settings.json")) as f:
            s = json.load(f)
        self.assertEqual(s["model"], "opus")
        cmds = [h["command"] for g in sum(s["hooks"].values(), []) for h in g["hooks"]]
        self.assertEqual(sorted(cmds), sorted(["ruby guard.rb", 'python3 "/home/u/dotfiles/hooks/hook.py" notify']))
        self.assertEqual(oct(os.stat(self.path(".claude/settings.json")).st_mode & 0o777), "0o600")
        self.assertFalse(os.path.exists(self.path(".claude/settings.json.pre-cc-pill")))
        backups = [n for n in os.listdir(self.path(".claude")) if "before-cc-pill-uninstall" in n]
        self.assertEqual(len(backups), 1)
        # the rc: alias and wrapper gone, the rest byte for byte
        self.assertEqual(read(self.path(".bashrc")), "export EDITOR=vim\nalias ll='ls -l'\nalias gs='git status'\n")
        self.assertTrue([n for n in os.listdir(self.home) if n.startswith(".bashrc.before-cc-pill-uninstall")])
        # the install and data dir
        self.assertFalse(os.path.exists(install))
        self.assertIn("cc-pill is uninstalled", out)

    def test_an_install_in_the_checkout_keeps_the_checkout(self):
        repo = os.path.join(self.tmp, "checkout")
        shutil.copytree(os.path.join(REPO, "linux"), os.path.join(repo, "linux"))
        self.installed(repo)
        p = self.run_setup(os.path.join(repo, "linux", "setup.sh"), "--yes")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(os.path.isfile(os.path.join(repo, "linux", "setup.sh")), "the checkout must stay")
        self.assertFalse(os.path.exists(self.path(".cc-pill")), "the data dir goes")

    def test_a_wrapper_that_was_edited_is_left_alone(self):
        self.installed(self.path(".cc-pill"))
        edited = read(self.path(".bashrc")).replace("tmux new-session", "my-own-launcher")
        with open(self.path(".bashrc"), "w") as f:
            f.write(edited)
        p = self.run_setup(os.path.join(REPO, "linux", "setup.sh"), "--yes")
        self.assertIn("not the block setup writes: left as it is", p.stdout + p.stderr)
        self.assertIn("my-own-launcher", read(self.path(".bashrc")))
        self.assertNotIn("alias alfred=", read(self.path(".bashrc")))

    def test_nothing_installed(self):
        os.makedirs(self.home)
        p = self.run_setup(os.path.join(REPO, "linux", "setup.sh"), "--yes", widgets=0)
        self.assertIn("nothing of cc-pill found", p.stdout)
        calls = self.calls_made()
        # only the read-only question to Plasma ("how many of ours?"), nothing removed
        self.assertNotIn("if (1)", calls.replace("\n", " "))
        for tool in ("systemctl", "kpackagetool6", "kbuildsycoca6", "cc-pill-containers"):
            self.assertNotIn(tool, calls)


if __name__ == "__main__":
    unittest.main()
