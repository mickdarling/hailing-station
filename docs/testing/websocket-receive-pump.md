# WebSocket receive pump

Part of #1120.

## Implemented invariants

Each peer has one receive pump and one application worker. Network callbacks classify close, error,
missing metadata, unsupported opcodes and missing application content before application dispatch.
Terminal events retire the peer's `ReplyTransportLifecycle`, clear queued messages and cancel the
connection before scheduling actor cleanup. The callback never awaits session processing, adapter
completion, response transmission or router teardown.

Application callbacks enqueue bytes and immediately arm the next receive. A single worker removes
messages in wire order and awaits all of `session.receive` and ordered response processing before
removing the next message. The peer actor can service closure while that worker is suspended; actor
reentrancy is not used as a serialization guarantee. Transport ping/pong only rearms receiving.

There are at most eight queued application messages and at most
`2 * PayloadLimits.defaultMaxFrameBytes` queued bytes (182,954 bytes). These bounds exclude the active
message and one receive bounded by the listener's existing `maximumMessageSize` (91,477 bytes).
A single application message also must fit that frame limit. Exceeding either queue bound retires
and terminates the peer immediately. Receiving never pauses to wait for capacity.

Protocol closure, hello timeout, listener shutdown, connection failure and send cancellation retire
the same lifecycle and stop the pump. The lifecycle's retirement observer clears the pump even when
listener-wide retirement precedes asynchronous peer cleanup. One receive already submitted to Network
may complete after local stop; it cannot enqueue application work or rearm receiving.

A submission already admitted at paste launch retains its bounded completion. Pending submissions
refuse after retirement. No application task is cancelled to recall an admitted submission. The pump
retains a worker-task snapshot so a caller can join outside the peer actor; closure and shutdown do
not join it. Tasks are created only when an idle worker becomes active, not for queued messages or
transport ping/pong.

## Lock order

The new pump state mutex protects only start/stop flags, receive reservation, worker ownership,
queued data and byte accounting. No synchronous callback, lifecycle operation, session operation,
Network call or asynchronous wait runs while it is held. Worker task creation only records the task;
the task must acquire the state mutex separately before removing any data.

Pump stop first retires the lifecycle, releases its gates, and then acquires pump state to clear the
queue. Lifecycle retirement invokes its observer only after releasing the retirement mutex and the
transport publication authority. Registration is under the lifecycle mutex; an immediate observer
callback also runs after releasing it. Pump state never nests a lifecycle, reply-permit, binding,
router, privacy or policy lock. No new path acquires router, privacy or policy while holding lifecycle,
reply permit or binding lease. Existing delivery-stage order remains unchanged.

The worker holds no pump lock while entering the peer actor, `HostSession`, adapter or response send.
Neither pump callbacks nor peer closure turns wait for the worker. The worker's task snapshot is read
under pump state and awaited only after releasing it, by the tests.

## Synthetic evidence

`WebSocketReceivePumpTests.closeObservationRemainsActiveDuringDelivery` uses a loopback WebSocket,
production `TmuxAdapter`, and a guarded scripted runner. Its first message parks in `beforeResponse`
before paste `launch.perform`. After the acknowledged park, the client sends a second application
message followed by transport close. The test awaits the peer's disconnect event and asserts lifecycle
retirement and peer termination while the first delivery remains parked. Only then does it release
and join the recorded worker. No paste or Enter executes, and only the first paste command was prepared.
The companion argument parks before Enter after paste admission: that submission completes exactly
once after close, and the queued second message never starts delivery. Disconnect may be reported as
the classified close or Network cancellation; retirement precedes either cleanup notification.

Other cases cover ordered text/select/text through real sessions, a transport pong during suspended
application processing, a single active worker, exactly one outstanding receive, count and byte
boundaries, queue clearing on direct lifecycle retirement, malformed metadata, receive failure,
protocol closure, hello timeout and listener shutdown. Synthetic count/byte tests fill exactly to the
bound before overflowing and prove that receiving remains armed at the bound. Loopback count/byte
overflow cases prove peer termination before releasing delivery.

Ordering uses acknowledged entry, release, disconnect and completion barriers. Deadlines are
watchdogs, except the hello timeout and the existing elapsed-age assertion, which explicitly measure
time. No sleep or scheduler-yield loop establishes message ordering. Scripted runners execute no tmux
process. These tests do not establish device capture, playback or a live captured-output round trip.

## Existing test assertion accounting

Only the three test-only carries below modify existing test files. Existing receive/listener and final
delivery test bodies are unchanged. No existing assertion is weakened or removed.

| Existing test / assertion | Status | Accounting |
| --- | --- | --- |
| `TaskProgressTmuxAdmissionTests.wakeAttemptCommitsOnlyAtPasteAdmission`: tainted refusal type | KEPT | Existing assertion unchanged. |
| Same: no committed attempt on tainted refusal | KEPT | Existing assertion unchanged. |
| Same: no later capture, buffer, paste or key commands on tainted refusal | KEPT | Existing assertion unchanged. |
| Same: established taint's delivered text and Enter | KEPT | Existing assertion unchanged. |
| Same: no attempt at set-buffer preparation | KEPT | Existing assertion unchanged; additional paste-launch case below. |
| Same: no delivered keys before preparation release | KEPT | Existing assertion unchanged. |
| Same: delivered outcome after release | KEPT | Existing assertion unchanged. |
| Same: committed attempt after release | KEPT | Existing assertion unchanged. |
| Same: exact text/Enter after release | KEPT | Existing assertion unchanged. |
| New `wakeAttemptRemainsUncommittedBeforePasteLaunch`: attempt boundary | TIGHTENED | Parks on recorded paste-buffer in `beforeResponse`; asserts no attempt and no delivery before `launch.perform`, then delivered outcome, committed attempt and text/Enter after release. |
| `TmuxRefusalEvidenceTests.aConfirmedInsertThatCameBackIsNamedStaleAndOwnWithItsLengthAndAge`: refusal type | KEPT | Existing assertion unchanged. |
| Same: delivered text and Enter remain unchanged by refusal | KEPT | Existing assertion unchanged. |
| Same: one confirmed submit evidence line | KEPT | Existing assertion unchanged. |
| Same: exactly one refusal evidence line | KEPT | Existing requirement unchanged. |
| Same: parsed whole-second age | KEPT | Existing requirement unchanged. |
| Same: age is within 1...30 seconds | KEPT | Same monotonic deadline; suspending clock wait replaces yield-based polling. |
| Same: exact refusal evidence with the observed age | KEPT | Existing assertion unchanged. |
| Same: token-only evidence excludes synthetic payloads | KEPT | Existing assertion unchanged. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal`: delivered first outcome | KEPT | Existing assertion unchanged. |
| Same: next terminal message has exact notAllowed response | KEPT | Existing assertion unchanged. |
| Same: only first text pasted | KEPT | Existing assertion unchanged. |
| Same: no subsequent capture, set-buffer, paste-buffer or send-keys | TIGHTENED | Each argv element is searched for each command substring, including if-shell command strings. |
| Same: exactly one Enter | KEPT | Existing assertion unchanged. |
| Same: empty input | KEPT | Existing assertion unchanged. |

All other tests in those files remain unchanged. The elapsed-age clock wait is intentionally a time
measurement, not a replacement for an ordering barrier. For paste and Enter, the responder executes
inside `launch.perform` on the guarded runner overload; the paste-launch park precedes that call.

## Verification

The VM workspace `~/codex-workspaces/vwf4` was freshly cloned and checked out at
`36259c1728edd5d2f8defadf28054e032a545668`. Host commits were synchronized with bundles made by
`git bundle create /tmp/vwf4.bundle origin/main..HEAD`; VM checkout used `git fetch /tmp/vwf4.bundle HEAD`
and `git checkout -B receive-verification FETCH_HEAD`. No source or test build ran on the host.

Each remote script was invoked through SSH with stdin redirected from `/dev/null`, and the SSH call
was joined before continuing. Every run first waited for the shared lane with the exact check below.
The check lived in a script file, so the waiting shell's arguments did not contain its search pattern.
A separate 600-second process-group watchdog reaped each phase on timeout or interruption.

```sh
while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done
```

The initial targeted run passed 26 tests in four suites. An expanded snapshot at
`d56b456db7c117d4a9a9e2ce06f700ecc4d9b45b` passed 28 tests in four suites three times. The final test
snapshot is `fd5a61df23ad475659f171769003643b9fb241d0`. Relative to the expanded snapshot, it adds an
exact protocol-error response assertion and permits either close/cancellation cleanup ordering in a
new test. Production files are identical across those two snapshots.

The targeted command, used initially and for each three-run repeat set, was:

```sh
WS=vwf4 python3 /tmp/vwf4-phase.py /bin/zsh ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(WebSocketReceivePump|TaskProgressTmuxAdmission|TmuxRefusalEvidence|TmuxAuthorityBoundary)'
```

The requested broad regression filter was split into these bounded groups, with the idle check
before each command. All existing test bodies were unchanged except the two explicit carry edits.

```sh
WS=vwf4 python3 /tmp/vwf4-phase.py /bin/zsh ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(WebSocket|Listener|HostSession|FinalDelivery|DeliveryAdmission|TaskProgress|Held|LocalDispatch|HailHost|Host|Tmux|Reply|CommandLaunch)'
WS=vwf4 python3 /tmp/vwf4-phase.py /bin/zsh ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.Ambient[A-M]'
WS=vwf4 python3 /tmp/vwf4-phase.py /bin/zsh ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.Ambient([^A-M]|$)'
```

| Regression group | Result |
| --- | --- |
| Core | 502 tests, 105 suites passed; 10 expected known issues in unchanged wait-harness self-tests. |
| Ambient A–M | 111 tests, 21 suites passed. |
| Remaining ambient | 507 tests, 107 suites passed. |

The ten known issues come from `LocalDispatchPreflightWaitTests` and `ReplyRecipientHandoffWaitTests`,
which deliberately exercise deadline and cancellation reporting. They are not unexpected failures.

The remaining verification commands, also preceded by the idle check, were:

```sh
cd ~/codex-workspaces/vwf4
python3 /tmp/vwf4-phase.py python3 -m unittest discover -s Tests/ReplyCLITests
PATH="$HOME/codex-workspaces/vwf4-tools:$PATH" python3 /tmp/vwf4-phase.py /bin/zsh ~/codex-workspaces/vw-werr.sh vwf4
```

The workspace-specific PATH wrapper delegates to `/usr/bin/swift`, adding `-j 4` only to `swift build`.
The shared helpers were not edited; before/after SHA-256 checks compare both `vw327-run.sh` and
`vw-werr.sh`. The ordinary test helper already supplies `-j 4` for build and test. No VM jobs are
intentionally detached.

The CLI suite passed all **124 tests** (215.092 seconds). Final changed-suite repeats at
`fd5a61df23ad475659f171769003643b9fb241d0` passed **28 tests in four suites** each, in 2.982, 2.826 and
2.590 seconds. Both warnings-as-errors invocations reported `werr build=0` and wrapper exit **0**,
including the final test snapshot. Command Line Tools emitted module-cache debug-information warnings;
there were no Swift warnings-as-errors failures. Shared-helper checksums matched after both runs.
The toolchain was Apple Swift 6.3.3 on the macOS Dev Work VM.

The existing real-tmux suites remain skipped when tmux is unavailable: `TmuxDeliveryCommitFakeTUITests`,
`TmuxDeliveryCommitShellPromptTests`, `TmuxIntegrationTests`, `TmuxPasteAgentTests` and
`TmuxPasteEnterTests`. No tmux binary was installed. All new pump, real-session and loopback tests ran.

VM logs are `/tmp/vwf4-{repeat-1,repeat-2,repeat-3,core,ambient-am,ambient-rest}-{build,test}.log`,
`/tmp/vwf4-final-repeat-{1,2,3}-{build,test}.log`, `/tmp/vwf4-cli.log`,
`/tmp/vwf4-{werr,final-werr}-result.log`, and `~/codex-workspaces/vwf4-werr.log`. Inspection after the
final run found no running phase, Swift build, Swift test or package-test process from this work.
The VM tracked worktree was clean. The final commit adds documentation only after the final test
snapshot; source and test identity are checked again during final bundle synchronization.

Host strict lint and explicit line-length verification were run separately on all eight changed
Swift files, with zero violations and no awk output:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
awk 'length($0)>120 && $0 !~ /^[[:space:]]*\/\//' <file>
```

`git diff --check` also passes. Local source counting imports `scripts/pr-shape.py` with
`runpy.run_path`, reads `git diff --name-status --find-renames 36259c17 HEAD`, includes both rename
names and applies its exact prefix/suffix exclusions. It counts **two production files**, below the
four-file limit. The GitHub-dependent checker entry point is not invoked.

| Changed file | Role |
| --- | --- |
| `Sources/HailDaemonKit/Listener/WebSocketPeer.swift` | Peer integration and lifecycle retirement observation. |
| `Sources/HailDaemonKit/Listener/WebSocketIngressPump.swift` | Bounded receive pump and serialized worker. |
| `Tests/HailDaemonKitTests/WebSocketReceivePumpTests.swift` | Synthetic pump boundaries and transport classification. |
| `Tests/HailDaemonKitTests/WebSocketReceivePumpLoopbackTests.swift` | Loopback delivery, overflow, selection and closure. |
| `Tests/HailDaemonKitTests/WebSocketReceivePumpSessionTests.swift` | Real-session receive concurrency measurement. |
| `Tests/HailDaemonKitTests/TaskProgressTmuxAdmissionTests.swift` | Additional paste-launch attempt boundary. |
| `Tests/HailDaemonKitTests/TmuxRefusalEvidenceTests.swift` | Suspended elapsed-age clock wait. |
| `Tests/HailDaemonKitTests/TmuxAuthorityBoundaryTests.swift` | All-argv command refusal assertion. |
| `docs/testing/websocket-receive-pump.md` | Invariants, lock order, assertions and verification. |

No installation, upload, daemon restart, launch-agent change, host configuration change or host tmux
operation is part of this work. The evidence is synthetic VM and loopback evidence; there is no
simulator, physical-device or live captured-output round-trip claim.
