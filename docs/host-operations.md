# Host operations

How to install, run and check the Mac host daemon (#246). The LaunchAgent and the `haild` on `PATH` always run the same installed release, so a rebuild cannot leave the daemon and `haild reply` on different builds (#115).

## Configure

Create `~/.config/hail/host.json`:

```json
{
  "bind": "127.0.0.1",
  "port": 8765,
  "singleTerminalReplyFallback": true,
  "deviceDiagnostics": false,
  "ambient": {
    "rightyo": "/absolute/path/to/rightyo",
    "config": "/absolute/path/to/rightyo-config.json",
    "target": "tmux:session-name"
  }
}
```

- `bind` (an IP address literal) and `port` are required. Everything else is optional; leave out `ambient` to run without ambient listening.
- Values must have the right JSON type: strings for `bind`, `hostID` and the ambient keys, an integer `port`, and `true` or `false` for flags. Ambient listening requires `"singleTerminalReplyFallback": true`.
- Values may not contain control characters or start with `-`. Bad config is refused before the running daemon is touched.
- `hostID` is optional. Without it, the daemon and `haild reply` both use the Mac's LocalHostName as `<name>.local`. If you set it, the target sessions that run `haild reply` must use the same value through `HAIL_HOST_ID`.
- Ambient paths must be absolute and exist, and `target` must be letters, digits and `._:-`. The daemon applies its own ownership, permission and guarded-word checks when ambient listening starts.

## Install and restart

```sh
scripts/host.sh deploy    # install, then restart: the usual one-command path
scripts/host.sh install   # build a release haild and stage it; nothing running changes
scripts/host.sh restart   # start the staged release under launchd and wait until it is ready
scripts/host.sh status    # staged release, running daemon, PATH haild, and problems
```

- `install` builds `haild` in release mode and stages it read-only at `~/Library/Application Support/HailingStation/releases/<sha256-prefix>/haild`, with `current` pointing at it. `--binary PATH` installs a prebuilt binary instead.
- `restart`:
  1. Checks the config and writes the new LaunchAgent before touching anything.
  2. Stops the legacy ad-hoc job (`com.mickdarling.hailing-station-session`) and the managed job, and waits until they have unloaded.
  3. Starts `com.hailingstation.haild`, retrying the bootstrap.
  4. Waits until the listener reports ready, the reply socket exists, and the process stays up.
  5. Only then points `running` and `~/.local/bin/haild` at the new release.
- If the new daemon does not become ready, `restart` restores the previous LaunchAgent, checks that it is ready, says whether it is, and exits non-zero.
- The first migration from the legacy job has no previous LaunchAgent to restore. The failed agent is kept as `com.hailingstation.haild.plist.failed`, so it does not load at the next login, and no daemon is running. Read the log, fix the cause, and run `restart` again.
- If an existing job does not unload in time, `restart` stops before starting anything new.
- `install`, `restart` and `deploy` take a per-user lock, so only one runs at a time; they need `python3` (the lock and the `bind` check use it).
- Make sure `~/.local/bin` is on `PATH` for the target sessions, so the `haild reply` named in reply instructions resolves to the running release.

## Logs

`~/Library/Logs/HailingStation/haild.err.log` holds the daemon's structured events. `restart` keeps the previous run's log as `haild.err.log.1`. `haild.out.log` holds standard output.

## When replies stop arriving

1. Run `scripts/host.sh status`. Exit code 3 means one of these:
   - the managed daemon is not running;
   - it runs a different release from the `PATH` haild;
   - the legacy job is still loaded.
   Run `scripts/host.sh restart`.
2. Read the refusal reason printed by `haild reply` (#85). For example, `sourceHostMismatch` means the host IDs differ (see `hostID` above), and `noRecipient` means no terminal is connected for that target.
3. Check the end of `haild.err.log` for `session_connected` and `session_disconnected` events.

## Rollback

Releases are never deleted by `install`. `ls -t "$HOME/Library/Application Support/HailingStation/releases"` lists them, newest first. To roll back, run `scripts/host.sh deploy --binary` with the absolute path to the earlier release's `haild`. Releases are read-only: to delete an old one, run `chmod -R u+w` on it first.
