# #327 PR 1 — ambient router stream targets

Host-local groundwork only. The gate and router still admit only the configured startup target. No follow-selection flag or device behavior is enabled.

## Independent review follow-up

The user supplied an independent **REQUEST CHANGES** review of `fd8bc3ae91eba6613c8b64835474bfee2bf2c40f`. This follow-up accepts both major findings, using the agreed removal for finding 2. Reviewer identity, evidence URL and review-round number were not supplied here; this document does not invent a completed approval record. The new commit needs fresh independent review after VM verification.

1. **Confirmation attribution:** `makePipeline` passes its immutable destination to every child callback. Meeting entry/exit, the private-meeting status, privacy entry/exit/status/hints/negations/unverified-owner clips and unavailable-child announcements retain that target through their queues. Meeting timeouts retain the target that armed the meeting; restores snapshot their new stream under the state lock. Privacy recovery clips retain the registering stream's target or their parent entry's target. `confirmVoiceMute` now requires an explicit target. Device `set_privacy` snapshots the connection when the action is accepted; privacy pre-arm has no clip.
2. **Unbounded binding lookup:** `streamBinding`, `needsBindingResolution` and the binding await in `work` are removed. A non-configured target is refused inline with `target_binding_unavailable`, even while the worker/reload is busy, without queuing, constructing a child, consulting a listing or making room. Configured-target starts retain `configuration.binding` and their original inline/queue/make-room ordering. `Destination` and `Active.target`/`Active.binding` remain; PR 2 must supply any other binding resolved before admission, with no router await.

STARTED now groups the admitted target and selection generation in immutable `AmbientStreamScope`. The target-aware `started(stream:connection:target:selection:)` constructor remains. The three-value event pattern lets `WebSocketListener+PrivacyPark.swift` return exactly to the pre-PR version, keeping this cumulative PR within its four-production-file limit without rewriting history.

## Scope and traceability

- STARTED carries the gate's pinned target and opening selection generation.
- Active retains each stream's target and binding across reloads. Idle status reports the configured target.
- Consumer/dispatcher, acknowledgements, heard/overheard messages, dismiss/mute confirmations and refusal notices receive explicit stream destinations.
- `streamTargets` retains the last admitted target through stream end, clears on `stop(connection:)` and shutdown, and is not written while the connection is marked closed or the router is shutting down.
- Admission/policy generation (#1028), selection generation (#636), named voice-route authorization, privacy/duck/meeting/media decisions, take-over (#366), and reply-reference authorization (#230) keep their existing checks. Named request routing remains separate from STARTED admission.

## Caller audit

All production callers of the three delivery functions, and every production use of `streamTarget(on:)`, are listed below. No delivery function resolves its target at playback time.

| Function / caller | Why the target is correct |
| --- | --- |
| `confirmVoiceMute` ← `carryOutVoiceMute` | Explicit target captured by the child's `voiceMuted` builder. |
| `confirmVoiceMute` ← `voiceMedia`, private-entry status branch | Explicit child target, retained through the privacy chain. |
| `confirmVoiceMute` ← `voiceMedia`, normal confirmation branch | Same child target, retained while waiting for the device notice. |
| `confirmVoiceMute` ← `voiceNote` | Explicit child target, retained while saving the note. |
| `confirmVoiceMute` ← `confirmNotSent` | Explicit origin from `tellNotSent`, retained through acknowledgement and privacy ordering. |
| `confirmVoiceMute` ← `sayPrivacy` | Required target passed through `voiceClip` / `entryClip` / `announceRefusal`. Voice callbacks get the child's destination; refused starts get STARTED's target; registration recovery gets the registering stream's target; cap recovery gets its parent entry's target; device clips get the action-time connection snapshot. |
| `confirmVoiceMute` ← `voiceMeeting`, private-entry status branch | Explicit child target, retained through the privacy chain. |
| `confirmVoiceMute` ← `meetingChanged` | Voice changes pass their child target; timeout uses the target retained with the meeting; restore snapshots its new stream under the state lock before enqueueing and stores it for the timeout. |
| `acknowledgeAmbient` ← `acknowledged` | Explicit originating child target, retained through the acknowledgement hold. |
| `acknowledgeAmbient` ← `confirmVoiceMute` | Forwards its required explicit target; there is no optional fallback. |
| `acknowledgeAmbient` ← `confirmStop` | Origin captured by `dismissed` before stopping playback and awaiting confirmation. |
| `showRouteRefusal` ← `tellNotSent` | Notice tuple retains the originating child target from `voiceRouteRefused` or `deliveryRefused`, even while awaiting the earlier acknowledgement. |
| `streamTarget(on:)` ← its locking overload | Delegates to the under-lock snapshot helper; no asynchronous work occurs in the lookup. |
| `streamTarget(on:)` ← `switchPrivacy` | Explicit device-originated path: action-time snapshot before queueing `deviceClip`; configured fallback covers no-stream device actions. |
| `streamTarget(on:in:)` ← `setMeeting` | Used only when no explicit child target was supplied: the production timeout first uses the stored meeting target; direct internal state tests can snapshot current state. Actual child callbacks always pass a target. |
| `streamTarget(on:in:)` ← `meetingChanged` | Restore/system mode changes snapshot the current stream while holding the state lock, before enqueueing; child voice changes pass their target explicitly. |

`duckUnsupported` itself only decides/refuses and logs: it sends no clip. The child's ensuing `.unavailable` callback uses the same target captured by `voiceDuck`. `ambientPrivacyPreArm` only holds privacy and posts a device mode notice, with no target-bearing clip. Existing direct test calls to `confirmVoiceMute` and `sayPrivacy` now explicitly name their rig's target.

## Tests added or updated — not yet run

`AmbientRouterStreamTargetTests`:

- `startedTargetDrivesTheConsumerDispatcherAndReload`: four consumer/dispatcher/reload combinations now start the **configured** deck target; named routing to scratch retains deck as the source. No test relies on STARTED resolving another target.
- `aDifferentTargetIsRefusedInlineWithoutDelayingTheConfiguredStart`: both idle and held-worker cases; a listed/alive/policy-bound non-configured target is refused synchronously, launches nothing and occupies no queue entry. The following configured start remains inline when idle, or keeps its exact `[start, segment, end]` order while queued. Replaces the removed binding-resolution cases.
- `configuredTargetKeepsItsStartupBindingAfterTheListingChanges`: startup binding remains pinned.
- `streamTargetsAreClearedByStopAndShutdownAndNeverSetWhileClosed`: teardown while a start can still be in flight, a late closed-connection start, shutdown and a late post-shutdown start.

`AmbientRouterConfirmationTargetTests.swift` extends that suite through the existing internal callback-builder/state seams; no test-only production API was added:

- `meetingCallbacksKeepTheirStreamTarget`: meeting entry, exit and timeout, each with the connection target replaced or cleared (six combinations).
- `privacyCallbacksKeepTheirStreamTarget`: privacy entry, exit, status, hint, unverified owner, negation, unavailable child and private-meeting refusal, each with the connection target replaced or cleared (sixteen combinations).

The confirmation tests use two allowed synthetic destinations. The phone selects the callback's originating target, which differs from the router's configured fallback. With no active-stream fallback available, the connection snapshot is changed/cleared after callback construction and before invocation; a latch also delays playback. Confirmation text/audio must still reach the originating target through the listener's normal selection/policy checks. This exercises both late callback invocation and queued playback.

Existing tests of callback builders/registration now pass their synthetic stream targets explicitly; selection tests read the generation from STARTED's scope.

## Production file count

Cumulative PR count: **4**, using the exact exclusions and rename handling from `scripts/pr-shape.py`; no renames:

- `Sources/HailDaemonKit/Listener/AmbientAudioGate.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener+MeetingMode.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener+DuckMode.swift`

The follow-up touches five production paths because it also restores `WebSocketListener+PrivacyPark.swift` to the pre-PR content; that restored path is absent from the cumulative PR diff. Tests and this document are excluded by the checker.

## Verification

**Tests are not yet run. No builds or tests were run on this live-voice host for the review follow-up.** Iteration builds and focused tests are delegated by the user to the briefing session on the Dev Work VM. This session did not launch VM work itself.

Every Swift file changed in either PR 1 or the follow-up, including the reverted privacy-park path, is linted individually and serially with the host SwiftLint:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <one-file>
```

The shell initially pointed at Command Line Tools; bare invocations failed to load SourceKit before linting. Selecting the installed Xcode with the per-command environment variable resolved that tool-loading failure. Line/file/function length violations found on working revisions were corrected before final lint. **Final result: all 33 Swift files passed strict lint individually, with 0 violations.** The corrected gate file and final unchanged-order router cleanup also passed focused reruns. `git diff --check` passed. No build/test command was used for this verification.

Historical `fd8bc3ae` verification: the prior session interrupted two host test-build attempts before any test ran (first exit 130, then exit 1 after ten minutes without build output). Those attempts are not evidence that this follow-up compiles or that any test passes.

## Deferred / not proven

The Dev Work VM must compile and run `AmbientRouterStreamTargetTests` (including its confirmation extension) and the affected focused regressions for policy/selection generations, reload, take-over, privacy/modes, acknowledgements, heard/overheard delivery, stop/mute confirmations, reply references and task progress. Compilation and runtime results remain unverified here. No simulator/app build, physical-device capture or playback, live captured-output round trip, installation, upload, daemon restart or push is performed in this follow-up. No `haild` process, launch agent, private configuration or target allowlist is changed.

The supplied independent review remains REQUEST CHANGES until a real fresh exact-head review completes. This document records implementation work, not approval or passing GitHub checks. Follow-selection gate/session/flag work belongs to PR 2; deployment and physical checks belong to a later authorized delivery slice.
