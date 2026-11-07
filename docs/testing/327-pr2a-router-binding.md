# #327 PR 2a — pre-admission router binding

Local implementation on `feat/327-follow-selection-router`, based on PR 1 #1113's merge
`5793b82f61c5cb71b63e56bd2af69eeda9c3d71f`. This is router groundwork. The production gate still pins its
configured target, admits only that target, and emits a nil binding. No follow-selection flag, binding resolver,
deployment, or two-session device behavior is enabled here.

The plan is issue #327 comment 6710189582. The PR 1 independent second-key record is comment 6709937206
(approved head `0b4e53a83eae15180cc0390a3538ed293a40464c`). That approval covers PR 1, not this change.
The older PR 1 testing document is historical; this record describes PR 2a and its current verification limits.

## Decisions and carry-forwards

- `AmbientStreamScope.binding` is optional and immutable. Nil means none was resolved before admission.
  Configured-target starts always retain `configuration.binding`, even with a conflicting scope binding.
  Other targets require a non-empty scope binding; the router never looks one up or awaits resolution.
- Every start reaches the same `latest`, `newestStart`, privacy-life reapplication, bounded queue and dead-start
  pruning. An unbound start is refused with `target_binding_unavailable` in normal queue order. A newer start
  still prunes an older queued start; a start ended other than final before service is skipped as before.
- **A binding-refused start cannot make room.** It neither forces a retired child out nor constructs a child,
  including when all child slots are occupied. It waits behind earlier work/reload when necessary. Configured
  starts keep their existing room-making and startup path.
- `streamTarget` returns nil without a live connection's admitted snapshot; it never guesses the configured
  target. Child callbacks keep their explicit captured destination. Meeting/system clips with no target are
  suppressed. A timeout uses only the meeting's retained target, never a newer stream's destination.
- Meeting target storage happens once in `meetingChanged`, before the persona guard, including a restore/move
  that has no persona. `setMeeting` no longer duplicates the target write.
- Device privacy snapshots the target before queueing. With no target, the privacy state change, reply hold,
  owner-off and device notices still run; only its target-bearing clip is suppressed. Pre-arm already has no
  clip and remains target-independent. Stream-end retention supports privacy-off after capture ends.
- The listener mirrors peer membership synchronously into a bounded UUID set on every peer dictionary change.
  The router checks it under its state lock before storing or reading a snapshot. No async lookup is involved;
  removal precedes teardown, and a late start cannot re-add `streamTargets` after `closed` has been pruned.
  The snapshot is attribution, not delivery authority: existing selection, policy and privacy checks still apply.

## Synthetic coverage added/extended — execution pending

All cases belong to `AmbientRouterStreamTargetTests` and its sibling-file extensions unless noted:

- `startedTargetDrivesTheConsumerDispatcherAndReload`: starts deck with binding `d` while scratch is configured;
  consumer delivery and named routing verify destination/binding, dispatcher source target, reload retention,
  active status, retained connection snapshot and idle configured status (four combinations).
- `configuredTargetKeepsItsStartupBindingAfterTheListingChanges`: conflicting scope binding is ignored.
- `anUnboundStartQueuesAndSupersedesOlderFailure`: nil and empty binding; refusal waits behind an earlier event,
  launches nothing, updates latest/newest, and an older normally ended stream's late failure stays suppressed.
- `anUnboundStartNeverMakesRoomEvenWhenQueued`: full child slots, inline and queued variants; no forced eviction.
- `deadUnboundStartsArePrunedLikeOtherStarts`: a queued start superseded before service produces no refusal/child.
- `everyConfirmationUsesTheStartedPreboundTarget`: actual `makePipeline` wiring through fake children and a
  loopback listener for stop/dismissed/confirmStop, mute, media, Markdown voice note, ack, heard, overheard,
  route-refusal and delivery-not-sent/tellNotSent. Checks target-bearing clip frames and heard/overheard IDs;
  route errors have no frame target, so their successful delivery exercises the explicit source-target guard.
- `meetingCallbacksKeepTheirStreamTarget` and `privacyCallbacksKeepTheirStreamTarget`: existing entry/exit/timeout
  and privacy entry/exit/status/hint/unverified/negation/unavailable/private-meeting cases now begin with a real
  prebound non-configured stream, then replace/clear its snapshot and delay playback behind a latch.
- `aPersonaLessMeetingRestoreRetainsItsTargetBeforeTheClipGuard` and
  `aTargetlessMeetingTimeoutDoesNotBorrowTheCurrentStreamTarget`: retain before the guard; no guessed timeout clip.
- `aPrunedClosedConnectionNeverRegainsAStreamTarget`, plus the existing stop/shutdown lifetime test: late starts
  cannot repopulate the map, even after real peer removal and pruning.
- `privacyPreArmAndDeviceOffWorkWithoutGuessingATarget`: targetless state changes proceed without a guessed clip.
- `AmbientAudioGateTests.admitsAStreamWithGapsAndEndsOnFinal`: explicitly checks the pinned target and nil binding.

Test helpers inject only the known synthetic `reply-binding` before forwarding STARTED, with
`recipient:other` configured and `recipient:reply` selected/admitted by the unchanged gate. They do not implement
production follow-selection or claim to verify a real resolver.

## Verification and outstanding work

No Swift build or test, simulator build, physical-device capture/playback, live captured-output round trip,
installation, upload, daemon restart, push or PR creation was performed. The live-voice host's daemon, launch
agents, private configuration and target list were untouched. Only the two explicitly authorized GitHub reads
were made. No independent review of PR 2a has been requested or completed in this session.

Every changed Swift file is linted individually and serially with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <one-file>
```

The bare command initially failed loading SourceKit under Command Line Tools. Selecting Xcode per command fixed
that environment failure. All **14 changed Swift files passed strict lint individually with 0 violations**;
`git diff --check` passed. Compilation and runtime behavior remain unverified here.

The briefing session must build and run the focused tests on the Dev Work VM, including the ambient gate,
router stream targets (all sibling extensions), reload/take-over, policy/selection generation, privacy pre-arm,
privacy/mode restore, device privacy, acknowledgements, heard/overheard, stop/mute/media/note, route/not-sent and
reply-reference regressions. Fresh independent exact-head review is required before any later PR is ready.
PR 2b supplies bounded pre-admission resolution and follow-selection admission/flag behavior. Deployment and
physical two-session validation are later, separately authorized work.

Production file count: **4**, using `scripts/pr-shape.py` exclusions and rename handling (no renames):
`AmbientAudioGate.swift`, `WebSocketListener.swift`, `WebSocketListener+MeetingMode.swift`, and
`WebSocketListener+DuckMode.swift`, all under `Sources/HailDaemonKit/Listener/`. Tests and this document are excluded.
