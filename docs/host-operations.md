# Host operations

How to install, run and check the Mac host daemon (#246). The LaunchAgent and the `haild` on `PATH` always run the same installed release, so a rebuild cannot leave the daemon and `haild reply` on different builds (#115).

## Configure

Create the config directory privately (`mkdir -m 700 ~/.config/hail`; the daemon refuses one that other accounts can read), then `~/.config/hail/host.json`:

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

- `bind` (an IP address literal) and `port` are required. If you use Tailscale Serve, `port` must differ from the Serve port; see [Remote access through Tailscale Serve](#remote-access-through-tailscale-serve). Everything else is optional; leave out `ambient` to run without ambient listening.
- Values must have the right JSON type: strings for `bind`, `hostID` and the ambient keys, an integer `port`, and `true` or `false` for flags. Ambient listening requires `"singleTerminalReplyFallback": true`.
- Values may not contain control characters or start with `-`. Bad config is refused before the running daemon is touched.
- `hostID` is optional. Without it, the daemon and `haild reply` both use the Mac's LocalHostName as `<name>.local`. If you set it, the target sessions that run `haild reply` must use the same value through `HAIL_HOST_ID`.
- Ambient paths must be absolute and exist, and `target` must be letters, digits and `._:-`. The daemon applies its own ownership, permission and guarded-word checks when ambient listening starts.

## Remote access through Tailscale Serve

Give `haild` its own loopback port, not the port Tailscale Serve exposes on the tailnet. Devices keep using the tailnet port, and Serve forwards it:

```sh
# host.json: "bind": "127.0.0.1", "port": 18765
tailscale serve --bg --tcp 8765 tcp://localhost:18765
```

- **Why:** Network.framework will not listen on a port that any address on the Mac already holds (#262). Serve listens on the tailnet addresses, so if it uses the daemon's port, `haild` fails at every start with `Address already in use`. That includes restarts and crash recovery, and probably logins where Tailscale starts first.
- **Check:** `tailscale serve status --json` should forward the tailnet port to the `port` in `host.json`.

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
- An interrupt (Ctrl-C, a closed terminal) during the legacy job's unload is ignored, because that job is not restored; the switch then continues. At any later point before the new daemon is ready, an interrupt rolls back.
- `install`, `restart` and `deploy` take a per-user lock, so only one runs at a time; they need `python3` (the lock and the `bind` check use it).
- Make sure `~/.local/bin` is on `PATH` for the target sessions, so the `haild reply` named in reply instructions resolves to the running release.

## Logs

`~/Library/Logs/HailingStation/haild.err.log` holds the daemon's structured events. `restart` keeps the previous run's log as `haild.err.log.1`. `haild.out.log` holds standard output.

## Health checks

`haild doctor` compares the running daemon with the `haild` you run it from and prints one line per check, marked `ok`, `WARN` or `FAIL`, with a plain-language fix under each failure or warning. It exits 1 if any check fails; a warning is advisory and alone exits 0. `haild status --json` prints the same report as JSON, with each check's `outcome` (`ok`, `warn` or `fail`) and a `healthy` field that only a failure makes false, and always exits 0. The checks (#247) are:

- `daemon_running`: the daemon's status snapshot exists and its process is alive.
- `build_match`: the daemon and this `haild` are the same build (the release digest), so replies are not refused for build skew (#115).
- `host_id_match`: both resolve the same host ID, so replies are not refused as `sourceHostMismatch`.
- `listener_ready`: the listener is up, and on which address. A port held elsewhere points to the Tailscale Serve section above.
- `ambient_listening`: the last ambient run did not fail; it shows `not enabled` when ambient listening is not configured. A RightyO child that died (`child transportLost`, for example), a refused start or a shutdown timeout fails, with the cause in the fix. A run that ended cleanly, or a request held for confirmation by the target's tier, is healthy and idle. The check reflects the most recent ambient event, so a failure stays visible until the next run.
- `target_input`: a warning (`WARN`), never a failure, listed only while the most recent ambient event is a request that the stream's own target refused because its prompt already held unsent text (`ambient_delivery_refused reason=inputPending`, #894). haild itself is healthy and listening goes on, so `ambient_listening` passes, `healthy` stays true and doctor still exits 0. The fix points at `haild targets flush <target-id>` (see [Clear a stale prompt draft](#clear-a-stale-prompt-draft-894)), and at `scripts/host.sh restart` when `haild.err.log` shows `tmux_input_pending reason=tainted`, since a flush cannot clear a taint. The snapshot holds neither the target nor the adapter's reason, so doctor names neither. The next ambient event replaces it, so it can outlast a flush that already cleared the prompt. It stays on the Mac: a device's health summary leaves it off.
- `device_connected`: at least one phone or tablet is connected.
- `recent_refusals`: no reply was refused in the last 15 minutes. Each refused `haild reply` is audited as `delivery_refused` with its code (`noRecipient`, `notUniqueRecipient`, `sourceHostMismatch`, …), never its text. A retryable `requestPending` answer is not a refusal and is not recorded. Doctor counts the records (refused reply frames) by reason over 15 minutes and an hour, and gives the fix for the most frequent one. `status --json` includes the counts.

The daemon keeps the snapshot in `~/.config/hail/status.json` (owner-only). It holds no transcript, peer address or device identifier. With the default loopback `bind`, the output is safe to paste; with any other `bind`, the listener line shows that address.

## Reload RightyO without touching the phone

After a RightyO reinstall, run `haild ambient reload`. It restarts the RightyO child for the stream that is listening now, using the current install and config. The phone keeps streaming and is not told; a second or so of audio around the restart may be lost. It only re-arms listening that is already on: with no active stream it prints `idle` and starts nothing. `busy` (the daemon is busy with this stream: starting, reloading or stopping a child) and `stopping` exit 75; try again shortly. `refused: <reason>` means the new child could not launch, and the running child keeps the stream.

`haild ambient status` shows whether a stream is active, the device class, target, when the stream and its current child started, the RightyO install time (flagged when it is newer than the running child), and the live child count. Neither command prints transcript text. Both use the owner-only reply socket (`--socket <path>` to choose another) and are audited as `local-ambient`. The running daemon must include #409; an older one answers `refused: ... (the daemon may predate ...)`.

## Session updates (opt-in, #609)

A session can tell you about finished work, a needed decision or a failure without a pending request:

```sh
haild notify tmux:work --say "The deck is built" --card "PR #123"
haild notify tmux:work --say "The build failed and needs you" --action
haild notify status
haild notify quiet on
```

It is off unless `haild run` gets `--personal-terminal --session-updates`. The target must be a live target from `haild targets`. That target is also the name the update is shown under and the key for its rate limit. Any local process can name any live target, so these limits are cooperative, not a security boundary.
- **For now every update is held. Nothing is spoken yet:** speaking waits for haild to deliver to the device it chose itself, and held updates are not yet delivered to a device. That comes with the update card and drain work.
- An `--action` update that a device could be told about prints `push: suggested`, so the session can raise its own notification. Quiet suppresses it.
- `haild notify quiet on` turns on do-not-disturb until haild restarts. A session cannot turn it off; that is the user's own control.

Each session may send 6 updates an hour and have 5 held. At most 20 are held in all, for up to 4 hours. These defaults are placeholders pending Mick's decision.

Exit codes: 0 when held or for status; 75 when rate limited; 1 for other refusals (`unknown_target`, `full`, `not enabled`). Output gives counts and reasons only, never the words. Requests are audited as `local-update` with the action only.

## When replies stop arriving

1. Run `haild doctor`, then `scripts/host.sh status`. Exit code 3 means one of these:
   - the managed daemon is not running;
   - it runs a different release from the `PATH` haild;
   - the legacy job is still loaded.
   Run `scripts/host.sh restart`.
2. Read the refusal reason printed by `haild reply` (#85). For example, `sourceHostMismatch` means the host IDs differ (see `hostID` above), and `noRecipient` means no terminal is connected for that target.
3. Check the end of `haild.err.log` for `session_connected` and `session_disconnected` events.
4. `listener_failed` with `Address already in use` means another listener holds the daemon's port on some address, often Tailscale Serve. See [Remote access through Tailscale Serve](#remote-access-through-tailscale-serve).

## Clear a stale prompt draft (#894)

haild never types after unsent text: when a target's prompt already holds text, every delivery to it is refused (`haild.err.log` shows `tmux_input_pending reason=…`, and after an ambient request `haild doctor` warns `target_input`). `haild targets flush <target-id>` clears that text:

```sh
haild targets flush tmux:work          # shows the draft, then asks you to type flush
haild targets flush tmux:work --yes > draft.txt   # scripts; the draft is kept in draft.txt
```

- **The draft is printed first, alone, on standard output**, so a real draft can be recovered. Everything else goes to standard error. Without `--yes` it asks you to type `flush`. When standard input is not a terminal, it refuses with exit code 8 and sends nothing.
- **What it reads:** the cursor row of the target's pane, after the agent's prompt marker (`>` or `❯`, at column 0 or inside a `│ ` box, as Claude Code draws it). Codex's prompt is not physically tested yet.
- **What it sends:** `End`, then exactly one `BSpace` for each character before the cursor. That count includes trailing blanks, which a capture does not show. It **never sends `Escape` or `C-c`**, which would interrupt a running agent turn. Each key command goes through the same tmux server-side agent check as the Enter after a pasted delivery (#608), and the binding is checked again before each one.
- **It refuses and sends nothing** when the pane is not running Claude Code or Codex, when the cursor row has no prompt marker, when the draft spans more than one line (or wraps), and when it holds a collapsed paste (`[Pasted text #N]`). Clear those by hand. It also refuses if the draft changed after it was shown; by then only the `End` has been sent, which deletes nothing.
- **Policy:** it is gated like Escape from the device. The target must be allowed, still bound and not `locked`, and lockdown refuses it. The `confirm` tier allows it.
- **Afterwards** it looks again. A busy agent redraws its input late, so it keeps looking every 100 ms, for up to 2 s, until the prompt reads empty. It sends nothing more while it waits. It then reports `the prompt is now empty`, or that text is still shown, which exits 6. The reason token says what the last look showed: `text_left`, `text_after_cursor` (likely the agent's greyed hint), `blank_before_cursor`, `no_prompt` or `unreadable`.
- **The live input is the cursor row.** A transcript row above it that echoes an earlier prompt behind its own `❯` is never read or cleared.
- **Logs:** it writes one line to standard error, `targets_flush cleared_chars=<n> result=empty|not_empty|refused reason=<token>`. It never logs the draft, and nothing goes to `haild.err.log`, OSLog or the audit log.
- **A flush cannot clear a taint.** A pane that holds a paste haild knows it never submitted is tainted in the running daemon's memory, and each `haild` command has its own. If deliveries are still refused afterwards with `reason=tainted`, run `scripts/host.sh restart`. The command says so after each flush.

Exit codes: 0 cleared or already empty, 4 refused (nothing cleared), 6 text still shown, 8 confirmation needed or cancelled. Policy denials use the `send` codes (5 unbound, 7 denied), and an unknown target gives 2.

## Keep speech real-time when the Mac is busy (#737)

Spoken replies are rendered on this Mac as they play, so heavy work here can make them choppy. That happened on 2026-10-21, with swap 93% full and a VM using 3+ cores. Load was about 10 when the choppy replies were heard, and about 40 later that day.

The voice path's own processes already ask for interactive scheduling: `haild` (with its RightyO child) and `vbstreamd` use `ProcessType Interactive`, which `launchctl print` shows as `spawn type = interactive (4)`. `launchd.plist(5)` prefers `ProcessType` to `Nice`. So the lever is running everything else in the background.

**Check:** compare the scheduling priority (`pri`, higher wins) of the voice processes with the heavy ones. It prints nothing useful if none of them is running.

```sh
ps -o pid,pri,nice,%cpu,rss,command -p "$(pgrep -d, -f 'haild run|vbstreamd|Virtualization.VirtualMachine|backupd$')"
```

`pri` moves from moment to moment, so read it as a snapshot. On 10-21, `vbstreamd` and `haild` sat in the 30s, while a VM's `com.apple.Virtualization.VirtualMachine` service held **55**, even after `renice +10`. `renice` doesn't lower that service.

**Run heavy work in the background.** `taskpolicy -b` sets `PRIO_DARWIN_BG`: CPU priority drops to about 4, disk and new network I/O are throttled, and the children inherit it.
- **A running VM:** `taskpolicy -b -p <pid of its VirtualMachine service>`, then run the check to confirm its `pri` dropped. With several VMs, pick the busy service by `%cpu`; not every one runs at 55. `taskpolicy -B -p <pid>` undoes it.
  - It's **untested on that service so far**.
  - Expect the guest to slow sharply, close to stalling when the host is loaded.
  - It's lost when the VM restarts. The service is spawned by launchd, not by the tool that starts the VM, so starting that tool under `taskpolicy` probably doesn't reach it. Re-apply `-p` after each VM start.
- **Builds and test lanes:** the compilers and `swift test` are children of your shell, so the policy reaches them: `taskpolicy -b scripts/verify.sh all`, `taskpolicy -b swift build`, `taskpolicy -b xcodebuild …`. Simulators and the test runners `xcodebuild` launches are started by launchd, so they escape it, like the VM service. For work that should still make progress, a softer limit is `taskpolicy -c utility <command>` (a QoS clamp, at launch only).
- **Time Machine:** `backupd` is usually at pri 4, but a running backup can be higher. On 10-21 a backup in its Copying phase showed pri 46, above both voice processes. Check it, and if it's above them during a voice session, `tmutil stopbackup`. `debug.lowpri_throttle_enabled` (1 by default, and 1 on 10-21) throttles low-priority disk I/O. Never set it to 0 on this Mac.

**Memory matters as much as CPU.** With swap nearly full, the TTS model and audio buffers page out, whatever their priority. Check `sysctl vm.swapusage`, and give VMs less memory or stop one before a long voice session. Keeping the voice path resident is #737's next step.

**What the measurements show** (#737 step 1; the first two arrive with #743 and #741):
- **Reply timing**, from a `haild` that includes #743: `log show --last 1h --predicate 'subsystem == "com.mickdarling.hailing-station" && category == "reply-timing"'` gives one line per spoken reply. A `haild` run from a SwiftPM `.build/` directory, such as the CLI tests in `verify.sh scripts`, logs under `reply-timing-dev` instead, so test runs never read as live replies.
  - A `min_lead_ms` below about −100 means the Mac fell behind real time, and the device very likely ran dry, unless it was still playing an earlier reply or was paused.
  - `ack_max_ms` and `ack_p95_ms` are the endpoint's per-frame acknowledgement times, and `resends` counts the retry waits inside them.
- **Playback gaps**, from a station build that includes #741: with `deviceDiagnostics` on in `host.json` and diagnostics on in the station app, each `reply_playback_end` in `~/.config/hail/diagnostics/diagnostics.jsonl` (see [device diagnostics](device-diagnostics.md)) carries `count` and `ms`, the gaps heard during that playback.
- **TTS speed:** `~/Library/Logs/vbstreamd/vbstreamd.log` gives TTS's per-line realtime factor. `steady` below 1x means generation fell behind playback. This needs voicebox-friday-kit #33 live, which takes a vbstreamd restart.

## Rollback

Releases are never deleted by `install`. `ls -t "$HOME/Library/Application Support/HailingStation/releases"` lists them, newest first. To roll back, run `scripts/host.sh deploy --binary` with the absolute path to the earlier release's `haild`. Releases are read-only: to delete an old one, run `chmod -R u+w` on it first.
