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
| Peer retirement precedes asynchronous cleanup. | `WebSocketListener.swift:390`: removal is followed by transport retirement at line 393, before `endAmbient` at line 397. The starting implementation proceeded from removal to cleanup without this defensive retirement. | Tightened. |
| A successor cannot revive captured transport authority. | `WebSocketPeer.swift:280` refuses permits after retirement; line 287 permanently retires and invalidates; `ReplyTransportPermit` at line 321 retains its original lifecycle. | Kept. |
| Attempt accounting separates refusal from possible execution. | `TaskProgressAuthority.swift:165` commits attempts at the final stage; `ListenerTaskProgress.swift:261` releases a canceled wake only if no attempt occurred. | Kept. |

The earlier `taskProgressConnection` check at `ListenerTaskProgress.swift:244` remains advisory.
Transport callbacks, peer close/finish and listener stop retain their existing retirement paths.

## Design and lock order

The production behavior change retires the removed peer's transport before ambient cleanup or environment refresh.
The listener cleanup entry is module-visible for lifecycle tests, and a task-local cleanup barrier is absent during
normal operation. The retained contribution and attempt-accounting implementation are unchanged.

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
| Listener stop before admission | Transport retirement precedes blocked cleanup; releasing pre-launch work starts no solicitation. |
| Audience replacement before admission | A live successor cannot authorize the captured handoff, including replacement that preserves the audience identity. |
| Peer retirement after admission | The original paste and Enter complete; outstanding state remains conservative after replacement, environment refresh and a large clock advance. No duplicate deadline or submission appears. |

## Existing-test preservation

| Existing suite | Classification | Change |
| --- | --- | --- |
| `TaskProgressHandoffTests` | KEPT | Unchanged. |
| `TaskProgressDispatchCancellationTests` | KEPT | Unchanged. |
| `TaskProgressAdmissionExpiryTests` | KEPT | Unchanged. |
| All other pre-existing tests and fixtures | KEPT | Unchanged. |

No existing test was tightened or weakened. New tests and their support are separate files.

## Execution record

Verification lane: Dev Work VM, Swift 6.3.3. Swift build/test concurrency is limited to four workers.
The checkout starts at `d13765e79ffc52dcbff55af091b7c2552c28a7d5`; local bundles supply the branch changes.

| Gate | Result |
| --- | --- |
| Targeted `HailDaemonKitTests.TaskProgress` filter | PASS: 62 tests in 21 suites. |
| Focused peer admission, handoff, dispatch cancellation and admission expiry filters, repeated three times | PASS: 10 tests in 4 suites on each run. |
| Broader delivery, listener and adapter filter | PASS: 1,106 tests in 227 suites; five expected known issues from the unchanged reply-handoff wait tests. |
| `python3 -m unittest discover -s Tests/ReplyCLITests` | PASS: 124 tests. |
| Package and tests with warnings as errors | PASS: build and command exit 0. The toolchain emits module-cache lookup warnings during linking. |
| Host strict SwiftLint for all four changed Swift files | PASS: zero violations. |
| Host non-comment Swift line-length check at 120 columns | PASS: no output. |

The production-file count uses the PR-shape checker's exclusions and rename handling: two production files,
`Sources/HailDaemonKit/Progress/TaskProgressAuthority.swift` and
`Sources/HailDaemonKit/Listener/WebSocketListener.swift`, below the four-file limit. The remaining additions
are the new test suite, its support file and this record. No existing test or fixture is edited.

No host build/test, simulator run, installed-build change or physical-device validation is part of this record.
