# #1246: mute silences audio, preserving pending text and cards

Part of #1246. The owner has adopted this behavior: mute silences audio only; pending
text and cards still show. Evidence here is local and synthetic, not shipped behavior,
physical playback proof, or independent approval of the amended head.

This follow-up is one commit on base `5ba7ea6d7bf6c1440479faaebca1b8fbd4773f26`.
The following older SHAs are historical content references: PR 2 content `887f67094841f94f7afa5b91b63af96fed27192a`
(rebuilt on main as `327c787c`). PR 1 is merged on main as
`13eb68ada66d6589497deeb8cb84e53aa88cd903` (content `0f4333a0`).

## Behavior and review fixes

For a peer advertising `reply_mute`, `muteReplyPlayback` holds a noncancelling publication
barrier across the existing playback stop and the mute flag send. Wire order is:

1. `stop_playback` retires current in-flight playback.
2. `set_reply_mute(true)` reaches the same connection while publication remains held.
3. The barrier releases. Pending answer text, cards and audio can arrive; audio is silent
   under the existing device mute and retained for replay. The mute confirmation text/PCM
   also follows the mute flag and is retained silently, rather than heard before muting.

No pending answer can start in the stop-to-mute gap and trigger deferred device mute.
A failed mute send retires the reply transport before releasing preserved publication.
Mute accepts no request cutoff and does not mark queued-audio tickets. A precondition
rejects preserving requests combined with queued-audio marking or a supplied cancelling
cutoff. Explicit stops, dismissals and privacy keep their cancelling behavior.

A peer advertising playback stop without `reply_mute` instead receives a cancelling stop.
It loses pre-stop pending request authority, marks queued tickets and cancels proactive session-update
speech exactly like explicit stop, receives no unsupported mute flag, and gets
an honest "Stopped." confirmation. Its later pending text and PCM are refused.

Only `WebSocketListener.swift` and `HostReplyDelivery.swift` change in production against
base `5ba7ea6d7bf6c1440479faaebca1b8fbd4773f26`. Scripts remain identical to that base. HailCore/app code is outside this change.
No protocol format change is needed.

## Regression coverage

- `ReplyMuteMixedPathsTests.preservedAudioWaitsAfterStopSendUntilMuteFlagIsSent` holds the
  real `afterStopSend` hook, starts pending audio, waits for the publication latch and
  verifies no completion or PCM on the wire before release. It then verifies mute before
  audio, with both operations completed.
- `ReplyMuteSilencesTests.unsupportedMuteCancelsPendingRequestAndConfirmsStopped` uses
  real spoken-mute wiring for a playback-stop-only peer, verifies its "Stopped." clip,
  request removal and refusal of both pending text and PCM.
- `muteThenExplicitStopRetractsEveryEarlierRequest` covers requests before and after mute,
  an explicit cancelling stop, unmute without authority revival, and a fresh answer.
- `ReplyMuteMixedPathsTests.overlappingMuteAndStopCannotReviveAuthority` holds the first
  control before session retirement in both capture orders and starts a waiting publication.
  Stop revokes every earlier request; newer requests survive only when admitted after
  the stop. Awaiting the blocked publication and then publishing fresh text proves
  no control waiter remains unresolved.
- `privacyWhileMutedRetractsPendingAuthorityThroughExitAndUnmute` enters real router
  privacy while muted, waits for request retirement, exits privacy and unmutes, refuses
  old authority, and delivers a fresh reply.
- `ReplyMuteControlBarrierTests` uses a `VoiceStopConfirmationHold` notification instead
  of polling flags; another connection proceeds while the muted connection waits.
- Existing spoken-mute and queued-audio mute coverage now asserts stop, mute, confirmation order.
  Existing device `ReplyPlaybackMuteTests` cover synthetic mute/playout behavior. Socket
  delivery alone is not evidence of audible or silent physical playback.

No `DispatchSemaphore` waits are introduced.

## Commands and gates

Before every build/test phase run the host-slot gate and then the voice-quiet gate.
Host-specific gate paths stay outside the repository. Scratch is `$SCRATCH`, an external
worktree-adjacent scratch directory. Use the full Xcode developer directory and background
policy; build with two jobs. Do not install or restart a live daemon.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2 --cache-path "$SCRATCH/swift-cache"
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyMute|ReplyPlaybackMuteTests|AmbientWiringVoiceMute'
# Ten separately gated runs of the affected mute, stop-scope and #1246 suites:
taskpolicy -b swift test --parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter '(Mute|ReviewRound[0-9]|FinalDeliveryCommitTests|RecipientPublicationGateTests|ReplyNewRequestQueueTests|ReplyQueueAuthorityTests|ReplyQueueConnectionCheckTests|ReplyQueueLifecycleTests|ReplyQueueStopAcceptanceTests|ReplyQueueStopCoverageTests|ReplyQueuedAudioRoutingTests|ReplyRecipientAuthorityRaceTests|ReplySegmentsBackstopTests|ReplySegmentsHostSessionTests|ReplySegmentsListenerTests|ReplyPrivacyStopScopeTests|ReplyPublicationControlBarrierTests|ReplyStopControlOrderTests)'
# From Tests/ReplyCLITests:
taskpolicy -b python3 -m unittest discover -s .
# From the worktree root, with scratch allocation isolated by the test harness wrapper:
taskpolicy -b bash scripts/tests/test-host.sh
# Once, unfiltered, with a 45-minute work-command deadline:
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache"
taskpolicy -b swiftlint lint --strict --no-cache \
  Sources/HailDaemonKit/Listener/WebSocketListener.swift \
  Sources/HailDaemonKit/Listener/HostReplyDelivery.swift \
  Tests/HailDaemonKitTests/ReplyMuteSilencesTests.swift \
  Tests/HailDaemonKitTests/ReplyMuteControlBarrierTests.swift \
  Tests/HailDaemonKitTests/ReplyMuteMixedPathsTests.swift \
  Tests/HailDaemonKitTests/ReplyMuteRetirementTests.swift \
  Tests/HailDaemonKitTests/AmbientVoiceMuteTests.swift \
  Tests/HailDaemonKitTests/ReplyQueuedAudioMuteTests.swift
```

The ten-run filter selects the Swift test suites changed by PR 1 and PR 2, the round-6
requestless ordering probes, and every mute-named test. It retains all assertions and
parallel mode. The initial larger stress selection (974 tests / 229 suites) also included
unrelated privacy, timing and HailCore families together; its failed result is retained
separately below, rather than represented as a passing run. The unchanged CI script
already separates HailCore from other targets to avoid startup-burst waiter delays.

## Historical mutations before round-2 findings

1. Release the outer mute barrier before calling the playback stop, leaving only the inner
   stop barrier. At `afterStopSend` that inner barrier has released, recreating the unsafe
   gap before `set_reply_mute`. Build and run the preserved-audio wire-order regression;
   an actual assertion/wire failure must detect it.
2. Preserve requests in the unsupported-peer fallback stop. Build and run the unsupported
   spoken-mute regression; an actual authority/PCM assertion failure must detect it.

Restore saved fixed bytes after each mutation, verify equality and rebuild before any
restored validation. Compiler failures, timeouts and empty selections do not count as
mutation detection.

The mutation test commands, each following its own successful gated build, are:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyMuteMixedPathsTests.preservedAudioWaitsAfterStopSendUntilMuteFlagIsSent'
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'ReplyMuteSilencesTests.unsupportedMuteCancelsPendingRequestAndConfirmsStopped'
```

## Historical verification before round-2 findings

Final fixed-source verification completed locally. Work times exclude all host-slot and
voice-quiet waits. The full run had no filter or omitted suites and ran once, within its
45-minute work deadline.

| Phase | Actual result | Work time | Scratch evidence |
| --- | --- | --- | --- |
| Initial build | Passed; 132.93 s Swift | 137.452 s | `review-fix-build.log` |
| Corrected overlap-helper build | Passed; 108.72 s Swift | 114.069 s | `review-fix-corrected-build.log` |
| Barrier mutation build | Passed; 38.67 s Swift | 42.754 s | `review-fix-mutation-barrier-build.log` |
| Barrier mutation regression | Expected exit 1: one test / two assertion issues; 0.236 s test | 10.702 s | `review-fix-mutation-barrier-test.log` |
| Unsupported-peer mutation build | Passed; 38.84 s Swift | 42.649 s | `review-fix-mutation-unsupported-build.log` |
| Unsupported-peer mutation regression | Expected exit 1: one test / four assertion issues; 0.454 s test | 10.732 s | `review-fix-mutation-unsupported-test.log` |
| Restored build | Passed; 45.77 s Swift | 50.086 s | `review-fix-restored-build.log` |
| Restored focused mute tests | 22 tests / 6 suites passed; 4.211 s test | 14.977 s | `review-fix-restored-focused.log` |
| Corrected queued-mute wire expectation build | Passed; 92.19 s Swift | 96.856 s | `review-fix-wire-expectation-build.log` |
| Scoped parallel loop | **10/10 passed**; 101 tests / 34 suites and 3 expected known issues each; 18.344 s test total | 115.842 s total | `review-fix-parallel-1.log` through `review-fix-parallel-10.log` |
| Full Reply CLI suite | 174 tests passed; 465.166 s test | 468.534 s | `review-fix-cli.log` |
| Isolated unchanged host harness | `test-host: OK`, exit 0 | 180.625 s | `review-fix-host.log` |
| Full unfiltered serial Swift suite | **4,255 tests / 894 suites passed**, 13 expected known issues; 1,510.765 s test | 1,522.550 s | `review-fix-full.log` |
| Strict lint | Seven changed Swift files; zero violations | — | `review-fix-lint.log` |

The ten parallel test times, in run order, were 1.444, 1.477, 1.728, 2.420, 1.815,
2.058, 1.788, 2.015, 1.830 and 1.769 seconds. Every invocation exited 0. The three
expected known issues are the existing recipient-publication timeout/cancellation probes.
The full run includes the existing handoff-wait and local-dispatch preflight probes for
thirteen expected known issues total. No known-issue wrapper was added or weakened.
The restored scoped loop and full serial run recorded zero unexpected issues.

Both mutations were detected by real selected tests after successful builds. Early barrier
release let the preserved publication complete and put PCM on the wire before mute.
Unsupported preservation kept the request and accepted both its text and PCM. After each
mutation the listener was restored byte-for-byte to its saved fixed SHA-256, and the
restored build replaced mutant binaries. All seven final Swift source digests remained
unchanged through the parallel loop, CLI, host harness and full serial run. No mutation
remains.

### Corrections and the retained broad stress failure

While strengthening the overlap test, one build attempt failed on a noncopyable
`Mutex<Bool>` helper parameter (78.672 s work; `review-fix-helper-build-failure.log`).
The helper now takes a Sendable completion callback. The corrected build and focused
run passed before mutation verification resumed. That compiler failure is not mutation
evidence. An early lint invocation lacked the selected Xcode environment and could not
load SourceKit; strict lint passed in the required environment after correction.

An initial larger parallel stress run failed: **974 tests / 229 suites**, 123.616 s test,
135.840 s work, runner summary **16 issues including 8 known issues**
(`review-fix-parallel-initial-failure.log`). Its exact filter was:

```sh
taskpolicy -b swift test --skip-build --parallel --cache-path "$SCRATCH/swift-cache" \
  --filter '(Mute|ReviewRound[0-9]|ReplyPublicationControlBarrier|Reply(NewRequestQueue|Queue|PrivacyStopScope|StopControlOrder|QueuedAudio|Mute|Segment|Playback|Recipient|StreamPacer)|RequestStreamLifetime|ProviderTurnRequestLifetime|LateAnswer|FinalDelivery|DeliveryStageOrder|RecipientPublicationGate|HostPlaybackStop|DeviceVoiceStop|AmbientWiringDismiss|AmbientWiringVoiceMute|SessionUpdate|SilentSessionUpdate|TaskProgress|AmbientPrivacy|AmbientDuck|ModeSnapshot)'
```

Three tests failed in that run:

- `ReplyQueuedAudioMuteTests.spokenMuteLeavesQueuedAudioAdmissionUnchanged` still expected
  confirmation text before the mute flag (`expectedText`). Its strict flag expectation
  was moved before the confirmation, matching the adopted wire order. It passed in all
  ten scoped parallel runs and in the full serial suite.
- `ReplyPlaybackMuteTests.theHelloAdvertisesReplyMuteAndTheControlReachesTheReplyPlayer`
  timed out waiting for negotiation. This HailCore test and its implementation are
  unchanged. It passed in all ten scoped parallel runs and in the full serial suite.
- `AmbientPrivacyRoundFourRigTests.aRacingVoiceOffAndDeviceOnEndOnTheirOwnClip` saw a
  late clip-state mismatch. This test and the privacy router files are unchanged. It
  passed in the full serial suite.

The combined 974-test stress selection was not rerun after the queued-mute expectation
correction: **its result remains failed**. The 101-test repeated selection above is the
complete changed-suite set for PR 1 / PR 2 plus round-6 probes and all mute-named tests;
its passing results do not claim a green broader parallel lane or green CI. No baseline
A/B result is claimed, and unrelated HailCore/privacy implementation changes were not
added to this follow-up.

Final checker-based scope against PR 2 content is **2/4 production files, zero renames**.
Scripts match base `5ba7ea6d7bf6c1440479faaebca1b8fbd4773f26`;
HailCore and app source is unchanged. Whitespace, source-integrity and private-path checks
pass. This remains one local amended follow-up commit on the base named above. Fresh independent
review of the amended exact head remains pending; earlier reviews are not approval of
that head. All results here are synthetic, with no physical-device silence proof.

No push, PR creation, live configuration change, install, daemon restart, simulator/device
build or captured-output round trip is included.

## Round-2 review follow-up

The primary round-2 review of historical head
`5c24bdacb4c5cdce103a15cd8e2b2207caae559a` requested changes. Its authority probe
showed a retained in-flight request admitting audio after 64 later requestless stops
evicted the reply UUID from both bounded stop ledgers. The second key approved that
historical head with an unsupported-mute fallback finding. Neither review approves
this amended head; fresh exact-head independent review remains pending.

- `HostReplyRequest.audioStopped` persists audio retirement in the request record.
  Media admission refuses subsequent audio regardless of stop-ledger eviction; the
  retained record still accepts its pending text/card. The stop sets the flag for
  each retained request whose descriptor names a stopped in-flight reply.
- Unsupported mute calls the full explicit stop with queued-audio marking enabled.
  This also cancels proactive session-update speech using the same connection scope
  and generation fence as voice stop and dismissal. Its existing spoken fallback
  regression still verifies the honest "Stopped." confirmation.
- The privacy/mute mixed-path test uses the existing utterance-correlated typed-input
  helper for both requests. The independently formed ambient request can no longer
  break a count-based assertion or select the wrong context.
- The base is `5ba7ea6d7bf6c1440479faaebca1b8fbd4773f26`; earlier SHAs above describe
  historical content and evidence, not current main.

`ReplyMuteRetirementTests.stoppedAudioCannotReviveAfterStopLedgerOverflowAndUnmute`
commits the authority probe as a regression: it starts correlated audio, mutes, retires
65 later requestless replies, proves both bounded stop lookups no longer name the old
reply, unmutes, delivers retained text/card, and refuses the old audio continuation.
`unsupportedMuteStopsQueuedRequestlessAudioAndProactiveSpeech` holds an uncooperative
proactive renderer using continuation notifications, queues requestless audio, applies
the fallback, verifies the proactive cancellation control, joins the renderer and
checks that queued publication is skipped. A socket barrier proves no late PCM.
The new regressions add no semaphore waits or polling loops.

The two required mutations remove the persisted retirement assignment and disable
queue marking in the fallback, respectively. Each must compile and cause its matching
regression to fail assertions. Fixed bytes are restored and checked after each mutation,
then rebuilt before restored verification. All current evidence is local and synthetic.

Round-2 verification first found an over-specific new-test assertion: after `check`
retires a stopped ticket, a subsequent `publish` reports a skipped, expired ticket
rather than another `stopped` reason. The assertion now requires publication to be
skipped; initial admission still requires `stopped`. The failed initial 24-test run
is preserved as `regressions-initial.log`, and the corrected 24-test run passed.

Both mutations compiled and failed their intended assertions without a timeout:

- Omitting persisted retirement admitted the old continuation (`publish` returned 1)
  and placed PCM on the socket after unmute: one test failed with two issues.
- Disabling fallback queue marking omitted proactive cancellation, let the renderer
  complete, kept the ticket playable and placed PCM on the socket: one test failed
  with five issues.

Both production files were restored byte-for-byte from saved fixed source before the
restored build. Raw mutation output remains in external scratch; generated fixture
identifiers and host-specific gate paths are not part of this record.

### Round-2 verification results

Every build/test invocation below ran the host-slot gate followed by the voice-quiet
gate. Work used the Xcode developer directory, `taskpolicy -b`, scratch caches/config
and two jobs for builds. Work times exclude gate waits. Commands are those in
"Commands and gates" above; the parallel filter is unchanged and now includes the two
new `ReplyMuteRetirementTests` through `Mute`. Evidence names below are within the
external scratch `round2-fixes` directory.

| Phase | Actual result | Work time | Evidence |
| --- | --- | --- | --- |
| Initial build | exit 0 | 234.072 s | `build.log` |
| Corrected regression build | exit 0 | 128.156 s | `corrected-build.log` |
| Corrected focused mute run | 24 tests / 7 suites passed, exit 0 | 20.568 s | `regressions.log` |
| Retirement mutation build/test | build exit 0; one test failed two assertions, exit 1 | 51.873 s / 12.956 s | `mutation-retirement-build.log`, `mutation-retirement-test.log` |
| Fallback mutation build/test | build exit 0; one test failed five assertions, exit 1 | 75.737 s / 16.244 s | `mutation-fallback-build.log`, `mutation-fallback-test.log` |
| Restored build | exit 0 | 92.081 s | `restored-build.log` |
| Restored focused mute run | 24 tests / 7 suites passed, exit 0 | 20.381 s | `restored-regressions.log` |
| Affected parallel selection, ten separately gated invocations | **10/10 passed**, 103 tests / 35 suites each, exit 0 each; three expected known issues each | 139.894 s total | `parallel-1.log` through `parallel-10.log`, `parallel-summary.json` |
| Full Reply CLI suite | 174 tests passed, exit 0 | 499.046 s | `cli.log` |
| Host script harness | `test-host: OK`, exit 0 | 200.616 s | `host.log` |
| Full unfiltered Swift run, exactly once | **exit 1**, 4257 tests / 895 suites; one unexpected issue plus 13 expected known issues | 2012.725 s (2002.346 s tests) | `full.log` |
| Final strict SwiftLint, all eight changed Swift files | exit 0, zero violations | — | `lint-final.log` |

The unfiltered run was not green. Its only unexpected issue was
`AudioInputSelectionConcurrencyTests.supersededSaveCannotOverwriteTheLatestPreference`
at `Tests/HailCoreTests/AudioInputSelectionConcurrencyTests.swift:17`: it expected
`AudioInputSelectionError.superseded`, but the earlier task returned without throwing.
The test starts a later selection task and immediately releases the earlier held save,
without a notification proving the later selection has begun. That is a possible
scheduling race, an inference from the fixture rather than a new baseline proof.
HailCore production and tests are byte-identical to the base and outside this follow-up.
Both new mute regressions passed in the full run. No second unfiltered run was made.

All eight tested Swift source digests still match after verification; no mutation remains.
Scripts and workflows match the base. The scope remains **2/4 production files**, zero
renames, with fresh independent exact-head review pending. This record does not claim
green CI, shipped behavior, simulator/device testing, or physical silence proof.

After the full run, one separately gated isolated recheck used:

```sh
taskpolicy -b swift test --no-parallel --skip-build --cache-path "$SCRATCH/swift-cache" \
  --filter 'AudioInputSelectionConcurrencyTests.supersededSaveCannotOverwriteTheLatestPreference'
```

It passed (one test / one suite, exit 0, 12.934 s work; `selection-recheck.log`). This
separate pass does not change the failed unfiltered result or establish a baseline A/B
result. No HailCore fix was added.

## Round-3 review follow-up: audio-only retirement for retained requests

The primary round-3 review of historical head
`d00137957c2c0e3983bd0526fafaf23b876af583` found that a retained request's pending
text/card was still refused immediately after mute. Both whole-reply stop ledgers
rejected the reply ID before media admission could distinguish text from stopped audio.
The round-2 regression delivered its text only after ledger eviction and masked this.

Capable mute now sets the retained request's persisted `audioStopped` flag while excluding
its reply ID from **both** whole-reply stop ledgers. Its pending final text and card can
publish immediately; its audio cannot resume before or after ledger overflow or unmute.
A removed or expired correlated request still has no recipient authority and cannot fall
back to requestless routing. Explicit stop, voice stop, dismissal, unsupported-device
fallback and privacy retain their existing whole-reply ledger and cancellation behavior.

Requestless/uncorrelated flights have no retained request record. This change deliberately
keeps them in the existing bounded whole-reply ledgers, refusing later audio and text for
those IDs while recorded. It does not introduce a new requestless lifetime guarantee.
Fresh reply IDs and retained correlated requests continue through ordinary admission.
The transport barrier still orders stop before mute before waiting publication, and a
failed mute send still retires the transport. Audio newly starting while muted remains
subject to the existing device mute, with replay retained; this is synthetic host/socket
and device-controller evidence, not physical silence proof.

`ReplyMuteRetirementTests.inFlightMuteDeliversPendingTextAndCardWithoutRevivingAudio`
starts audio for two retained requests and mutes. It delivers the first request's final
text and card immediately, proves neither stop ledger contains either correlated ID,
and refuses audio for both. It then retires 65 requestless flights, verifies their
whole-reply ledger entries and refusal of text and audio while recorded, and proves
a sentinel has actually been evicted from both ledgers. The second retained request's
text/card then delivers while still muted. Audio for both retained requests is refused
after overflow and again after unmute, and the socket barrier finds no leaked audio.

The protocol carries Markdown cards in `metadata` on the same final-text frame. It has no
independent card frame or second final text for one request. The regression therefore
runs both supported field orders, decoding metadata-before-text and text-before-metadata
inputs and verifying atomic delivery of both fields. It does not claim separate card
arrival or change the wire contract. No blocking wait or polling is introduced.

The required mutation restores retained mute reply IDs to the whole-reply ledger set,
affecting both session and listener ledgers through the existing stop result. It must
compile and fail the immediate-delivery regression, then restore the exact fixed bytes
and rebuild before final verification. Evidence is kept in external scratch
`round3-mute-fix`; no host-specific paths are recorded here.

### Round-3 verification results

Every build/test invocation runs the host-slot gate and then the full voice-quiet gate.
Commands match "Commands and gates" above, using the Xcode developer directory,
background policy, two build jobs and external scratch caches/configuration. Work times
exclude gates. The parallel filter is unchanged. The full Swift command is unfiltered,
serial, invoked once, and has a 45-minute work deadline.

The mutation compiled, then both field-order cases failed on actual ledger-membership
assertions and immediate text publication with `replyStopped`: one test in one suite,
14 issues in 0.612 seconds, exit 1. This was not a compiler failure or timeout. Fixed
source bytes were restored exactly before the restored build.

| Phase | Actual result | Work time | Scratch evidence |
| --- | --- | --- | --- |
| Initial build | exit 0 | 167.831 s | `build.log` |
| Initial focused mute selection | 24 tests / 7 suites passed, exit 0 | 20.454 s | `regressions.log` |
| Whole-reply-ledger mutation build | exit 0 | 49.632 s | `mutation-build.log` |
| Mutation regression, both field orders | expected exit 1, 14 issues | 11.912 s | `mutation-test.log` |
| Restored build | exit 0 | 50.647 s | `restored-build.log` |
| Restored focused mute selection | 24 tests / 7 suites passed, exit 0 | 18.345 s | `restored-regressions.log` |
| Affected parallel selection, ten separately gated invocations | **10/10 passed**, 103 tests / 35 suites each; three expected known issues each, no unexpected failures | 147.099 s total | `parallel-1.log` through `parallel-10.log`, `parallel-summary.json` |
| Full Reply CLI suite | 174 tests passed, exit 0 | 509.723 s (505.855 s tests) | `cli.log` |
| Host script harness | `test-host: OK`, exit 0 | 198.964 s | `host.log` |
| Full unfiltered serial Swift run, exactly once | **exit 0**, 4,257 tests / 895 suites passed; 13 expected known issues, zero unexpected failures | 1,946.482 s (1,936.660 s tests) | `full.log` |
| Final strict SwiftLint, all eight changed Swift files | exit 0, zero violations | 6.569 s | `lint.log` |

All requested verification completed successfully. The full run's 13 expected known
issues remain in `LocalDispatchPreflightWaitTests` (five), `RecipientPublicationGateTests`
(three), and `ReplyRecipientHandoffWaitTests` (five). No known-issue annotation was added.
Both new field-order cases passed in the full run. The historical round-2 unfiltered
failure above remains a separate result; it is not relabelled as passing.

Both production files and seven of the eight changed Swift files match the executed
source digests exactly. After the full run, three leading-indent lines in the regression
helper were normalized; a line-by-line comparison confirms every nonindent byte is
unchanged. Final strict lint covers those final bytes. `tested-digests.json` records
executed bytes, `final-digests.json` records final bytes, and `indentation-only.json`
records that comparison. No mutation remains.

Checker-based scope against `5ba7ea6d7bf6c1440479faaebca1b8fbd4773f26` is **2/4 production
files, zero renames**. Scripts, workflows, HailCore and app source match that base.
Documentation contains no home-directory or private host-tool paths. This remains one
local amended commit on that base, with no push, PR action, live configuration change,
installation, daemon restart, simulator/device build or captured-output round trip.
Fresh independent exact-head review remains pending. All evidence here is local and
synthetic; no shipped behavior or physical silence proof is claimed.

## Test-only review follow-up: completion notifications

This follow-up addresses the P3 scheduling finding against historical head
`990df03892e07439eeed90b20904111d6eba9c2b`. Production files are unchanged from that
head; only test code and this record change. Earlier review and verification records
above retain their original scope.

State waits now use explicit completion notifications:

- `ReplyMuteMixedPathsTests` waits for `ambient_started`, then the fixture adapter's
  first context notification. That handoff follows admission of the duck-v3 start
  line, so privacy entry is attempted once and its reported-child assertion remains.
- Both typed requests use their own utterance IDs and a socket pong acknowledging
  completion of the preceding typed dispatch. The context and pending-record
  assertions remain; an unrelated ambient request cannot satisfy them.
- Privacy entry waits for `ambient_privacy_replies dropped=...`, emitted after the
  pending-record drop. Privacy exit waits for `released=true`, emitted after clearing
  the hold. The request-removal and released-hold assertions remain separate checks.
- The mixed-path fixture's successful teardown waits for `ambient_ended`, replacing
  the polling `DuckRig.finish`/bounded-settle path. Error cleanup stops the listener.
- `ReplyMuteSilencesTests` and its unsupported-peer case wait for `ambient_started`
  and still require an active connection before releasing the spoken command.
- The shared stop/mute shell fixture blocks on a FIFO read in place of checking for
  a release file every 20 ms. The mute fixture writes the release from a dispatch
  queue and resumes a continuation; no Swift worker blocks on FIFO startup.
- `ReplyQueuedAudioMuteTests` and `AmbientWiringVoiceMuteTests`' shared runner wait
  on latches signalled after recording `ambient_voice_mute`. Their existing outcome
  assertions remain. The shared runner also waits on `ambient_ended` at teardown.

No sleep, polling loop, semaphore wait or state-wait deadline is added. Existing suite
limits and shared socket I/O cancellation bounds retain their existing behavior.
The adapter's context stream and `DuckRig`'s optional event callback are test-only
hooks; other callers retain their existing setup.

Every build/test invocation runs the host-slot gate followed by the voice-quiet gate.
The Xcode developer directory is exported; scratch caches, configuration, security
state and temporary files stay outside the worktree. Exact work commands, with
`$SCRATCH` denoting the external scratch directory:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export TMPDIR="$SCRATCH/test-only-notifications/tmp/"
taskpolicy -b swift build --build-tests -j 2 \
  --cache-path "$SCRATCH/swift-cache" --config-path "$SCRATCH/config" \
  --security-path "$SCRATCH/security"
# Twenty separately gated invocations:
taskpolicy -b swift test --skip-build --parallel --filter 'ReplyMute|AmbientWiringVoiceMute' \
  --cache-path "$SCRATCH/swift-cache" --config-path "$SCRATCH/config" \
  --security-path "$SCRATCH/security"
# All mute and stop suites, plus the affected request/queue/publication scope suites, once:
taskpolicy -b swift test --skip-build --no-parallel \
  --filter '(Mute|Stop|ReviewRound[0-9]|FinalDeliveryCommitTests|RecipientPublicationGateTests|ReplyNewRequestQueueTests|ReplyQueueAuthorityTests|ReplyQueueConnectionCheckTests|ReplyQueueLifecycleTests|ReplyQueuedAudioRoutingTests|ReplyRecipientAuthorityRaceTests|ReplySegmentsBackstopTests|ReplySegmentsHostSessionTests|ReplySegmentsListenerTests|ReplyPublicationControlBarrierTests)' \
  --cache-path "$SCRATCH/swift-cache" --config-path "$SCRATCH/config" \
  --security-path "$SCRATCH/security"
```

The initial build failed on a missing `await` in the new privacy-hold assertion and
also reported a fixture edited while that failed build was still running. No tests
ran from that attempt. Its log is preserved as `build-initial.log`; it is not passing
verification. The corrected, separately gated build passed with Swift files unchanged
throughout execution. Initial strict lint found two function-length violations and
one file-length violation; extracting the shared outcome recorder and adjusting spacing
resolved them. Final strict lint passed for all eight changed Swift files.

| Phase | Actual result | Work time, excluding gates | Scratch evidence |
| --- | --- | --- | --- |
| Initial build | exit 1, compiler diagnostics described above | 488.578 s | `build-initial.log` |
| Corrected build | exit 0, Swift build complete | 162.902 s | `build.log` |
| Final strict lint | exit 0, zero violations in eight files | — | `lint-final.log` |
| All mute and stop-scope selection, exactly once serial | **exit 0**, 316 tests / 169 suites passed; 3 existing known issues, zero unexpected failures | 162.731 s (150.273 s tests) | `serial.log` |
| Requested parallel filter, twenty separately gated invocations | **20/20 passed**, 19 tests / 7 suites each; exit 0 each, zero known or unexpected issues | 184.705 s total (35.813 s tests) | `parallel-01.log` through `parallel-20.log`, `parallel-summary.json` |

The twenty parallel test times, in run order, were 1.602, 1.850, 2.117, 1.744, 1.563,
1.702, 1.723, 1.493, 2.125, 1.686, 1.426, 2.044, 1.685, 1.749, 1.638, 1.750,
1.894, 1.924, 2.227 and 1.871 seconds. All twenty gates completed before their own
invocation. No retry or extra parallel invocation was needed.

The serial run's three expected known issues are the unchanged timeout/cancellation
probes in `RecipientPublicationGateTests`: two parameter cases of
`policyTimeoutRecordsOneInconclusiveIssue` and
`publicationTimeoutFailsClosedAndRecordsOneInconclusiveIssue`. No known-issue wrapper
was added or weakened. The serial run also passed the existing
`SessionUpdateStopRegressionTests.spokenMuteKeepsRunningSessionUpdateSpeech`, exercising
the shared FIFO fixture's existing empty-data release caller.

Final wait locations (line numbers in this test-only revision):

| Awaited state | Test or fixture location | Completion signal |
| --- | --- | --- |
| Mixed-path connection | `ReplyMuteMixedPathsTests.swift:108` | `ambient_started` latch |
| Child ready for one privacy-entry attempt | `ReplyMuteMixedPathsTests.swift:114` | Adapter context stream following admitted start |
| Typed request context and pending record, both requests | `ReplyMuteMixedPathsTests.swift:116`, `:132`; `ReplyMuteTestSupport.swift:70` | Pong after serial typed dispatch |
| Pending request dropped | `ReplyMuteMixedPathsTests.swift:122` | Privacy drop notification |
| Privacy hold released | `ReplyMuteMixedPathsTests.swift:125` | Privacy release notification |
| Mixed-path teardown | `ReplyMuteMixedPathsTests.swift:139` | `ambient_ended` latch |
| Spoken-mute active connection, including unsupported peer | `ReplyMuteSilencesTests.swift:66`, `:131`; `ReplyMuteTestSupport.swift:44` | `ambient_started` latch, followed by active-connection assertion |
| Shared fixture release | `SessionUpdateStopTestSupport.swift:85`; `ReplyMuteTestSupport.swift:10` | FIFO read/write and continuation |
| Queued-audio mute outcome | `ReplyQueuedAudioMuteTests.swift:26` | Recorded-outcome latch |
| Shared voice-mute outcome and teardown | `AmbientVoiceMuteTestSupport.swift:41`, `:46` | Recorded-outcome and `ambient_ended` latches |

All eight final Swift file SHA-256 digests match `source-digests.json`, captured before
the successful build. The same bytes were used for all twenty parallel invocations
and the single serial invocation. No production mutation was made in this follow-up.
Whitespace and private-path checks pass. Against
`990df03892e07439eeed90b20904111d6eba9c2b`, the diff contains only `Tests/` and this
record; `Sources/`, `scripts/` and `.github/` are byte-identical to that head.

The single local commit is amended with its message unchanged on base
`5ba7ea6d7bf6c1440479faaebca1b8fbd4773f26`. No push, PR action, installed build change,
live service change or remote execution is included. Fresh independent review of the
amended exact head remains pending. All evidence is local and synthetic; this does not
claim shipped behavior or physical-device silence proof.
