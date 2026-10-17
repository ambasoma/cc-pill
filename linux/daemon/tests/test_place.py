"""Tests for linux/bin/cc-pill-place: the pure planning and INI parts."""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "bin", "cc-pill-place")
spec = importlib.util.spec_from_loader("ccpill_place", loader=None, origin=SCRIPT)
place = importlib.util.module_from_spec(spec)
with open(SCRIPT) as f:
    exec(compile(f.read(), SCRIPT, "exec"), place.__dict__)


STOCK = ["1", "2", "3", "4", "5", "6", "7"]  # a stock Plasma bottom panel
STOCK_TYPES = {
    "1": "org.kde.plasma.kickoff", "2": "org.kde.plasma.pager", "3": "org.kde.plasma.icontasks",
    "4": "org.kde.plasma.marginsseparator", "5": "org.kde.plasma.systemtray",
    "6": "org.kde.plasma.digitalclock", "7": "org.kde.plasma.showdesktop",
}


class PlanOrderTest(unittest.TestCase):
    def plan(self, align, spacers=(), order=None, types=None):
        order = list(order if order is not None else STOCK) + ["9"] + list(spacers)
        t = dict(types if types is not None else STOCK_TYPES)
        t["9"] = place.PILL
        for s in spacers:
            t[s] = place.SPACER
        return place.plan_order(order, "9", list(spacers), align, t)

    def test_start_goes_first(self):
        self.assertEqual(self.plan("start"), ["9"] + STOCK)

    def test_end_sits_before_the_tray_cluster(self):
        self.assertEqual(self.plan("end"), ["1", "2", "3", "9", "4", "5", "6", "7"])

    def test_center_brackets_with_spacers_after_task_manager(self):
        self.assertEqual(self.plan("center", ("8", "10")), ["1", "2", "3", "8", "9", "10", "4", "5", "6", "7"])

    def test_center_without_task_manager_goes_before_cluster(self):
        order = ["1", "2", "5", "6"]
        self.assertEqual(self.plan("center", ("8", "10"), order), ["1", "2", "8", "9", "10", "5", "6"])

    def test_end_on_panel_without_cluster_appends(self):
        self.assertEqual(self.plan("end", (), ["1", "3"]), ["1", "3", "9"])

    def test_already_placed_is_stable(self):
        order = ["1", "2", "3", "9", "4", "5", "6", "7"]
        t = dict(STOCK_TYPES, **{"9": place.PILL})
        self.assertEqual(place.plan_order(order, "9", [], "end", t), order)

    def test_old_spacers_and_pills_are_dropped(self):
        # a second pill id would have been removed by the shell script; only
        # the new one and its spacers are kept in place
        order = ["1", "8", "9", "10", "5"]
        t = {"1": "org.kde.plasma.kickoff", "8": place.SPACER, "9": place.PILL, "10": place.SPACER, "5": "org.kde.plasma.systemtray"}
        self.assertEqual(place.plan_order(order, "9", ["8", "10"], "start", t), ["8", "9", "10", "1", "5"])


INI = """[Containments][2]
location=4
plugin=org.kde.panel

[Containments][2][Applets][3]
immutability=1
plugin=org.kde.plasma.kickoff

[Containments][2][Applets][4]
plugin=com.ccpill.pill

[Containments][2][Applets][4][Configuration][General]
slotChars=30

[Containments][2][General]
AppletOrder=3;4

[Containments][7]
plugin=org.kde.desktopcontainment

[ScreenMapping]
screenMapping=
"""


class AppletsrcTest(unittest.TestCase):
    def test_parse(self):
        c = place.parse_appletsrc(INI)
        self.assertEqual(c["2"]["order"], ["3", "4"])
        self.assertEqual(c["2"]["applets"], {"3": "org.kde.plasma.kickoff", "4": "com.ccpill.pill"})
        self.assertEqual(c["7"]["order"], [])

    def test_rewrite_existing_order(self):
        out = place.rewrite_order(INI, "2", ["4", "3"])
        self.assertIn("[Containments][2][General]\nAppletOrder=4;3\n", out)
        self.assertEqual(out.count("AppletOrder="), 1)
        # nothing else moved
        self.assertIn("slotChars=30", out)
        self.assertIn("[ScreenMapping]\nscreenMapping=", out)

    def test_rewrite_adds_missing_group(self):
        out = place.rewrite_order(INI, "7", ["1", "2"])
        self.assertIn("[Containments][7][General]\nAppletOrder=1;2\n", out)
        self.assertEqual(place.parse_appletsrc(out)["7"]["order"], ["1", "2"])

    def test_rewrite_adds_missing_key_in_existing_group(self):
        ini = "[Containments][2][General]\nfoo=bar\n\n[Other]\nx=1\n"
        out = place.rewrite_order(ini, "2", ["5"])
        self.assertIn("[Containments][2][General]\nfoo=bar\nAppletOrder=5\n", out)


class ShellEnvTest(unittest.TestCase):
    def test_bus_defaults_from_runtime_dir(self):
        saved = {k: os.environ.pop(k, None) for k in ("XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")}
        try:
            os.environ["XDG_RUNTIME_DIR"] = "/run/user/42"
            env = place.shell_env()
            self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/user/42/bus")
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
