# Immediate silent session-update cards (#1249)

This local source candidate supersedes Design A and its settle timer under the owner's revised instruction.
It is synthetic verification, not an installed build, captured-output round trip, or physical-device proof.
There is no settle setting or environment variable; `scripts/host.sh` and its tests match `origin/main`.

## Rule and ordering boundary

While speech status is `not_configured`, an ordinary info update attempts delivery on submit. Explicit notify
quiet, privacy, and meeting hold it; clearing a hold offers it immediately. Silent info is retained through
privacy, unlike main's spoken/action discard policy. Expiry, capacity, rate budget, exact recipient, capability,
selection generation, target policy, and binding authority still apply. Media, requests, finalized turns,
owner speech, and device playback are irrelevant to silent-card admission. Configured speech and action-card
behavior remain as on main. The session-facing quiet-on API is unchanged; the owner-side flag-clear is tested
directly, without introducing a new CLI or session quiet-off command.

`ReplyTransportLifecycle` in `WebSocketPeer.swift` serializes the final Network enqueue with transport retirement
and stream bookkeeping. A text frame declaring audio opens its reply; a text-only terminal or final audio
frame ends it. Silent info uses a distinct transport permit that can enqueue only with no active stream on
that connection. Terminal notifications run outside the transport lock. The listener retains queued cards
until successful exact-peer completion and coalesces events received during an active drain into one follow-up.

If a second reply enqueues its first frame before the card wins final admission, the card stays held through
that reply's terminal as well. It may go before the next reply's first frame or after its terminal, never inside.
The transport lock makes checking for an active stream and enqueuing the card atomic. Device playback-end and
elapsed time play no role. A closed connection retires permits, so pending/prepared cards cannot enqueue there.

Quiet, global reply privacy, and router privacy/meeting gates cover the synchronous final handoff after all
asynchronous registry/policy preparation. An already-prepared attempt cannot cross a privacy on/off epoch;
a retained silent card can receive a fresh audience lease on a later drain. Automatic router notifications
observe completed mode transitions before evaluating the reply hold. Silent delivery cannot start speech,
even if a renderer is configured after enqueue; configuration observed at final admission refuses that silent attempt.

Every enabled drain attempt emits only `session_update_drained` with
`trigger=<asked|interaction|natural_pause|immediate|reply_end|hold_cleared> count=N`, including zero when blocked
or empty. Counts mean successful transport completion, never viewing or hearing proof.

## Synthetic traceability

| Requirement | Tests |
| --- | --- |
| Immediate submit, no content in drain log | `SilentSessionUpdateTests.silentInfoDeliversOnSubmitAndLogsNoContent` |
| Streaming text/audio through terminal, exactly one card | `streamingReplyOwnsEveryFrameThroughTerminalThenCardDeliversExactlyOnce` |
| A second reply wins at card admission | `secondReplyStartingAtCardPeerHopWinsAndCardWaitsForItsTerminal` |
| Quiet/privacy/meeting retain, clearing drains | `SilentSessionUpdateHoldTests.holdsRetainCardsAndClearDrainsImmediately` (each hold) |
| Holds turn on during async preparation, clear during reply | `holdAtFinalPeerHopRefusesSendAndClearDuringReplyWaitsForTerminal` (each hold) |
| Media does not hold | `mediaModeDoesNotHoldSilentInfo` |
| Request/finalized turn/device playback do not hold | `inputAndDevicePlaybackDoNotHoldSilentCards` (each activity) |
| Configured speech keeps main's info/action behavior | `configuredSpeechKeepsMainInfoAndActionBehavior`; existing session-update speech/stop families |
| Action remains immediate even mid-reply | `actionCardStillDeliversImmediatelyDuringReply` |
| Pending card and prepared terminal after connection closes | `connectionClosedWithPendingCardNeverDelivers` |
| A second submission during a suspended drain | `SilentSessionUpdateRaceTests.submissionDuringAnOutstandingDrainIsDeliveredOnceAfterIt` |
| Terminal event while a drain is active | `terminalEventDuringAnOutstandingDrainIsNotLost` |
| Renderer configured during preparation | `configuringSpeechAtThePeerHopRefusesTheSilentAttempt` |
| Existing trigger names, empty drain counts | `allExistingDrainTriggersLogEmptyCountsWithoutContent` |

The existing ordinary-authority and general listener fixture explicitly configure an inert renderer so their
held-info, epoch-discard and manual-drain assertions continue to exercise unchanged spoken-mode behavior.
The new silent fixtures use no renderer. All transports are never-started synthetic peers; mode tests use the
real router's meeting/media gates. No recordings, private transcripts, provider processes or device are used.

## Executed verification

The full worktree build passed (`Build complete!`, 727.52 s). The serial family run passed **484 tests in
105 suites** (240.198 s), including the three new silent-card suites. No test failure was classified pre-existing.
Strict lint passed on all **11 Swift files touched by this rework**, including `HostSession.swift` restored to main.
`git diff --check` passed. The corrected scratch baseline also passed **14 tests in 3 suites** (1.246 s).
All **five mutations were killed by their required named test**, with successful builds.
After restoring every source mutation, the serial scratch run passed **14 tests in 3 suites**
(1.200 s). Every scratch production Swift file matches the worktree byte for byte.

Before every build/test phase:

```sh
"$HOME/.local/share/jarvis/voicework-2026-11-11/hostslot-wait.sh"
"$HOME/.local/share/jarvis/voicework-2026-11-11/voice-quiet.sh"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter 'SessionUpdate|OrdinaryUpdate|TaskProgress|TerminalReplyTransport|PreparedWebSocketReply|WebSocket|AmbientMeeting|AmbientPrivacy|AmbientDuck|AmbientMedia'
```

Mutations run in a separate scratch candidate, with the same slot/quiet protocol and serial synthetic tests.
Its scratch-only package manifest builds the complete unchanged production daemon and protocol modules, plus
copies of the exact new test files and verbatim supporting declarations from the full target. Unrelated test
and executable targets are omitted from scratch compilation; the worktree's full package supplies the broader
verification. No scratch manifest, harness, build output or mutation is committed.
The requested mutations are: bypass stream exclusion, bypass quiet, bypass privacy, hold silent info in media,
and treat a configured renderer as silent. Every source mutation is restored after its run; compiler failures
are not accepted as killed mutations. No failing test is classified pre-existing without an origin/main A/B.

The exact strict-lint command, with the full Xcode developer directory exported as above:

```sh
swiftlint lint --strict \
  Sources/HailDaemonKit/Listener/HostSession.swift \
  Sources/HailDaemonKit/Listener/LocalSessionUpdate.swift \
  Sources/HailDaemonKit/Listener/WebSocketListener.swift \
  Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift \
  Sources/HailDaemonKit/Listener/WebSocketPeer.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdate*.swift \
  Tests/HailDaemonKitTests/SessionUpdateDeliveryTests.swift \
  Tests/HailDaemonKitTests/OrdinaryUpdateAuthorityTestRig.swift
```

The first reduced-harness compile omitted the shared `InMemoryPolicyStore` declaration. The harness was
corrected with a verbatim copy before baseline/mutation execution. This setup failure is not a production
regression or a killed mutation; the full worktree family run had already passed.

## Mutation results

Each variant used the same host-slot/quiet preflight and `DEVELOPER_DIR` above, followed by these exact commands
in the isolated scratch candidate. The same commands passed before mutation and again after complete restoration.

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter 'SilentSessionUpdate'
```

| Variant | Deliberate regression | Build | Required failing test | Result |
| --- | --- | --- | --- | --- |
| `midstream` | Allow a silent card while the transport has an active reply stream | Pass, 35.75 s | `streamingReplyOwnsEveryFrameThroughTerminalThenCardDeliversExactlyOnce` | Killed; test exit 1 |
| `quiet` | Ignore queue and final-enqueue quiet gates | Pass, 18.02 s | `holdsRetainCardsAndClearDrainsImmediately (quiet case)` | Killed; test exit 1 |
| `privacy` | Ignore listener, router and final reply-privacy gates | Pass, 24.32 s | `holdsRetainCardsAndClearDrainsImmediately (privacy case)` | Killed; test exit 1 |
| `media` | Hold silent info when media is on | Pass, 21.48 s | `mediaModeDoesNotHoldSilentInfo` | Killed; test exit 1 |
| `speech` | Treat a configured renderer as silent; bypass its final admission check | Pass, 16.93 s | `configuredSpeechKeepsMainInfoAndActionBehavior` | Killed; test exit 1 |

The stream, quiet and privacy variants also failed additional assertions in the related race tests. No mutation
was counted from compiler failure, timeout alone or an unrelated test. All intentional edits were confined to
the scratch candidate; the worktree source remained fixed throughout these checks.

Local evidence files are `rework-final-build.log`, `rework-final-test.log`, `rework-all-touched-lint.log`,
`rework-scratch-baseline-fixed-{build,test}.log`, `rework-mutation-{midstream,quiet,privacy,media,speech}-{build,test}.log`,
`rework-mutation-results.json`, and `rework-restored-{build,test}.log` in the requested scratch directory.

The final source count against the supplied `origin/main` (`3c6fb4ce62bf52921cd026918620e6357d4a204e`) is **four**,
using `scripts/pr-shape.py` exclusions:
`LocalSessionUpdate.swift`, `WebSocketListener+SessionUpdate.swift`, `WebSocketListener.swift`, and `WebSocketPeer.swift`,
all under `Sources/HailDaemonKit/Listener/`. `HostSession.swift`, `scripts/host.sh`, `scripts/tests/test-host.sh`,
and the setting inventory match main. The obsolete settle tests and record were removed; this record replaces them.
