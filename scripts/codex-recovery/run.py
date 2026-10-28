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
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("status", "recover", "watch"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--node", default=shutil.which("node"))
    args = parser.parse_args()
    node = Path(args.node or "")
    if not node.is_absolute() or not node.is_file() or not args.config.is_absolute():
        raise ValueError("invalid_runtime_path")
    source = args.config.lstat()
    parent = args.config.parent.lstat()
    if (not stat.S_ISREG(source.st_mode) or source.st_uid != os.getuid() or source.st_mode & 0o077
            or not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077):
        raise ValueError("unsafe_config")
    if args.mode != "status":
        fd = os.open(str(args.config) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        held = os.fstat(fd)
        if not stat.S_ISREG(held.st_mode) or held.st_uid != os.getuid() or held.st_mode & 0o077:
            raise ValueError("unsafe_lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            print(json.dumps({"state": "watcher_busy", "recovered": False}))
            return 75
        os.set_inheritable(fd, True)
        os.environ["HAIL_CODEX_RECOVERY_LOCK_FD"] = str(fd)
    script = Path(__file__).with_name("index.cjs")
    os.execv(str(node), [str(node), str(script), args.mode, "--config", str(args.config)])
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError):
        print("codex_recovery_unavailable", file=sys.stderr)
        sys.exit(1)
