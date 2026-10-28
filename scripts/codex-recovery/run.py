#!/usr/bin/env python3
"""Hold a kernel lock through exec, so watchdog death never leaves a stale PID lock (#1002)."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import re


def acl_free(path: Path) -> None:
    result = subprocess.run(["/bin/ls", "-lde", str(path)], capture_output=True, text=True, timeout=2, check=True)
    if any(re.match(r"\s*\d+:", line) for line in result.stdout.splitlines()):
        raise ValueError("extended_acl")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("status", "recover", "watch", "host"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--node", default=shutil.which("node"))
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise ValueError("unsupported_platform")
    node = Path(args.node or "")
    if not node.is_absolute() or not node.is_file() or not args.config.is_absolute():
        raise ValueError("invalid_runtime_path")
    source = args.config.lstat()
    parent = args.config.parent.lstat()
    if (not stat.S_ISREG(source.st_mode) or source.st_uid != os.getuid() or source.st_mode & 0o077
            or not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077):
        raise ValueError("unsafe_config")
    acl_free(args.config)
    acl_free(args.config.parent)
    if args.mode != "status":
        state_dir = args.config.parent / ".codex-recovery-state"
        state_dir.mkdir(mode=0o700, exist_ok=True)
        state = state_dir.lstat()
        if not stat.S_ISDIR(state.st_mode) or state.st_uid != os.getuid() or state.st_mode & 0o077:
            raise ValueError("unsafe_state_directory")
        acl_free(state_dir)
        lock = state_dir / "lock"
        fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        held = os.fstat(fd)
        named = lock.lstat()
        acl_free(lock)
        if (not stat.S_ISREG(held.st_mode) or held.st_uid != os.getuid() or held.st_mode & 0o077
                or (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino)):
            raise ValueError("unsafe_lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            print(json.dumps({"state": "watcher_busy", "recovered": False}))
            return 75
        os.set_inheritable(fd, True)
        os.environ["HAIL_CODEX_RECOVERY_LOCK_FD"] = str(fd)
    script = Path(__file__).with_name("host.cjs" if args.mode == "host" else "index.cjs")
    os.execv(str(node), [str(node), str(script), args.mode, "--config", str(args.config)])
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print("codex_recovery_unavailable", file=sys.stderr)
        sys.exit(1)
