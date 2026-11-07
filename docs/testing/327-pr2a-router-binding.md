# #327 PR 2a: pre-admission router binding

PR 2a lives on `feat/327-follow-selection-router`, based on PR 1 #1113's merge `5793b82f61c5cb71b63e56bd2af69eeda9c3d71f`. It is router groundwork and changes no production behaviour:

- The production gate still pins its configured target, admits only that target, and emits a nil binding.
- No follow-selection flag, binding resolver, deployment or two-session device behaviour is enabled.

The plan is issue #327 comment 6710189582. The PR 1 second-key record is comment 6709937206. That approval covers PR 1, not PR 2a.

## What changed

- **Pre-admission binding:** `AmbientStreamScope` carries an optional `binding`, resolved before admission and never by the router.
  - A configured start always uses `configuration.binding`.
  - Any other target starts only with a non-empty scope binding. Without one, it is refused with `target_binding_unavailable`.
- **Refusals share the start path:** the inline refusal path is gone. Every start, refused or not, goes through the same bookkeeping (`latest`, `newestStart`, `reapplyOnLife`, the queue, dead-start pruning). A binding refusal never makes room or evicts a child.
- **Configured fallback kept, explicitly:** `streamTarget(on:in:)` keeps a documented configured-target fallback for connection-scoped device and system clips with no admitted stream target.
  - Delivery (`acknowledgementFrames` and related checks) still requires the session to select that target, so a mismatch fails closed.
  - That prevents mismatched delivery but does not establish correct attribution. PR 2b must resolve connection-scoped attribution from the session's selection before it enables follow-selection.
  - Child callbacks keep the target captured when the child was built.
- **Meeting target:** `meetingChanged` stores the target before the persona guard, including a future persona-less on-change guard (the synthetic `on=true, reason=moved` case is not a production restore). A timeout uses its meeting's retained target and never borrows a newer stream's target.

## Review history of this branch

1. **`c21ddb93`:** `streamTarget` returned nil, and `streamTargets` writes were gated on a new `livePeerConnections` set. VM result: 670 tests in 148 suites, **3 failing tests**.
   - Two were regressions in unchanged tests: `AmbientModeRestoreGuardTests.aStartNoLongerCurrentIsStillGated` and `AmbientPrivacyAnnounceTests.anEntryAfterTheStartDeadlineIsAnnouncedWithinTheBound`.
   - The third was the new queued-refusal test.
2. **`4efeadef`:** the configured fallback is restored and `livePeerConnections` is removed. The two regression test files are byte-identical to base. The new test was rewritten around a held worker executor, and it then timed out at its retirement hook on the VM.
3. **`d251eef7` and `8da618d0`:** the queued-refusal test was replaced with the simpler, deterministic form described below.

## The queued-refusal test (`anUnboundStartQueuesAndSupersedesOlderFailure`)

**Root cause of the original failure:** this was a fixture problem, not production behaviour.

- A fake child that speaks no RightyO session protocol reaches EOF without a terminal session event.
- `RightyoInputConsumer.finish()` then throws `invalidLifecycle`.
- The router reports `ambient stopped: input invalidLifecycle` while that older stream is still the connection's latest, so the gate correctly lets the error through.
- That happened before the newer start existed.

**The committed test** (both `nil` and `""` bindings) is synthetic. In order, it:

1. starts and finally ends one stream whose fake child emits the canonical session `started` and terminal events at EOF;
2. waits for that child to complete cleanly;
3. hand-sets `working` and `reloading` so the next start queues, as the sibling refusal tests do;
4. queues the unbound start for another target, and checks that it alone is queued and takes `latest[connection]` and `newestStart`;
5. injects `listener.ambientFailed` for the older stream and requires a clean pong, so the older failure is suppressed;
6. releases the queue, then requires exactly one `ambient unavailable: target_binding_unavailable` error, one child in total, and a final clean pong.

**Deferred:** a real concurrent forced-retirement race, with real older children failing while a refused start waits behind in-flight work, is not exercised here.

## Other synthetic coverage

`AmbientRouterStreamTargetTests` and its sibling extensions cover:

- Optional pre-admission scope bindings. Non-configured targets require a non-empty binding, and configured starts keep the startup binding.
- Consumer, dispatcher and voice-route destinations, reload retention, and active and idle status.
- Binding refusals:
  - in queue order;
  - dead-start pruning;
  - no child built and no room made, even with every slot full.
- `makePipeline` callback wiring for prebound non-configured streams, covering stop, mute, media, voice notes, acknowledgements, heard and overheard, route refusal and not-sent confirmations.
- Meeting and privacy child callbacks keeping their target across snapshot replacement, clearing and queued playback.
- A future persona-less on-change keeping its target; production restores use `resumed_unrecorded`, which has a persona.
- Snapshot clearing on stop and shutdown, and the closed and shutdown write guards.
- `AmbientAudioGateTests.admitsAStreamWithGapsAndEndsOnFinal`, checking the pinned target and nil binding.

All of these use authored fixtures and loopback delivery. None of them is capture, real binding resolution or physical playback.

## Verification

- **Dev Work VM**, at `8da618d0c0eabf0c3cc56a5f3f7e0bdf99c7da2b` (Swift 6.3.3, Command Line Tools with the Testing framework flags; iteration only):
  - `swift test --skip-build --no-parallel --filter 'HailDaemonKitTests\.(Ambient|TaskProgress|GuardBudget)'`: **670 tests in 148 suites passed**.
  - `AmbientRouterStreamTargetTests` alone passed three consecutive runs (13 tests each).
- **Strict SwiftLint** on each changed Swift file: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>`.
- **Host gate** (Xcode Swift 6.2.4) and CI: recorded in the PR body for the final head.
- **Not run:** physical-device proof and any live haild change. The full unfiltered suite is left to CI.

Production files by `scripts/pr-shape.py` counting: **3**, namely `AmbientAudioGate.swift`, `WebSocketListener.swift` and `WebSocketListener+MeetingMode.swift`. Duck mode is byte-identical to PR 1.
