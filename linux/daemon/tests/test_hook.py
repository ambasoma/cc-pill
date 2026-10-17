"""hooks/hook.py: finding the claude process behind the hook."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "hook", os.path.join(HERE, "..", "..", "..", "hooks", "hook.py"))
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class ClaudePidTest(unittest.TestCase):
    def test_walks_past_the_shell_claude_runs_hooks_in(self):
        me = os.getppid()
        tree = {me: ("sh", 500), 500: ("claude", 400), 400: ("bash", 1)}
        self.assertEqual(hook.claude_pid(lambda pid: tree.get(pid)), 500)

    def test_direct_parent_when_it_is_not_a_shell(self):
        me = os.getppid()
        tree = {me: ("node", 300), 300: ("sh", 1)}
        self.assertEqual(hook.claude_pid(lambda pid: tree.get(pid)), me)

    def test_no_proc_keeps_the_parent(self):
        self.assertEqual(hook.claude_pid(lambda pid: None), os.getppid())

    def test_never_walks_to_init(self):
        me = os.getppid()
        tree = {me: ("sh", 1)}
        self.assertEqual(hook.claude_pid(lambda pid: tree.get(pid)), me)

    def test_real_proc_reader_is_sane(self):
        info = hook._proc(os.getpid())
        if info is None:
            self.skipTest("no /proc on this platform")
        self.assertEqual(info[1], os.getppid())


if __name__ == "__main__":
    unittest.main()
