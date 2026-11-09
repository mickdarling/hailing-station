# Delivery stage order

Part of #1120.

The host evaluates held predicates inside the target-policy gate before its continuation. Their order
is policy revision, selection, allowed mode, then notice lifetime. They precede the request clock.
A refusal from an inner session stage re-evaluates those predicates only after all nested gates have
released, so its reason retains that precedence. A retired held generation still resolves to `policyChanged`.

`DeliveryAdmission.Stage` retains the order target policy, task output fence, reply permit, binding
lease, session-update fence, ambient router, privacy hold, peer lifecycle, attempt/cancellation, then
operation. Absent stages are skipped. Each target-policy generation is acquired once; task delivery
uses the output fence directly rather than nesting the composite publication authority.

## Path audit

An arrow denotes nested locks held through the continuation. A semicolon separates checks whose
locks have already released. Actor turns and asynchronous preflight are not locks in this table.

| Path | Lock order and evidence |
| --- | --- |
| Host delivery without retained authority | `HailHost.dispatch`, `requireCurrentLine`, and `deliverLine` perform preflight and policy observations before adapter handoff. There is no peer lock around these observations. A missing policy generation with retained, held or task-handoff authority refuses before adapter delivery. |
| Session input, phone or local | `HostSession.finalDeliveryAuthority` starts empty and contributes reply permit → binding lease → peer lifecycle → request clock. `RetainedDeliveryStages.composed` supplies target policy outside those stages. The final factory does not inherit or overwrite outer slots. |
| Held session input | Target policy → held predicates (policy-revision mutex; selection-store mutex; lockdown mutex; router snapshot; notice clock, each released before the next) → reply permit → binding lease → peer lifecycle → request clock. `requireHeld` runs before the target-policy continuation. A refused nested stage unwinds before held predicates are consulted again. There is no router or policy re-entry while peer lifecycle is held. |
| Task wake input | Target policy → task output fence → session-update fence → ambient router → privacy hold → retained audience's peer lifecycle → attempt/lifetime decision. `taskProgressDeliveryStages` retains the original audience, privacy revision and peer permit. `ListenerTaskProgress.sendWake` binds those stages before `sendAuthorized`. |
| Compatibility task handoff | `taskProgressHandoff` composes the same task stages and calls `admit {}`. It does not nest `TaskProgressPublicationAuthority.perform` under another policy gate. |
| Existing adapter handoff checks | `TaskProgressWakeScope.checkedHandoff` calls composed `admit {}`; it commits attempts while taking short locks and doing no policy I/O. Gates release before asynchronous adapter completion. The per-side-effect guarded-delivery contract remains in effect. |
| Owned post-handoff commit | Reply permit → binding lease → peer lifecycle → request clock and last-input ledger. Only `request.committed`, `replyRequests[id]`, and ledger attribution commit under those gates. `HostReplyRequest.withAuthority` supplies the permit and lease order. |
| Ownerless post-handoff commit | Peer lifecycle → last-input ledger. Selection is checked before entering peer lifecycle. A retired peer records no attribution. Local completion keeps `connectionLost`; phone completion keeps `.unowned("reply authority changed")`. |
| Post-commit observers | Every commit gate releases before segmented-reply stopping, stopped-reply recording, reply events, logging and callback task creation. `didNoteLastInput` runs synchronously in the same session actor turn. Commit paths use `recordLastInput`; the former combined helper has been removed. |
| Held request preflight and resolution | `HeldRequests.attemptHeld` performs selection, listing, policy and mode checks separately before dispatch; no peer lock encloses them. Failure recording and policy-reason classification happen after delivery gates unwind. The store serializes decisions with actor tasks and does not hold a mutex across dispatch. |
| Task enrollment | `TaskProgressEnrollmentAdmission.perform`: owner-state lock → controller lifetime. No router, policy or peer gate is entered by the scheduler's enrollment commit. Initial `ownerState.enroll` orders owner state → controller lifetime → previous output fence closure; direct retirement orders owner state → output fence. |
| Task owner control | `TaskProgressRetainedOwnerAdmission.perform`: owner-state lock → controller lifetime → ambient owner permission (router) for an ambient source; a local source skips router. The control commit does not enter a peer gate. After router and lifetime release, pause/stop may close the output fence while owner state remains held. |
| Task reports and session-update cards/audio | `TaskProgressPublicationAuthority.perform`: target policy → optional task output fence → reply permit → binding lease → session-update fence → ambient router → privacy hold → prepared transport enqueue (peer lifecycle). `enqueueSessionUpdate`, `deliverSessionUpdate`, and `enqueueSessionUpdateAudio` share this order; renderer admission omits the final transport gate. Preparation and completion waits happen outside these gates. |

Peer lifecycle contains its retirement-state mutex → its original transport publication permit.
Prepared transport enqueue briefly enters its own submission state after that permit and never
re-enters router, privacy or target policy.

The host's policy observation and transaction paths order observation → target-policy state; admission
uses only target-policy state. Held policy-revision and lockdown snapshots do not reacquire that state.
`ListenerTaskProgress.wake`, `report`, and `submit` perform actor and clock preflight separately and
retain publication authority for the final synchronous composition. No audited path acquires peer
lifecycle and then router, privacy or policy.

`DeliveryAuthority.admit` documents that an error does not prove zero execution. Callers rely on the
attempt/cancellation record and never retry on error. This delivery does not change command launch.

## Synthetic evidence

- `DeliveryAdmissionStageOrderTests` instruments the real retained gates. Held predicates assert that the peer
  gate is free on success, peer refusal and request-clock refusal. The task test wraps the actual router
  continuation and retained peer gate. Session stages are exercised with an earlier router contributor; ordinary session input
  has no router stage unless held predicates apply. These tests require no production recorder hook.
- `FinalDeliveryCommitTests.lastInputObserversRunAfterCommitGatesRelease` synchronously reacquires the
  original reply permit, binding lease and peer permit from stopped-reply and event observers. It also
  checks that ledger attribution is already present. Ownerless observers probe the peer gate.
- Completion-barrier cases cover ownerless local and both phone ownership forms after peer retirement,
  with no last-input entry. Missing-policy cases cover retained, held and task-handoff authority.
- Existing tests and expectations remain unchanged.

## Verification

The Dev Work VM workspace is a fresh clone at `~/codex-workspaces/vwf3a`, checked out at
`1f2a4dc1b6c8f14699a9df971957d88f5c90995e` and synchronized by a local `origin/main..HEAD` bundle.
Each run waits for the shared lane from a remote script whose process arguments contain only its
filename, avoiding a match against the waiting shell itself:

```sh
while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done
WS=vwf3a ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(DeliveryAdmission|DeliveryAuthority|FinalDelivery|TaskProgress|Held|LocalDispatch|HailHost|Host|Ambient|Tmux|Reply)'
python3 -m unittest discover -s Tests/ReplyCLITests
~/codex-workspaces/vw-werr.sh vwf3a
```

SSH stdin is closed with `< /dev/null`; each command finishes before the next begins. The package
runner uses four workers. The warnings-as-errors helper runs with a workspace-specific `swift` wrapper
on `PATH` that executes `/usr/bin/swift "$@" -j 4`, keeping that build at four workers too. The wrapper
and runner scripts are outside the repository.

The initial source/test snapshot `f3156e0c693bbfde082f9588d36aa93f5ae673f2` passed **1,098 tests in 227 suites** in **544.729 seconds**,
with `build=0`, `test=0` and the ten existing known issues.

The final source/test snapshot `4970484837b0f02e00f407d0f1a6e2770ebe3aaa` passed **1,099 tests in
227 suites** in **637.580 seconds**, with **`build=0`, `test=0`**. Its ten known issues are the five
each in the existing `LocalDispatchPreflightWaitTests` and `ReplyRecipientHandoffWaitTests`; there
were no unexpected issues. The final ordering and commit suites passed, including the request-clock
refusal assertion. Reply CLI verification passed **124 tests in 216.158 seconds**, exit 0.
The warnings-as-errors helper finished with **`werr build=0`, exit 0**. Existing missing
module-cache debug-info warnings were emitted by the Command Line Tools iteration build.

Final VM logs are `~/codex-workspaces/vwf3a-build.log`, `~/codex-workspaces/vwf3a-test.log`,
`~/codex-workspaces/vwf3a-cli.log`, `~/codex-workspaces/vwf3a-werr.log` and
`~/codex-workspaces/vwf3a-werr-result.log`. The final follow-up changes this document only;
executable source and tests match the verified snapshot.

Strict host lint passed with zero violations on the four production files and three new test files:
`DeliveryAdmissionStageOrderTests.swift`, `DeliveryStageOrderTestSupport.swift` and
`FinalDeliveryCommitTests.swift`.
Each file is checked separately with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

Production files are `Progress/TaskProgressAuthority.swift`, `Listener/HostSession+Routing.swift`,
`Daemon/HailHost.swift` and `Adapter/Adapter.swift`, all under `Sources/HailDaemonKit`. Loading
`scripts/pr-shape.py` locally and applying its exact exclusions and rename handling counts **four**
production files. Its GitHub-dependent PR checks are not invoked. No existing test file is modified.
`git diff --check` and its staged equivalent passed. All verification commands completed; no VM job
is left running by this session.

This record covers synthetic VM package checks and host lint. It establishes no simulator,
physical-device or live captured-output behavior. No host build or test, daemon or configuration
change, install, upload or push is part of this verification.
