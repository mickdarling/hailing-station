# #327 PR 2b-i: connection-scoped clip attribution

Part of #327. Based on `origin/main` at `09b4c466` (PR 2a #1122). This is attribution groundwork;
the production gate still pins one configured target. It adds no follow-selection flag, binding resolver,
deployment, installed build, or physical two-session proof.

The PR 2 plan is [comment 6710189582](https://github.com/mickdarling/hailing-station/issues/327#issuecomment-6710189582).
The PR 2a independent second-key carry-forwards are
[comment 6712525350](https://github.com/mickdarling/hailing-station/pull/1122#issuecomment-6712525350).
The primary-review fallback carry-forward is recorded in [the PR 2a test record](327-pr2a-router-binding.md).
These are prior-slice reviews, not reviews of this change.

## Attribution decision

- Device privacy clips and connection-scoped meeting changes resolve the connection's current session selection
  through `WebSocketListener.ambientClipTarget(connection:)`, inside their async clip tasks. There is no session
  hop or await under `state.withLock`, no configured-target fallback, and no `HostSession.swift` change.
- A missing connection/selection suppresses the clip while the mode change still applies. An on-change retains
  its resolved target before the persona guard, only if its meeting token is still current. Even a future silent
  on-change can therefore retain its timeout target. Production restores use `resumed_unrecorded`, with a persona.
- A meeting timeout uses only its retained target: no target, no clip. A connection-scoped off command resolves
  current selection rather than borrowing the meeting's earlier child target.
- Child callbacks keep the target captured when their pipeline was built, including privacy, meeting, media,
  acknowledgement, route-refusal and not-sent paths. Media's connection restore sends a mode notice, not a clip.
  Privacy entry work still closes its ledger and handles refused children with a nil target; device notices still run.
  Pre-arm changes privacy state without inventing a target; later device clip work resolves selection as above.
- Delivery still uses `acknowledgementFrames` and the existing host/transport guards. A selection change after
  resolution fails closed. This slice does not change the existing selection-generation or binding gates.
- Refused starts never write `streamTargets`. Only registration of a child writes that diagnostic snapshot;
  a prior admitted snapshot can remain, but no device/system clip consults it. `latest`, `newestStart`, queue
  order, dead-start pruning, teardown and shutdown protections remain. The closed-mark comment now includes
  `latest` and identifies the gate's bounded ended-connection ring as the actual backstop.

Production files by the exact exclusions and rename handling in `scripts/pr-shape.py`: **4**:
`WebSocketListener.swift`, `WebSocketListener+Acknowledgement.swift`, `WebSocketListener+DuckMode.swift`,
and `WebSocketListener+MeetingMode.swift`, all under `Sources/HailDaemonKit/Listener/` (security-critical).
There are no renames. No enforcement script changes or bootstrap exemption.

## Synthetic tests and changed assertions

Existing test changes are restricted to `AmbientRouterTargetLifetimeTests.swift`,
`AmbientRouterBindingRefusalTests.swift` and `AmbientRouterBoundConfirmationTests.swift`.
`AmbientRouterConnectionAttributionTests.swift` is new. All other existing files under `Tests/` remain
byte-identical to `origin/main`, including all privacy, duck, meeting, media, wiring and restore-guard tests,
and all support files (including `PreboundAmbientRouterTestSupport.swift`).

Changed existing assertions, including equivalent lookups moved to the new attribution seam:

| Case | Old expectation | New expectation | Reason |
| --- | --- | --- | --- |
| Persona-less on-change (renamed from a restore) | Meeting target equals the admitted stream's `RecipientTestRig.target` immediately under the lock and after clearing `streamTargets` | After draining the async on-change task, target equals the session-selected `recipient:other`, despite the different admitted stream and cleared snapshot | Resolve before the persona guard, outside the router lock; explicitly a future guard, not a production restore |
| Late-start test, before a stream | `streamTarget` equals `configuration.target` | Listener lookup equals selected `RecipientTestRig.target` | The connection's selection is authoritative; values coincide in the configured case |
| Late-start test, after an admitted non-configured stream | `streamTarget` equals stream target `recipient:other` | Listener lookup still equals selected `RecipientTestRig.target` | An admitted stream does not change session selection |
| Refused start after closed-mark pruning | `streamTargets[connection] == "recipient:other"` | Snapshot is nil and `latest[connection]` names the late start; listener lookup is nil after disconnect | Refusal retains ordering bookkeeping without claiming child admission or inventing a destination |
| Target-less meeting timeout, initial lookup | `streamTarget` equals `RecipientTestRig.target` | Listener lookup equals selected `RecipientTestRig.target` | Shows selection exists but cannot replace a missing retained timeout target |
| Target-less meeting timeout | Require a queued clip chain, drain it, then a clean pong because fallback delivery is rejected | Meeting mode is off, no clip chain is created, clean pong | Explicit no-target/no-clip branch; state change still applies |
| Pre-arm/device off, both lookups | `streamTarget == configuration.target` before/after off | Listener lookup equals selected `RecipientTestRig.target` before/after off | Verify connection attribution without a stream; privacy state and no-frame expectations stay intact |
| Bound confirmation, route-refusal/not-sent error | Error code is `voiceRouteRefused` | Same code, plus error frame target is nil | Control error is intentionally untargeted; subsequent confirmation supplies attribution |
| Bound confirmation, text/audio | Frame target equals `RecipientTestRig.target` | Same frame target, plus reply descriptor target equals `RecipientTestRig.target` | Assert attribution on both the frame and reply; no original assertion is weakened |

Added held-worker coverage queues an unbound start followed by a configured start, segment and final end.
It asserts zero stray `ambient_refused`, exactly one child, `ambient_started` then `ambient_ended`, all audio
bytes consumed, and an empty queue. It uses the existing synthetic held-worker seam, not a real forced-retirement race.

New connection tests cover refusal bookkeeping and current selection, missing selection with state changes,
selection changed while a meeting clip waits in its chain, selection changed after lookup but before delivery,
privacy entry ledger closure with no selection after a child has started, and device privacy off after selecting a target different from the child's captured target.
Existing child-callback tests continue to cover target retention across snapshot replacement/clearing.

## Verification

The Dev Work VM verification clone was clean at the requested `09b4c466` baseline, with
GitHub as origin, before bundle synchronization. Verification snapshots use temporary refs, not implementation
commits on `feat/327-attribution`. Source and tests must match the final verified snapshot before committing.

Each VM invocation waits for the shared lane to become idle, then runs, over blocking SSH with stdin
`< /dev/null`:

Each run waited for the shared VM lane to be idle.

The VM verification wrapper built the package and tests, then ran the filtered tests: `'HailDaemonKitTests\.(Ambient|TaskProgress|GuardBudget)'`.

The runner builds all Swift package tests with `swift build --build-tests -j 4` and its Command Line Tools
Testing framework/plugin/linker flags, then uses `swift test --skip-build --no-parallel -j 4` with the filter
above and workspace-specific build path. This is synthetic macOS package evidence, not simulator/device proof.

- Final VM snapshot: `2b585319e44fc47b4e27fd4eb31912652182897a`. **Build passed** (`build=0`, 24.98 s);
  **677 tests in 148 suites passed** (`test=0`, 538.327 s). The unchanged
  `AmbientPrivacyAnnounceTests.anEntryAfterTheStartDeadlineIsAnnouncedWithinTheBound` and all router tests,
  including the new nil-target ledger case, passed.
- `git diff 2b585319e44fc47b4e27fd4eb31912652182897a -- Sources Tests` is empty before committing:
  the final source/test tree is exactly what the VM validated. Only documentation results were updated afterward.
- Strict host lint: **all 8 changed Swift files passed, zero violations**, each with:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>`.
- Test boundary: `git diff --stat origin/main -- Tests` lists only the three existing router files and the new
  connection-attribution file. A blob-hash comparison of **908 other existing Tests paths** (including symlink
  contents) confirms they are byte-identical to `origin/main`.
- Production count: loaded `EXCLUDED_PREFIXES`/`EXCLUDED_SUFFIXES` from `scripts/pr-shape.py` and applied them to
  `git diff --name-only origin/main`; 4 production paths, no renames. `HostSession.swift` diff is empty.
- Whitespace: `git diff --check` / `git diff --cached --check` pass.
- Iterations: the first VM build exposed a lock-state name collision in the meeting closure; moved to the async
  helper. An intermediate runtime iteration exposed the unchanged privacy deadline test's missing completion log
  when nil target short-circuited the whole device task (**676 tests / 148 suites, 3 issues in that one test**).
  The correction suppresses only speech and preserves
  ledger closure, refusal handling, device notices and logs. The existing regression test is unchanged.

## Deferred to PR 2b-ii and delivery

Follow-selection flag and gate admission, target policy generations, bounded binding lookup, unknown/offline/
denied/rebound target refusals, cross-target take-over, and the physical two-session proof remain deferred.
A real concurrent forced-retirement race remains outside the synthetic held-worker test. Independent exact-head
reviews and GitHub protections are pending a later PR; prior-slice approvals do not cover this work.
No host build/test, simulator/app build, physical capture/playback, live captured-output round trip, haild action,
private configuration or target-list change, installed-build replacement, upload, push or PR creation is performed.
