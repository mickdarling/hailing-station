# Host operations

How to install, run and check the Mac host daemon (#246). One installed release serves both the LaunchAgent and the `haild` on `PATH`, so a rebuild cannot leave the daemon and `haild reply` on different builds (#115).

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

- `bind` and `port` are required. Everything else is optional; leave out `ambient` to run without ambient listening.
- `hostID` is optional. Without it, the daemon and `haild reply` both use the Mac's LocalHostName as `<name>.local`. If you set it, the target sessions that run `haild reply` must use the same value through `HAIL_HOST_ID`.
- Ambient paths must be absolute. The daemon applies its own ownership and permission checks when ambient listening starts.

## Install and restart

```sh
scripts/host.sh install   # build a release haild and install it as an immutable release
scripts/host.sh restart   # write the LaunchAgent, replace any running haild job, wait for readiness
scripts/host.sh status    # installed release, PATH link, LaunchAgent program, drift
```

- `install` builds `haild` in release mode, copies it to `~/Library/Application Support/HailingStation/releases/<sha256-prefix>/haild` (read-only), and switches `current` and `~/.local/bin/haild` to it atomically. `--binary PATH` installs a prebuilt binary instead.
- `restart` writes `~/Library/LaunchAgents/com.hailingstation.haild.plist`. It removes the managed job and the legacy ad-hoc job (`com.mickdarling.hailing-station-session`), then starts the agent with `KeepAlive`. It fails unless the listener reports ready within 20 seconds.
- Make sure `~/.local/bin` is on `PATH` for the target sessions, so the `haild reply` named in reply instructions resolves to the installed release.

## Logs

`~/Library/Logs/HailingStation/haild.err.log` holds the daemon's structured events. `restart` keeps the previous run's log as `haild.err.log.1`. `haild.out.log` holds standard output.

## When replies stop arriving

1. `scripts/host.sh status`. Exit code 3 means drift: the daemon runs an older release than the one installed. Run `scripts/host.sh restart`.
2. A warning about the legacy job means a second daemon may still be running. Run `scripts/host.sh restart`.
3. Read the refusal reason printed by `haild reply` (#85). For example, `sourceHostMismatch` means the host IDs differ (see `hostID` above), and `noRecipient` means no terminal is connected for that target.
4. Check the end of `haild.err.log` for `session_connected` and `session_disconnected` events.

## Rollback

Releases are never deleted by `install`. To roll back, run `scripts/host.sh install --binary` with the earlier release's `haild`, then `scripts/host.sh restart`.
