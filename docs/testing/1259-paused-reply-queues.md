# Paused replies queue subsequent replies (#1259)

This is host-local synthetic evidence for the owner's #1259 decision, which supersedes #321's
newest-wins discard. It is not shipped, installed, TestFlight, physical-device, or live audio proof.

New ordinary audio appends to the existing FIFO even while paused. The current player buffer and
cursor remain intact. Resume plays the retained remainder, then handles each queued reply in arrival order.
Explicit stop still cancels the buffer and retires stopped identities so late frames cannot restart them.
Session-update authorization, measured-quiet admission, and retirement policy are unchanged.

Four production files change: `ReplyPlaybackController+Proactive.swift`,
`ReplyPlaybackController+Stop.swift`, `ReplyPlaybackController.swift`, and
`ReplyAudioProblem.swift`, which houses the paused-retention logic and chat loss label. The shared controller changes only state, ingest,
completion, and scheduling; its latest-content/control-presentation area stays untouched for #1254.

## P2: bounded paused audio retention

The default budget is **900 seconds (15 minutes)** of PCM plus a **67,108,864-byte (64 MiB)** hard cap,
whichever would be exceeded first. Duration uses each frame's bytes / (sample rate × channels × 2)
for PCM16. Equality fits. `PausedReplyAudioBudget` is injectable for deterministic pressure tests.
`retainAudioWhilePaused` enforces the limit before ordinary queued audio enters `streams`.
`retainedPausedAudio` counts every live stream, including all retained audio of the paused reply;
a replay with no live stream also counts. This conservatively counts already-scheduled frames until
the reply completes. Stream removal releases the budget automatically, including playback and stop.
Session updates retain their existing admission and retention policies.

The paused reply's own arriving audio is always kept, even if it alone exceeds either limit.
If a queued reply's next frame would exceed either limit,
the entire reply becomes text-only: its previously retained frames are released from the budget,
and that frame and all later audio are refused, including after resume. Its FIFO identity and text
remain, with the visible status **Audio not kept while paused**. A fixed OSLog notice says
`Queued reply audio not kept: paused retention budget exceeded`; it includes no content, identities,
endpoints, or audio. One notice is emitted per affected reply, rather than per rejected frame.

A refused reply completes as text-only at its FIFO turn after earlier audio finishes. No fragments
play, missing sequences are never skipped, and no completion markers are fabricated. Playback and
Replay eligibility are checked independently of retained storage. Text-only completion is processed
both before and after proactive admission reorders a deferred update behind an ordinary reply;
admission repeats for the new head before any idle watch or playback begins. The budget status
persists through completion, late frames, and Replay of the previous complete reply. Explicit stop
clears retained streams and queued text-only entries as before.

## Synthetic acceptance coverage

`ReplyPlaybackSupersedeTests` uses a fake player's retained cursor and asynchronous completion
notifications. New scenarios use no sleeps, polling, or semaphores; the idle scheduler is injected.

| Expectation | Test |
| --- | --- |
| Paused A resumes at its retained frame, then B; every frame plays exactly once | `aNewReplyWaitsForThePausedRemainder` (final received before pause and final arriving during pause) |
| A, B, C stay in arrival order, including B queued before pause | `threeRepliesKeepArrivalOrder` |
| Host stop and all-host stop discard paused A and queued B; late audio cannot restart either | `explicitStopDuringPauseDiscardsBothReplies` |
| Session update stays queued and still needs measured quiet | `sessionUpdateDuringPauseKeepsItsExistingAdmissionPolicy` |
| Pending voice mute waits for A to finish and mutes B before scheduling | `pendingVoiceMuteStillWaitsForThePausedReplyToFinish` |
| Capture ending preserves explicit pause and both replies | `listeningEndingKeepsTheExplicitPauseAndBothReplies` |
| Per-reply Paused, Queued, Playing, Played, Stopped statuses | Assertions throughout these scenarios |

Updated legacy assertions also cover pending first audio, muted pending replies, late audio after
silence claims/overflow, malformed-tail retirement, and per-stream receipt lifetime. Existing stop,
mute, headset, proactive, capture suppression, and shared-cancel suites supply regression coverage.

`PausedReplyBudgetTests` adds asynchronous player-notification coverage with no sleeps or polling:

| Expectation | Test |
| --- | --- |
| Defaults are 900 seconds and 64 MiB | `defaultBudgetIsFifteenMinutesAndSixtyFourMiB` |
| A and B fit exactly; C stays queued with text/status, resumes after A then B without audio; repeated/late C frames stay refused | `pressureKeepsAudioAndTextInFIFO` (duration and byte cap independently) |
| Duration is computed per PCM format, including a changed sample rate | `durationUsesEachFramesPCMFormat` |
| The paused reply's own growing audio is counted and always kept | `pausedReplyIsKeptEvenWhenItAloneExceedsBudget` |
| Overflow after frames 0 and 2 releases all B audio; no B fragments play, late B frames stay refused, C uses the released budget | `overflowDiscardsTheWholeReplyIncludingGappedFragments` |
| Paused A, deferred U, text-only B, normal C immediately complete B in order, play C, then admit U only after measured quiet | `PausedReplyLifecycleTests.deferredUpdateAdmitsTextOnlyThenNormalReplyWithoutAnIdleTimeout` |
| Text-only storage is ineligible for playback/Replay; previous complete A replays fully and B retains its budget status | `PausedReplyLifecycleTests.textOnlyNeverReplacesThePreviousCompleteReplay` |
| Budget releases as replies finish and after stop; a later pause admits fresh audio | `budgetIsReusableAfterPlaybackOrStop` |

## Verification

Before each build/test phase, wait for the shared host build slot, then the voice-quiet gate. Run phases
one at a time at background priority. Select the full Xcode developer directory. Gate implementation
and private host locations are deliberately omitted from this record. Scratch logs and generated
products stay outside version control.

Commands are listed below; completed results are recorded at the end.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2
```

The suite selection is:

```text
PausedReplyLifecycleTests|PausedReplyBudgetTests|ReplyPlaybackSupersedeTests|FirstAudioOverflowTests|FirstAudioRecoveryTests|ReplyPlaybackFirstAudioReviewTests|ReplyPlaybackFirstAudioTests|ReplyPlaybackMalformedPauseTests|ReplyPlaybackStreamDiagnosticsTests|ReplyPlaybackStopTests|ReplyPlaybackMuteTests|ProactiveReplyPlaybackTests|ReplyPlaybackCaptureSuppressionTests|ReplyPlaybackHeadsetTests|ReplyPlaybackSharedCancelTests|ReplyPlaybackControllerTests|ReplyPlaybackIdleHoldTests
```

Run the serial command once and the parallel command five times, reacquiring both gates for each run:

```sh
taskpolicy -b swift test --skip-build -j 2 --no-parallel --filter "$suites"
taskpolicy -b swift test --skip-build -j 2 --parallel --filter "$suites"
```

Original FIFO mutation check (before P2): temporarily restore both original production files
(the supersede call and discard helper), rebuild, and run `ReplyPlaybackSupersedeTests` against the mutant. Its failure must demonstrate
the retained-frame/FIFO rule detects the old discard. Restore the implementation and rebuild before
final passing runs. The mutation is never committed. Its focused command was:

```sh
taskpolicy -b swift test --skip-build --no-parallel --filter ReplyPlaybackSupersedeTests
```

Compile-only checks, each once after its own gates:

```sh
taskpolicy -b scripts/verify.sh sim
taskpolicy -b scripts/verify.sh mac
```

Strict lint covered these exact Swift files (the line breaks below only split the argument list):

```sh
swiftlint lint --strict --quiet \
  Sources/HailCore/Replies/ReplyPlaybackController.swift \
  Sources/HailCore/Replies/ReplyPlaybackController+PausedBudget.swift \
  Tests/HailCoreTests/PausedReplyBudgetTests.swift \
  Sources/HailCore/Replies/ReplyPlaybackController+Stop.swift \
  Sources/HailCore/Replies/ReplyPlaybackController+Proactive.swift \
  Tests/HailCoreTests/ReplyPlaybackSupersedeTests.swift \
  Tests/HailCoreTests/PausedReplyTestSupport.swift \
  Tests/HailCoreTests/FirstAudioRecoveryTests.swift \
  Tests/HailCoreTests/FirstAudioOverflowTests.swift \
  Tests/HailCoreTests/ReplyPlaybackMalformedPauseTests.swift \
  Tests/HailCoreTests/ReplyPlaybackStreamDiagnosticsTests.swift \
  Tests/HailCoreTests/ReplyPlaybackFirstAudioTests.swift \
  Tests/HailCoreTests/ReplyPlaybackFirstAudioReviewTests.swift
```

Run `scripts/check-host-paths.py origin/main..HEAD` on the final local commit.

No upload, installation, live configuration change, or physical playback check is in scope. The owner's
physical acceptance (pause A, ask again, unpause, hear both fully in order) and any later TestFlight
delivery remain deferred.

## Original FIFO results, before P2 (2026-11-20)

| Phase | Result |
| --- | --- |
| Initial `swift build --build-tests -j 2` | PASS, 1357.71 s; no warnings or errors |
| Filtered `--no-parallel` run | PASS, 88 tests in 15 suites |
| Original discard restored; rebuild | PASS, 82.62 s |
| Focused mutant `ReplyPlaybackSupersedeTests` run | Expected FAIL (exit 1): 6 tests, 34 issues; session-update case still passed |
| Fixed source restored byte for byte; rebuild | PASS, 86.62 s |
| Filtered `--parallel` run 1 | PASS, 88 tests in 15 suites |
| Filtered `--parallel` run 2 | PASS, 88 tests in 15 suites |
| Filtered `--parallel` run 3 | PASS, 88 tests in 15 suites |
| Filtered `--parallel` run 4 | PASS, 88 tests in 15 suites |
| Filtered `--parallel` run 5 | PASS, 88 tests in 15 suites |
| `scripts/verify.sh sim` | PASS, Test Build Succeeded; compile only, signing disabled |
| `scripts/verify.sh mac` | PASS, Build Succeeded; compile only, signing disabled |
| Strict SwiftLint, all ten changed Swift files | PASS |
| `scripts/check-host-paths.py origin/main..HEAD` | Run after the final commit; result accompanies the delivered SHA |

The mutant scheduled B during the pause, cancelled the retained buffer, and marked A `Skipped`;
these are actual assertion failures, not a build or selection failure. The session-update scenario
passed under both implementations. The restored source exactly matches the positive serial run.

## P2 verification (2026-11-20)

The fixed implementation first passed the complete selected suites serially once. For the P2
mutation, only the duration/byte comparison in `retainAudioWhilePaused` was bypassed; FIFO and
the tests stayed intact. After a successful mutant build, `PausedReplyBudgetTests` failed as
expected. The exact fixed source was restored, rebuilt, then passed the selected suites in parallel
five times. Each phase reacquired the host slot and voice-quiet gates, used
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, background priority, and two build jobs.
Logs and redirected SwiftPM cache/configuration/security state stay in task scratch. Package products
remain in ignored `.build`; app builds redirect DerivedData to task scratch and use `-jobs 2`.
Simulator and Mac are compile-only checks.

The P2 package commands also redirect SwiftPM cache, configuration, and security state into task
scratch, using these exact additional arguments (the local scratch path is omitted):

```sh
swift_storage=(--cache-path "$scratch/swift-cache" --config-path "$scratch/swift-config" \
  --security-path "$scratch/swift-security")
taskpolicy -b swift build --build-tests -j 2 "${swift_storage[@]}"
taskpolicy -b swift test --skip-build -j 2 "${swift_storage[@]}" --no-parallel --filter "$suites"
taskpolicy -b swift test --skip-build -j 2 "${swift_storage[@]}" --parallel --filter "$suites"
```

The mutation's focused test command uses the same storage arguments and
`--skip-build -j 2 --no-parallel --filter PausedReplyBudgetTests`. Its build and test each reacquire both gates.

| P2 phase | Result |
| --- | --- |
| Strict SwiftLint on all 13 changed Swift files | PASS |
| Initial `swift build --build-tests -j 2` | PASS, 331.74 s; no compiler warnings or errors |
| Filtered `--no-parallel` run | PASS, 94 tests in 16 suites, 0.648 s |
| Budget-bypass mutant build | PASS, 16.60 s |
| Unchanged `PausedReplyBudgetTests` against mutant | Expected FAIL, exit 1; 6 tests in 1 suite, 33 issues |

Both byte-cap and duration-cap pressure cases failed: the mutant retained 240,000 bytes / 5.0 s
where the injected bound was 120,000 bytes / 2.5 s, retained C's audio, and labelled C `Queued`
instead of `Audio not kept while paused`. The pressure test itself reported 18 issues. This was
an assertion failure after a successful build. The fixed file was restored byte for byte.

| P2 restored verification | Result |
| --- | --- |
| Exact fixed source restored; rebuild | PASS, 20.60 s |
| Filtered `--parallel` run 1 | PASS, 94 tests in 16 suites, 0.483 s |
| Filtered `--parallel` run 2 | PASS, 94 tests in 16 suites, 0.503 s |
| Filtered `--parallel` run 3 | PASS, 94 tests in 16 suites, 0.671 s |
| Filtered `--parallel` run 4 | PASS, 94 tests in 16 suites, 0.593 s |
| Filtered `--parallel` run 5 | PASS, 94 tests in 16 suites, 0.638 s |
| `scripts/verify.sh sim` (one run) | PASS, Test Build Succeeded; compile only, signing disabled |
| `scripts/verify.sh mac` (one run) | PASS, Build Succeeded; compile only, signing disabled |

Final cache-disabled strict SwiftLint (`--no-cache`) on all 13 changed Swift files: PASS.
Production count using the PR checker exclusions and rename handling: **4**.
The latest-content/control-presentation area is unchanged. Source hashes were checked
through the final amendment; the branch retains one commit on the required base.

`python3 scripts/check-host-paths.py origin/main..HEAD`: PASS on the final amended range.
The guard was rerun after this result line was added to the amendment.

## P2a/P2b/P2c review corrections (2026-11-20)

The earlier P2 results above describe the superseded retained-prefix behavior. The owner rule is
now all audio or text-only for each queued reply. These corrections release all of a reply's retained
frames at its first overflow, refuse its future frames, and independently exclude text-only streams
from scheduling and Replay. They also finish text-only heads exposed by proactive admission before
watching or scheduling the resulting head. The original budget defaults and paused-head exemption
remain unchanged.

`overflowDiscardsTheWholeReplyIncludingGappedFragments` replaces the defect-asserting prefix test.
It accepts B's frames 0 and 2, overflows on frame 1, verifies the released budget admits C, then
proves only A and C play and later B audio stays refused. The mixed-queue lifecycle test uses
paused A, deferred session update U, completely refused B, and normal C; asynchronous A completion
must immediately complete B and start C without firing any idle deadline. U still requires measured
quiet. The Replay lifecycle test overflows B after retaining its first frame, checks eligibility
against a retained snapshot, and proves the previous complete A replays fully while B's exact budget
status persists. Player completion uses asynchronous notifications; these scenarios contain no
sleeps, polling, or semaphores.

Three temporary mutations are built and tested separately against unchanged tests:

| Mutation | Required detection |
| --- | --- |
| Keep B's retained fragments and restore the old gap-skipping/fabricated-final scheduler | P2a's replacement test must fail actual playback, budget-release, and FIFO assertions |
| Remove post-admission text-only completion, keeping only the pre-admission check | P2b's mixed queue must fail immediate B completion/C playback without an idle deadline |
| Store B's retained overflow prefix in `lastAudio`/`lastKey` before releasing it | P2c's lifecycle must reject B replacing A's Replay and reject any B playback |

Each mutation restores the fixed sources before the next one; a final restoration and build precede
all five parallel runs. Build and test phases separately reacquire the shared host-slot and
voice-quiet gates, select Xcode explicitly, use `taskpolicy -b` and two jobs, and use the storage
redirects listed above. The selected suite pattern adds `PausedReplyLifecycleTests` to the earlier
16 suites. Simulator and Mac verification invoke `scripts/verify.sh sim` and `scripts/verify.sh mac`
once each, with the scratch wrapper supplying `-jobs 2` and scratch DerivedData. Strict SwiftLint
uses `--no-cache` and all 14 changed Swift files. No PR, push, installation, device test, or upload
is part of this revision.

The focused mutation commands were (each after its own successful gated mutant build):

```sh
taskpolicy -b swift build --build-tests -j 2 "${swift_storage[@]}"
taskpolicy -b swift test --skip-build -j 2 "${swift_storage[@]}" --no-parallel \
  --filter PausedReplyBudgetTests/overflowDiscardsTheWholeReplyIncludingGappedFragments
taskpolicy -b swift test --skip-build -j 2 "${swift_storage[@]}" --no-parallel \
  --filter PausedReplyLifecycleTests/deferredUpdateAdmitsTextOnlyThenNormalReplyWithoutAnIdleTimeout
taskpolicy -b swift test --skip-build -j 2 "${swift_storage[@]}" --no-parallel \
  --filter PausedReplyLifecycleTests/textOnlyNeverReplacesThePreviousCompleteReplay
```

The final strict lint command was:

```sh
taskpolicy -b swiftlint lint --strict --quiet --no-cache \
  Sources/HailCore/Replies/ReplyPlaybackController.swift \
  Sources/HailCore/Replies/ReplyPlaybackController+PausedBudget.swift \
  Sources/HailCore/Replies/ReplyPlaybackController+Proactive.swift \
  Sources/HailCore/Replies/ReplyPlaybackController+Stop.swift \
  Tests/HailCoreTests/FirstAudioOverflowTests.swift \
  Tests/HailCoreTests/FirstAudioRecoveryTests.swift \
  Tests/HailCoreTests/PausedReplyBudgetTests.swift \
  Tests/HailCoreTests/PausedReplyLifecycleTests.swift \
  Tests/HailCoreTests/PausedReplyTestSupport.swift \
  Tests/HailCoreTests/ReplyPlaybackFirstAudioReviewTests.swift \
  Tests/HailCoreTests/ReplyPlaybackFirstAudioTests.swift \
  Tests/HailCoreTests/ReplyPlaybackMalformedPauseTests.swift \
  Tests/HailCoreTests/ReplyPlaybackStreamDiagnosticsTests.swift \
  Tests/HailCoreTests/ReplyPlaybackSupersedeTests.swift
```

| Review correction phase | Result |
| --- | --- |
| Initial test build | PASS, 76.80s |
| Serial selected suites | PASS, 96 tests in 17 suites, 1.177 s |
| P2a mutant build | PASS, 23.82s |
| P2b mutant build | PASS, 26.61s |
| P2c mutant build | PASS, 21.90s |
| Restored fixed-source build | PASS, 20.04s |
| P2a focused mutant test | Expected FAIL (exit 1), 1 test, 8 assertion issues |
| P2b focused mutant test | Expected FAIL (exit 1), 1 test, 5 assertion issues |
| P2c focused mutant test | Expected FAIL (exit 1), 1 test, 4 assertion issues |
| Parallel selected suites, run 1 | PASS, 96 tests in 17 suites, 0.461 s |
| Parallel selected suites, run 2 | PASS, 96 tests in 17 suites, 0.527 s |
| Parallel selected suites, run 3 | PASS, 96 tests in 17 suites, 0.690 s |
| Parallel selected suites, run 4 | PASS, 96 tests in 17 suites, 0.613 s |
| Parallel selected suites, run 5 | PASS, 96 tests in 17 suites, 0.657 s |
| Simulator build-for-testing, one run | PASS; compile only, signing disabled |
| Mac build, one run | PASS; compile only, signing disabled |
| Strict SwiftLint, all 14 changed Swift files | PASS; `--no-cache` |

All three mutants failed actual assertions after successful builds. P2a reported partial B
playback and unreleased budget; P2b left B incomplete and C unscheduled; P2c replaced A
with B for Replay and lost the budget status. Fixed source restoration was checked byte
for byte. The final suite runs use the same fixed source as the serial pass.

A scratch-runner validation initially mistook XCTest's empty section for an empty Swift
Testing run after P2a. The actual selected Swift Testing test ran and failed with eight
issues; its output was verified, the validator corrected, and P2b/P2c continued without
repeating P2a. An early lint invocation without the selected Xcode developer directory
failed to load SourceKit before analysis; the final gated strict lint passed.

The PR checker's exclusions and rename handling count **4 production files**. The
controller presentation prefix and latest-content extension are unchanged from the
starting head. The branch retains one amended local commit on the requested base.

`python3 scripts/check-host-paths.py origin/main..HEAD`: PASS. Rerun after recording
this result in the final local amendment. The working tree is clean.

## Round d — Replay and the chat loss label

A non-segmented Replay of a completed reply has player buffers but no live stream. Replay takes
the FIFO head until its player completion arrives. While it owns that turn, subsequent replies can
store frames, but only the Replay can play. The idle watch follows the same FIFO. The budget
counts the Replay from its cached frames alongside queued streams. The next reply can replace
the cache only after the Replay completes. A Replay of a still-live stream already counts through
that stream.

The conversation bubble already reads `audioProblem(replyID:)` for its own entry. HailCore now
maps a paused-budget refusal to the exact label **Audio not kept while paused**. The existing
failure announcer still handles playback failures separately. Folding the paused-budget extension
into `ReplyAudioProblem.swift` keeps the branch at four production files.

| Regression in `PausedReplayQueueTests` | Observable result |
| --- | --- |
| `queuedPrefixNeverEntersPlayerBeforeReplayFinishes` | Replay A, pause, queue B's prefix, resume and pause again. B's continuation overflows. The player receives only A until Replay completes, then receives C immediately. |
| `activeReplayCountsUntilPlayerCompletion` | A, B and C are each 60,000 bytes. With a 120,000-byte cap, paused Replay A plus queued B fills the budget and C becomes text-only. Completion releases A's 60,000 bytes. |
| `refusedChatEntryShowsBudgetLossWhileNextReplyOwnsControls` | With C owning the controls, the chat entry for B still returns its exact refusal label and C has no loss label. |

These regressions wait for synthetic player completion notifications. The idle, duplicate-frame,
proactive and cancellation tests also exercise the FIFO ownership change. The idle clock is injected
and the fake player delivers the replacement Replay's completion explicitly.

Each command ran after the host-slot and voice-quiet gates, at background priority with the full
Xcode developer directory selected. SwiftPM used two jobs and the scratch storage arguments
shown above. Each mutation used one `swift test` invocation to build and run its named regression.
The runner restored each edit before the next mutation. The serial invocation rebuilt the fixed code.

```sh
suites='PausedReplyLifecycleTests|PausedReplyBudgetTests|ReplyPlaybackSupersedeTests|FirstAudioOverflowTests|FirstAudioRecoveryTests|ReplyPlaybackFirstAudioReviewTests|ReplyPlaybackFirstAudioTests|ReplyPlaybackMalformedPauseTests|ReplyPlaybackStreamDiagnosticsTests|ReplyPlaybackStopTests|ReplyPlaybackMuteTests|ProactiveReplyPlaybackTests|ReplyPlaybackCaptureSuppressionTests|ReplyPlaybackHeadsetTests|ReplyPlaybackSharedCancelTests|ReplyPlaybackControllerTests|ReplyPlaybackIdleHoldTests|PausedReplayQueueTests|ReplyPlaybackDuplicateTests|ProactiveAudibilityRestorationTests|ReplyAudioProblemTests|ReplyPlaybackFormatTests|ReplyPlaybackIdleTests|ReplySegmentPauseTests|ReplySegmentWiringScopeTests|ProactiveActivityEpochTests|AmbientDuplexPlaybackTests|AnnouncerTests'
# For each mutation set test_name to its regression in the table above.
taskpolicy -b swift test -j 2 "${swift_storage[@]}" --no-parallel --filter "PausedReplayQueueTests/$test_name"
taskpolicy -b swift test -j 2 "${swift_storage[@]}" --no-parallel --filter "$suites"
taskpolicy -b swift test -j 2 "${swift_storage[@]}" --skip-build --parallel --filter "$suites" # five gated runs
taskpolicy -b scripts/verify.sh sim
taskpolicy -b scripts/verify.sh mac
taskpolicy -b swiftlint lint --strict --quiet --no-cache "${changed_swift_files[@]}"
```

| Round d check | Result |
| --- | --- |
| Remove Replay's FIFO reservation | Expected failure, 5 assertion issues |
| Omit active Replay from retained audio | Expected failure, 4 assertion issues |
| Return nil for the budget loss label | Expected failure, 1 assertion issue |
| Fixed serial run | 158 tests across 29 suites passed in 5.292 s |
| Five fixed parallel runs | 158 tests across 29 suites passed each time (1.628, 1.181, 1.677, 1.416, 2.599 s) |
| Simulator and Mac | Both compile-only builds passed once with signing disabled |
| Strict SwiftLint | Passed on all 20 changed Swift files |
| Final Swift package and test compilation | Passed after the extension-boundary move |

The initial strict lint reported a 154-line class body against the 150-line limit. After the
suite runs and platform compiles, the declaration boundary for the existing controller extension
moved from before receipt pruning to before playback completion. The method bodies and statements
are identical across that move. The final layout passed strict lint and a gated
`taskpolicy -b swift build --build-tests -j 2` with the same scratch storage arguments.

## Round e — Recheck admission after retiring a Replay

While capture stays quiet, muting the Replay of a completed session update A can retire A when
B arrives. The controller records which head it is checking before admission can retire or reorder
that head. If the head changes, the next head goes through admission before any frame can enter
the player. A pending voice mute that becomes due at this boundary takes effect before admission.
When the owner unmutes, a queued session update gets a fresh admission check after the player
has been unmuted, even if all its frames have already arrived and capture stays quiet.

`PausedReplayQueueTests.nextReplyGetsItsOwnAdmissionAfterMutedReplay` exercises the same two-frame
B as an authorized session update and as an ordinary reply. The session update remains queued with
zero frames scheduled while muted. Unmute admits both frames in order, and the final player
callback records completion. The ordinary reply keeps its existing behavior: its frames enter
the muted player in FIFO order. `pendingVoiceMuteTakesEffectBeforeUpdateAdmission` checks a voice
mute that becomes due when its spoken confirmation finishes. Both regressions use injected quiet
measurements and explicit player callbacks.

The mutation records the head after admission, bypassing the check of the head exposed when A
retires. Its focused command uses the scratch storage arguments from round d:

```sh
taskpolicy -b swift test -j 2 "${swift_storage[@]}" --no-parallel \
  --filter PausedReplayQueueTests/nextReplyGetsItsOwnAdmissionAfterMutedReplay
```

The fixed runs use round d's suite filter, SwiftPM storage, and compile-only simulator and Mac
commands. Each phase waits for the host slot and then voice quiet, uses the full Xcode developer
directory, and runs at background priority. SwiftPM and Xcode use two jobs.

| Round e check | Result |
| --- | --- |
| Skip admission for the newly exposed head | Expected failure (exit 1), 8 assertion issues. The mutant handed B audio to the muted player. Fixed source restored byte for byte. |
| Strict SwiftLint on all 20 changed Swift files | Passed |
| Fixed serial run | 160 tests in 29 suites passed in 9.986 s |
| Five fixed parallel runs | All 160 tests in 29 suites passed each time (2.207, 5.011, 11.271, 1.529, 1.520 s) |
| Simulator and Mac | Both compile-only builds passed once, signing disabled |

The full branch diff contains 4 production files. This round changes production
code only in `ReplyPlaybackController+Proactive.swift`. The host-path guard runs on the amended
range with `python3 scripts/check-host-paths.py origin/main..HEAD`.
