# Codex voice recovery and continuation (#1002)

Part of [#1002](https://github.com/mickdarling/hailing-station/issues/1002) and
[#986](https://github.com/mickdarling/hailing-station/issues/986). RightyO's paired
request-outcome work is [rightyo#262](https://github.com/mickdarling/rightyo/issues/262),
related to its existing [#158](https://github.com/mickdarling/rightyo/issues/158).

## Delivery boundary

This first slice packages a bounded controller and decision loop. It does not
register a provider, change `haild run`, install a watcher, add a LaunchAgent,
replace an app, or enable the experimental owned stdio adapter from #153.
Host-owned request binding, default supervision, device-visible recovery notices,
and RightyO lifecycle controls remain the next slices. This is not a deployed fix.

The 2026-10-28 personal setup already used the existing tmux adapter, capture,
RightyO, reply CLI and local Jarvis voice. The owner heard a correctly routed reply
on Mac, iPhone and iPad. The Mac turn took14.382s, an iPhone-origin turn158.461s
(three input messages accumulated), and the iPad turn9.285s. A later text-only
operator turn took5m7s and completed on its own. It was not recovered by this code.
These are Codex turn durations after dispatch, not microphone-to-hearing latency.
The cause of the long waits remains unknown. Installed clients in those checks
were Mac0.1.191/build19, iPhone0.1.116 (owner reported), and iPad0.1.115.

## Code owns the recovery

`scripts/codex-recovery/index.cjs` implements:

- A bounded WebSocket client over the exact local Unix socket. The socket uses an
  HTTP Upgrade handshake; sending JSONL to it is not the supported transport.
- Discovery of the configured exact tmux binding and `codex` foreground command,
  its same-user child app-server and one owner-only socket. Rebinding, ambiguous
  servers/sockets, unsafe file permissions and unavailable control refuse action.
- An original first-response deadline. User steering does not renew it. A visible
  assistant response, reasoning progress, tool activity or waiting-for-owner flag
  protects substantive work for the rest of that exact turn, even if later history
  regresses. Unknown reasoning shapes, negative/missing timing, unknown runtime
  shape and clock discontinuity do not grant cancellation authority.
- A second runtime/ownership check immediately before exact-ID `turn/interrupt`.
  Success requires observing the same turn's explicit `interrupted` terminal while
  the binding remains unchanged. Natural completion stays natural completion.
- An owner-only interruption-attempt checkpoint written before the interrupt.
  A lost acknowledgement is not blindly retried after restarting the watcher.
  The checkpoint is control state (opaque IDs only), not a transcript or diagnostic.
  A different thread/binding cannot overwrite that checkpoint: foreign state is
  refused, never treated as an empty attempt set. Host composition must provision
  a separate private configuration directory for each managed session generation.
- Content-free status and bounded control failure/backoff. It never answers a
  server approval, authentication, tool or attestation request.

`run.py` holds a nonblocking kernel lock through `exec` of the controller. Only one
recovering process owns a configuration at a time. Process death releases the lock;
there is no PID-file deletion procedure and no leaked parent lock-holder process.
Lock, status, checkpoint and temporary files live in a separate fixed
`.codex-recovery-state/` directory. A configured status filename cannot replace the
lock or configuration. macOS extended ACLs on protected objects are refused even
when their POSIX mode is0600/0700; configuration/checkpoint reads are byte-bounded
and checked against the opened inode. The runtime control profile is macOS-only.
Protected reads open nonblocking before requiring a regular file, so a FIFO cannot
hang the controller while it holds the kernel lock.

No code replays a user request, switches provider, falls back to Claude, kills a
Codex daemon, changes policy, or touches microphone/audio configuration.

## Operator interface for development and verification

Node20+ and Python3 are prerequisites; `Brewfile` includes Node. The only Node
dependency is lockfile-pinned `ws`; install scripts are disabled:

```sh
npm ci --prefix scripts/codex-recovery --ignore-scripts --no-audit --no-fund
npm test --prefix scripts/codex-recovery
python3 -m unittest scripts/tests/test_codex_recovery_lock.py
```

These tests are included in the normal `scripts/verify.sh scripts` and `all` lanes.
Their Unix-WebSocket servers, IDs, payloads and process fixtures are authored;
they use no model, account, microphone, speech, real conversation or TCP listener.

An explicitly provisioned private configuration has mode0600 in a real owner-only
directory (0700). Example values below are invented, not discovery instructions:

```json
{
  "version": 1,
  "target": "tmux:voice-codex",
  "threadId": "11111111-1111-4111-8111-111111111111",
  "binding": "$1@2/%3:4",
  "firstResponseSeconds": 90,
  "statusFile": "/private/operator-config/.codex-recovery-state/status.json"
}
```

`statusFile` must be exactly `.codex-recovery-state/status.json` below the config's
parent directory; arbitrary output aliases are refused. The wrapper provisions
and validates that owner-only state directory before taking its kernel lock.
IDs and bindings must come from trusted host composition, never from model text. This
first slice accepts an explicit operator config; it does not invent a live binding.

```sh
python3 scripts/codex-recovery/run.py status --config /private/operator-config/recovery.json
python3 scripts/codex-recovery/run.py recover --config /private/operator-config/recovery.json
python3 scripts/codex-recovery/run.py watch --config /private/operator-config/recovery.json
```

`recover` applies the same first-response predicate as `watch`; it is not a force
kill. `status` is read-only. `watch` writes status and attempts recovery only when
qualified. A second recovering process exits75 with `watcher_busy`. Other refusals
are fixed codes, not raw provider messages. No transcript is written. Stopping the
watcher stops only its controller, not Codex or capture; stopping it does not undo
an already accepted interruption. The explicit `watch` command is a developer
interface until packaged host supervision and request-lifetime wiring are reviewed.
It is not an end-user Terminal recovery requirement or automatic installation.

Control transactions have a five-second bound. Confirmation has a separate bounded
five-second grace, rechecked before each read. Discovery subprocesses are bounded
to two seconds each. The watcher polls locally at three seconds, backs off control
failures to at most30s, and performs no GitHub polling. The supported protocol
subset was inspected against CLI0.165.0-alpha.1.2; this is not permission to change
the separate owned adapter's version allowlist or inherited configuration rules.

## Next-agent handoff: package integration, not prompt workarounds

Continue from the issue-linked PR's current head; read its actual verification and
review records rather than transferring an earlier approval. The implementation
worktree starts from main `e11bb4d36453720770701cc837af51ba5b26428d`. Never reset a
shared checkout or copy private setup files into Git.

1. **Hailing Station host composition:** own the controller with the same voice
   request/session generation, revoke it on selection/Stop/Quit/privacy/connection
   retirement, and distinguish waiting, productive work, refused control,
   unconfirmed interruption and ready. Supervise it through the normal package
   lifecycle, with explicit enable/disable/rollback. Do not monitor arbitrary
   desktop chats or assume a manually configured UUID is permanent authority.
2. **Routing and user feedback:** preserve the originating connection and exact
   host request reference for any notice. No current-listener inference,
   request-less fallback with multiple devices, automatic stale-request replay,
   or promotion of an accepted interrupt to successful playback. Admission and
   busy/queue rules belong in typed host code, not a model's standing instructions.
3. **RightyO:** review a versioned capability-negotiated request lifecycle under
   rightyo#262. Bind accepted/failed/timed-out/cancelled outcomes to the exact child
   session and original request. Clear only that request's pending-ack/await-answer
   state, preserve privacy/meeting/role/retention rules, and admit a genuinely new
   request afterward. Playback started/ended is a different event. RightyO never
   discovers Codex sockets or decides provider interruption authority.
4. **Paired proof and delivery:** add shared authored contract fixtures, host
   generation/routing/lifetime tests and RightyO control-FD/replay tests. Use normal
   bounded PRs, complete checks and fresh exact-head independent reviews in both
   repositories. Keep unimplemented acceptance explicit. Only after integration
   review and authorized delivery should an installed watcher or client change be
   claimed. Keep real provider checks separate from fixture and physical hearing
   results; no audio, voiceprint, private prompt or credential enters the repo.

## References

- [Official Codex App Server protocol](https://learn.chatgpt.com/docs/app-server#protocol)
- [Official exact-turn interruption](https://learn.chatgpt.com/docs/app-server#interrupt-a-turn)
- [ws client and IPC documentation](https://github.com/websockets/ws/blob/master/doc/ws.md)
- [Existing owned adapter boundary](codex-app-server-adapter.md)
- [Host operations](host-operations.md)

## Host-owned worker protocol (next integration slice)

`run.py host --config <private-profile>` owns the same inherited kernel lock and
uses the existing controller; it is a private supervised child, not an end-user
Terminal recovery command. It accepts bounded newline JSON controls on stdin:
`version: 1`, `op`, `request` (fresh host UUID), `generation` (host lifetime UUID).
The only operations are `prepare`, `commit`, `authorize`, and `retire`.

Prepare requires an idle exact configured Codex backend and records its baseline.
Commit follows a successful existing-pipeline dispatch. The worker binds only a
new turn whose first user message ends in the exact host-generated request reply
block. A quoted ID or later user message cannot supply authority. Authorize must
follow the exact RightyO child's sequenced `accepted` acknowledgement, within five
seconds of commit. An unconfirmed commit/request observation expires after 30s.
The worker applies the original first-response deadline and activity protections,
then rechecks request, turn and ownership in the final interrupt snapshot.

EOF, retirement, malformed control or owner change revokes the worker. It never
starts/replays a model turn, kills Codex, changes provider or opens audio. Its
stdout is a private bounded control channel containing fixed states plus opaque
request/generation IDs; persisted status contains only states and recovery proof.
The existing checkpoint is written before an interrupt, including when its ack is
lost. Recovery still requires the exact interrupted terminal state.

This slice provides the worker and authored Unix-WebSocket/control regressions.
Native host spawning, request/generation ownership, RightyO acknowledgement
plumbing, originating-device notices and installed runtime provisioning still
require their paired integration. No worker is installed or automatically enabled
by adding this module. `npm test --prefix scripts/codex-recovery` runs both controller
and host-worker suites. Python process-lock tests continue to cover kernel locking
through exec, competing controllers and release on death.

The paired v1 outcome vocabulary also accepts `reply_published`: confirmed final
publication of that exact request's audio stream (or final text for text-only output).
It clears matching pending-answer state without pretending the device played or
heard it. A provider turn ending or merely enqueuing a frame cannot supply this
proof. Existing confirmed transport-completion callbacks are the integration point;
question metadata may be carried explicitly. Scoped physical playback remains a
separate event, and unknown, retired or competing request identities still refuse.
