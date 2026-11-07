# #327 PR 2a — pre-admission router binding

Local implementation on `feat/327-follow-selection-router`, based on PR 1 #1113's merge
`5793b82f61c5cb71b63e56bd2af69eeda9c3d71f`. This is router groundwork. The production gate still pins its
configured target, admits only that target, and emits a nil binding. No follow-selection flag, resolver,
deployment, or two-session device behavior is enabled here. PR 2a preserves existing device behavior.

The plan is issue #327 comment 6710189582. The PR 1 independent second-key record is comment 6709937206
(approved head `0b4e53a83eae15180cc0390a3538ed293a40464c`). That approval covers PR 1, not PR 2a.

## VM result supplied for c21ddb93

The briefing session reported that the Dev Work VM (Swift 6.3.3) built `c21ddb93ab8353cc6ccbf159266b7867a99ab9e8`
and ran:

```sh
swift test --no-parallel --filter 'HailDaemonKitTests\.(Ambient|TaskProgress|GuardBudget)'
```

Result: **670 tests in 148 suites, 6 issues, 3 failing tests**. The following fixes are a new commit on top;
that VM result does not validate this follow-up. No build or test was run on this host.

## Regression repairs

1. `AmbientModeRestoreGuardTests.aStartNoLongerCurrentIsStillGated` lost its unreported meeting confirmation.
   `AmbientPrivacyAnnounceTests.anEntryAfterTheStartDeadlineIsAnnouncedWithinTheBound` lost another connection's
   unsupported-version confirmation, then exhausted its bound. Restore the nonoptional `String` lookup and its
   explicit configured-target fallback for device/system actions without an admitted target. Remove
   `livePeerConnections` completely, including the listener's `peers` observer. Target snapshots are written only
   when not shutting down and not closed, as in PR 1. A late callback after a closed mark is pruned can re-add a
   snapshot, bounded by connection ids; the gate never starts streams for torn-down peers. No new lock is added.
2. Delivery still requires the session to select the captured/fallback target (`acknowledgementFrames` and related
   checks), so a mismatch fails closed. PR 2b revisits connection-scoped fallback using the session's selection.
   Child callbacks keep their captured targets. `meetingChanged` stores the target before the persona guard,
   including a persona-less restore/move. A timeout uses its meeting's retained target; a hand-built meeting
   without one uses only the configured fallback, never the connection's newer stream target.
3. The two reported regression test files remain unchanged. `AmbientDuckModeTests.swift`,
   `AmbientMeetingTestSupport.swift`, `AmbientWiringTestSupport.swift`, and `GuardBudgetClockTests.swift` are
   restored exactly to PR 1. The existing callback-attribution tests are also restored. A separate
   `PreboundAmbientRouterTestSupport.swift` provides the new PR 2a fixtures, injecting only an authored
   `reply-binding` before forwarding STARTED through the original guard-clock sink.

## Failure 3: fixture failure before the newer start

`anUnboundStartQueuesAndSupersedesOlderFailure` originally started `/bin/cat > /dev/null`, ended that stream
with `.final`, then awaited `boundedSettle` **before** announcing the newer unbound start. The fake emitted no
RightyO session events. EOF reached `RightyoAmbientPipeline.run` → `RightyoInputConsumer.finish`, whose missing
terminal-session guard threw `invalidLifecycle`. The router's `run` catch described it as
`input invalidLifecycle`, then called `listener.ambientFailed` with `ambient stopped: input invalidLifecycle`.
At that time the older stream was still latest, so `AmbientAudioGate.endForFailure` allowed the error. The frame
was already on the socket when the later barrier read it. This was not a late failure reported after a newer start.

The later hand-built `working/reloading` flags and duplicate queued `.ended` did not cause that earlier error;
with the run already settled, that duplicate end had no child to retire. Those mutations did not represent the
intended in-flight race and are removed from this test. The production stale-failure path needs no change.

The replacement (both nil and empty binding) creates two real, finally ended streams whose fake children wait
at a file marker before exiting without terminal events. Full child slots put a configured start onto the real
worker. Its forced-retirement log hook is held on an inherited dedicated executor using the existing bounded
`PolicyWriteGate`, leaving Swift's cooperative pool free. The pending start receives its single superseded end
before the newer unbound start, preserving gate order. That end and the unbound start queue behind the in-flight
work; the newer start updates `latest/newestStart`. Only then does the marker release the older children into
actual EOF failures.
The test checks their exact `input invalidLifecycle` logs and requires a clean pong while the newer start waits.
After releasing the worker it requires only the binding refusal, another clean pong, and no additional child.
There are no manual lifecycle-flag writes or injected duplicate ends in this replacement test.

## Retained synthetic coverage

`AmbientRouterStreamTargetTests` and its sibling extensions cover:

- Immutable optional pre-admission scope bindings; non-configured targets require a non-empty binding.
  Configured starts retain the startup binding despite scope/listing changes.
- Consumer/dispatcher and named routing destinations, reload retention, active and idle status.
- Binding refusals in queue order, latest/newest tracking, dead-start pruning, no child construction and no
  room-making even with full slots. Older failures cannot stop a newer queued start.
- Actual `makePipeline` callback wiring through prebound non-configured streams for stop, mute, media, Markdown
  voice notes, acknowledgements, heard/overheard, route refusal and delivery-not-sent confirmations.
- Existing meeting/privacy child callbacks retaining their explicit target across snapshot replacement/clearing
  and queued playback. Meeting entry/exit/timeout attribution remains covered by the unchanged PR 1 cases.
- Persona-less meeting restore retaining its target before the clip guard; a missing-retained-target timeout
  refusing playback when the configured fallback differs from the session's current stream selection.
- Stop/shutdown snapshot clearing and closed/shutdown write guards; a pruned closed id allowing a late snapshot
  without starting a child on the unbound path; privacy pre-arm/off retaining the configured fallback.
- `AmbientAudioGateTests.admitsAStreamWithGapsAndEndsOnFinal` checking the pinned target and nil binding.

These are authored fixtures and loopback delivery, not capture, real binding resolution or physical playback.

## Verification and handoff

No Swift build/test, simulator build, physical-device proof, live captured-output round trip, installation,
upload, daemon restart, push or PR creation was performed in this follow-up. Neither haild nor private config
was touched. No independent PR 2a review has been requested or completed. The briefing session must rerun the
VM build and focused command above, keeping the two original regression tests unchanged.

Changed Swift files are linted individually and serially with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

Xcode is selected only for these commands because the host's default Command Line Tools cannot load SourceKit.
All **12 Swift files changed by this follow-up passed individual strict lint with 0 violations** on their final
contents. Initial function/file-length violations in the rewritten queue test and meeting-mode file were corrected
and those files were linted again successfully. `git diff --check` passed. No build or runtime test was run here.

Using `scripts/pr-shape.py`'s exact prefix/suffix exclusions and rename handling (no renames):

- This follow-up changes **3 production files**: `WebSocketListener.swift`, `WebSocketListener+DuckMode.swift`,
  and `WebSocketListener+MeetingMode.swift`.
- The cumulative PR 2a diff against `5793b82f61c5cb71b63e56bd2af69eeda9c3d71f` changes **3 production files**:
  `AmbientAudioGate.swift`, `WebSocketListener.swift`, and `WebSocketListener+MeetingMode.swift`. Duck mode is
  restored exactly to PR 1. Tests and this document are excluded by the checker.

Compilation/runtime validation and fresh independent exact-head review remain pending on the follow-up commit.
