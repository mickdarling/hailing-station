"""Synthetic process-level proof that only one recovering controller owns the kernel lock."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import sys
import pwd


ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "scripts/codex-recovery/run.py"


@unittest.skipUnless(sys.platform == "darwin", "the runtime control profile is macOS-only")
class CodexRecoveryLockTests(unittest.TestCase):
    def test_one_watcher_holds_lock_through_exec_and_death_releases_it(self):
        with tempfile.TemporaryDirectory(prefix="hailing-codex-lock-") as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            fakebin = root / "bin"
            fakebin.mkdir()
            fake = fakebin / "tmux"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake.chmod(0o700)
            config = root / "config.json"
            status = root / ".codex-recovery-state/status.json"
            config.write_text(json.dumps({
                "version": 1, "target": "tmux:authored-absent",
                "threadId": "11111111-1111-4111-8111-111111111111",
                "binding": "$1@2/%3:4", "firstResponseSeconds": 90, "statusFile": str(status),
            }), encoding="utf-8")
            config.chmod(0o600)
            node = shutil.which("node")
            self.assertIsNotNone(node)
            command = [os.sys.executable, str(WRAPPER), "watch", "--config", str(config), "--node", node]
            env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"])
            child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not status.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(status.exists(), "watch must hold its inherited descriptor and publish status")
                self.assertIsNone(child.poll())
                self.assertEqual(json.loads(status.read_text())["state"], "binding_changed")
                second = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
                self.assertEqual(second.returncode, 75, second.stderr)
                self.assertEqual(json.loads(second.stdout)["state"], "watcher_busy")
            finally:
                child.terminate()
                try:
                    child.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.communicate()
            # The lock file persists, but its kernel lock must not persist after the owner dies.
            retry = command.copy()
            retry[2] = "recover"
            result = subprocess.run(retry, env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout)["state"], "binding_changed")

    def test_status_cannot_replace_the_kernel_lock(self):
        with tempfile.TemporaryDirectory(prefix="hailing-codex-alias-") as temporary:
            root = Path(temporary)
            config = root / "config.json"
            config.write_text(json.dumps({
                "version": 1, "target": "tmux:authored-absent",
                "threadId": "11111111-1111-4111-8111-111111111111",
                "binding": "$1@2/%3:4", "firstResponseSeconds": 90,
                "statusFile": str(config) + ".lock",
            }))
            config.chmod(0o600)
            command = [sys.executable, str(WRAPPER), "watch", "--config", str(config), "--node", shutil.which("node")]
            result = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(Path(str(config) + ".lock").exists())
            self.assertTrue((root / ".codex-recovery-state/lock").is_file())

    def test_wrapper_refuses_an_extended_acl(self):
        with tempfile.TemporaryDirectory(prefix="hailing-codex-acl-") as temporary:
            config = Path(temporary) / "config.json"
            config.write_text("{}")
            config.chmod(0o600)
            name = pwd.getpwuid(os.getuid()).pw_name
            subprocess.run(["/bin/chmod", "+a", f"user:{name} allow read", str(config)], check=True)
            result = subprocess.run([sys.executable, str(WRAPPER), "recover", "--config", str(config),
                                     "--node", shutil.which("node")], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn("codex_recovery_unavailable", result.stderr)
            self.assertFalse((Path(temporary) / ".codex-recovery-state").exists())


if __name__ == "__main__":
    unittest.main()
