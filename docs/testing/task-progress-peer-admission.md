# Task-progress peer admission

Part of #1120.

Task-progress admission is bound to the exact selected ambient audience and that audience's peer transport.
This record describes source inspection and synthetic verification; it does not establish physical-device proof.

## Audit

The audience capture and operation-bearing peer stage already existed at the starting revision.
References below name the resulting source locations.

| Invariant | Evidence | Disposition |
| --- | --- | --- |
| The permit belongs to the selected audience's connection. | `TaskProgressAuthority.swift:147`: match the update audience, ambient audience and peer's `session.connectionID` before issuing a permit. | Kept. |
| Audience and permit are captured together without an actor hop. | `TaskProgressAuthority.swift:129` delegates to the synchronous contributor at line 143; `WebSocketPeer.swift:35` makes `replyTransport` nonisolated. | Kept. |
| Admission retains the original audience and permit. | `TaskProgressAuthority.swift:158` captures the audience; line 164 captures its permit in `.peerLifecycle`. No lookup or permit replacement follows an await. | Kept. |
| Production dispatch carries the retained stages through the host. | `ListenerTaskProgress.swift:278` captures the contributor once, then lines 284–286 pass its task-local stages through `host.sendAuthorized`; `HailHost.swift:38` composes those stages. | Kept. |
| Peer retirement precedes asynchronous cleanup. | `WebSocketListener.swift:391`: removal is followed by transport retirement at line 394, before `endAmbient` at line 398. This early retirement is defence in depth: production reaches this callback only after `finish()` has already retired the transport. | TIGHTENED: explicit lifecycle invariant, with no reachable production behaviour change. |
| A successor cannot revive captured transport authority. | `WebSocketPeer.swift:280` refuses permits after retirement; line 287 permanently retires and invalidates; `ReplyTransportPermit` at line 321 retains its original lifecycle. | Kept. |
| Attempt accounting separates refusal from possible execution. | `TaskProgressAuthority.swift:165` commits attempts at the final stage; `ListenerTaskProgress.swift:261` releases a canceled wake only if no attempt occurred. | Kept. |

The earlier `taskProgressConnection` check at `ListenerTaskProgress.swift:244` remains advisory.
Transport callbacks, peer close/finish and listener stop retain their existing retirement paths.

## Design and lock order

The early retire in `peerEnded` is defence in depth. Production reaches `peerEnded` only from the peer's end
callback after the peer's `finish()`, which already retires its transport. There is no reachable production
behaviour change. The listener cleanup entry is internal for lifecycle tests, and a task-local cleanup barrier
is absent during normal operation. The retained contribution and attempt-accounting implementation are unchanged.

Task-progress operation admission nests these stages in the order defined by `DeliveryAdmission.swift:14`:

1. Target policy generation.
2. Task output fence.
3. Session-update fence, including quiet/stop closure.
4. Ambient router permission for the retained audience.
5. Privacy hold at the retained revision.
6. Peer transport lifecycle and its retained publication permit.
7. Attempt/deadline decision and synchronous submission admission.

The peer gate never surrounds router acquisition. Every gate is synchronous: no `await`, peer liveness actor read,
peer teardown or ambient teardown runs under a gate. Preparation and asynchronous adapter completion occur outside
the admission gates. Already admitted submission work may complete after peer retirement.

## Verification cases

`TaskProgressPeerAdmissionTests` uses real scheduler wakes, the production tmux adapter and process command runner,
and a synthetic executable. Acknowledged pre-launch, cleanup and child-write barriers establish ordering.
Directory notifications acknowledge child writes; watchdogs bound missing acknowledgements. No sleep establishes
ordering. The fixture involves neither a tmux server nor a physical device.

| Case | Required evidence |
| --- | --- |
| Selected audience versus a different peer | Retirement of a different peer preserves admission; retirement of the selected peer refuses without recording an attempt. |
| Peer removal before admission | Cleanup is blocked, transport is retired, then pre-launch preparation is released: no solicitation child launches and no attempt stays outstanding. |
| Listener stop before admission | Transport retirement precedes blocked cleanup; releasing pre-launch work starts no solicitation. Stop finishes the controller enrollment, leaving no task or outstanding wake. |
| Audience replacement before admission | `capturedHandoffRefusesSameAudienceSuccessor` captures a handoff, removes and retires its selected peer, and registers a live successor with the same connection and unchanged audience identity. A fresh handoff succeeds; the captured handoff throws `CancellationError` without recording an attempt. |
| Peer retirement after admission | The original paste and Enter complete; outstanding state remains conservative after replacement, environment refresh and a large clock advance. No duplicate deadline or submission appears. |

The fresh handoff proves that the registered successor and the other admission gates permit execution.
A lazy lookup by audience at admission would find that successor and succeed; retaining the original peer's
permit instead refuses. The original attempt remains separate from the successful fresh attempt.

## Existing-test preservation

| Existing suite | Classification | Change |
| --- | --- | --- |
| `TaskProgressHandoffTests` | KEPT | Unchanged. |
| `TaskProgressDispatchCancellationTests` | KEPT | Unchanged. |
| `TaskProgressAdmissionExpiryTests` | KEPT | Unchanged. |
| `TaskProgressPeerAdmissionTests` selected-peer coverage | TIGHTENED | Same-audience successor coverage distinguishes retained permits from admission-time lookup. |
| `TaskProgressPeerAdmissionTests` retirement coverage | TIGHTENED | Listener stop asserts a finished enrollment; other retirement cases retain refusal accounting assertions. |
| All other pre-existing tests and fixtures | KEPT | Unchanged. |

The peer-admission suite and its support remain separate files. Earlier suites and fixtures are unchanged.

## Execution record

Verification lane: Dev Work VM, Swift 6.3.3. Swift build/test concurrency is limited to four workers.
The checkout starts at `d13765e79ffc52dcbff55af091b7c2552c28a7d5`; local bundles supply the branch changes.

Initial F5 verification:

| Gate | Result |
| --- | --- |
| Targeted `HailDaemonKitTests.TaskProgress` filter | PASS: 62 tests in 21 suites. |
| Focused peer admission, handoff, dispatch cancellation and admission expiry filters, repeated three times | PASS: 10 tests in 4 suites on each run. |
| Broader delivery, listener and adapter filter | PASS: 1,106 tests in 227 suites; five expected known issues from the unchanged reply-handoff wait tests. |
| `python3 -m unittest discover -s Tests/ReplyCLITests` | PASS: 124 tests. |
| Package and tests with warnings as errors | PASS: build and command exit 0. The toolchain emits module-cache lookup warnings during linking. |
| Host strict SwiftLint for all four changed Swift files | PASS: zero violations. |
| Host non-comment Swift line-length check at 120 columns | PASS: no output. |

Lifecycle assertion follow-up verification:

| Gate | Result |
| --- | --- |
| `HailDaemonKitTests.TaskProgress` filter, repeated three times | PASS: 63 tests in 21 suites on each run; build and test exit 0. |
| TaskProgress, WebSocket, Listener, Tmux and CommandLaunch filter | PASS: 261 tests in 56 suites; build and test exit 0. |
| Package and tests with warnings as errors | PASS: build and command exit 0. The toolchain emits module-cache lookup warnings during linking. |
| Host strict SwiftLint for all four branch-changed Swift files | PASS: no output, exit 0, using the Xcode developer directory. |
| Host non-comment Swift line-length check at 120 columns | PASS: no output, exit 0 for all four files. |

The follow-up verifies the final Swift sources; only this execution record changes after those runs.

The production-file count uses the PR-shape checker's exclusions and rename handling: two production files,
`Sources/HailDaemonKit/Progress/TaskProgressAuthority.swift` and
`Sources/HailDaemonKit/Listener/WebSocketListener.swift`, below the four-file limit. The remaining additions
are the peer-admission suite, its support file and this record. The suite is tightened as recorded above;
all earlier suites and fixtures remain unchanged.

No host build/test, simulator run, installed-build change or physical-device validation is part of this record.
