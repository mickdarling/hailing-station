# Immediate silent session-update cards (#1249)

This local source candidate supersedes Design A, its settle timer, and the earlier silent privacy/meeting holds
under the owner's final instruction.
It is synthetic verification, not an installed build, captured-output round trip, or physical-device proof.
There is no settle setting or environment variable; `scripts/host.sh` and its tests match `origin/main`.

## Rule and ordering boundary

While speech status is `not_configured`, an ordinary info update attempts delivery immediately in every mode.
Only explicit `haild notify quiet on` holds it; clearing quiet offers it immediately. Privacy, meeting and media
do not hold silent info: privacy protects the room's audio, and meeting participants do not see the owner's
visual cards. Expiry, capacity, rate budget, exact recipient, capability, selection generation, target policy,
and binding authority still apply. Requests, finalized turns, owner speech, and device playback are irrelevant
to silent-card admission. Configured speech and action-card
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

The explicit quiet gate covers the synchronous final handoff after asynchronous registry/policy preparation.
Silent info has no privacy/meeting gate or privacy-epoch restriction; spoken/action guards remain unchanged.
Router audience changes retry silent cards held without a recipient, including a real admitted ambient start
with reply diagnostics disabled. Admitted input already retries through the interaction event; peer teardown
also retries against the newly selected audience. A connection alone does not invent a last-input recipient.
Silent delivery cannot start speech,
even if a renderer is configured after enqueue; configuration observed at final admission refuses that silent attempt.

Every enabled drain attempt emits only `session_update_drained` with
`trigger=<asked|interaction|natural_pause|immediate|reply_end|hold_cleared|recipient_changed> count=N`, including zero when blocked
or empty. Counts mean successful transport completion, never viewing or hearing proof.

## Synthetic traceability

| Requirement | Tests |
| --- | --- |
| Immediate submit, no content in drain log | `SilentSessionUpdateTests.silentInfoDeliversOnSubmitAndLogsNoContent` |
| Streaming text/audio through terminal, exactly one card | `streamingReplyOwnsEveryFrameThroughTerminalThenCardDeliversExactlyOnce` |
| A second reply wins at card admission | `secondReplyStartingAtCardPeerHopWinsAndCardWaitsForItsTerminal` |
| Only quiet retains; clearing drains | `SilentSessionUpdateHoldTests.quietRetainsCardsAndClearDrainsImmediately` |
| Quiet turns on during async preparation, clears during reply | `quietAtFinalPeerHopRefusesSendAndClearDuringReplyWaitsForTerminal` |
| Privacy/meeting/media deliver immediately | `roomModesDoNotHoldSilentInfo` (each mode) |
| Privacy/meeting/media wait only through a streaming reply's terminal | `roomModesWaitOnlyForStreamingReplyTerminal` (each mode) |
| Mode entry during async preparation does not hold silent info | `roomModeEntryAtFinalPeerHopDoesNotHoldSilentInfo` (each mode); `privacyEntryDuringSubmissionDoesNotDiscardSilentInfo` |
| Configured speech keeps main's privacy discard, quiet hold and held-on-submit meeting behavior | `configuredSpeechKeepsMainModeBehavior`; `configuredSpeechPrivacyAtFinalEnqueueRefusesCard` |
| Held without a recipient, device connects/starts listening | `SilentSessionUpdateRecipientTests.cardHeldWithoutRecipientDeliversWhenDeviceConnectsAndStartsListening` (with/without an initially connected peer; no last-input recipient) |
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
The silent fixtures use no renderer except tests explicitly verifying the configured path. All transports are
never-started synthetic peers; mode tests use the real router's meeting/media state. The recipient test starts
only a temporary fake ambient child (`/bin/cat`), with no microphone, recording, real provider or device.

## Executed verification for the final owner rule

The full worktree `swift build --build-tests -j 2` passed in **595.66 s**. Strict lint passed on all
**11 Swift files changed versus `origin/main`**, with zero violations. No installation, simulator build,
captured-output round trip or physical-device proof is claimed.

Every build/test phase starts with these preflights, in order:

```sh
"$HOME/.local/share/jarvis/voicework-2026-11-11/hostslot-wait.sh"
"$HOME/.local/share/jarvis/voicework-2026-11-11/voice-quiet.sh"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The worktree build and serial family-test commands are:

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build -j 2 --filter 'SessionUpdate|OrdinaryUpdate|TaskProgress|TerminalReplyTransport|PreparedWebSocketReply|WebSocket|AmbientMeeting|AmbientPrivacy|AmbientDuck|AmbientMedia'
```

The exact lint command is:

```sh
swiftlint lint --strict \
  Sources/HailDaemonKit/Listener/LocalSessionUpdate.swift \
  Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift \
  Sources/HailDaemonKit/Listener/WebSocketListener.swift \
  Sources/HailDaemonKit/Listener/WebSocketPeer.swift \
  Tests/HailDaemonKitTests/OrdinaryUpdateAuthorityTestRig.swift \
  Tests/HailDaemonKitTests/SessionUpdateDeliveryTests.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdate*.swift
```

Mutation runs use the same preflights and developer directory, followed by:

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build -j 2 --filter "$test_filter"
```

The unmutated serial family run passed **490 tests in 106 suites** in **246.368 s**, including both
no-recipient scenarios and every silent/spoken mode case. No build or unmutated test failure was classified
as pre-existing; no origin/main failure exemption was used.

## Mutation results

Each deliberate regression compiled successfully and failed the required named test. The privacy and meeting
variants each failed only their matching mode case in `roomModesDoNotHoldSilentInfo`; the quiet variant failed
`quietRetainsCardsAndClearDrainsImmediately`; the spoken variant failed
`configuredSpeechPrivacyAtFinalEnqueueRefusesCard`. Dropping the recipient hook failed both cases of
`cardHeldWithoutRecipientDeliversWhenDeviceConnectsAndStartsListening`: the active recipient existed, but the
card remained held with zero sends. No compiler failure, timeout or unrelated test was counted as a kill.

The `test_filter` values below are the exact arguments to the mutation command above.

| Variant | Deliberate regression | `test_filter` | Build | Result |
| --- | --- | --- | --- | --- |
| `privacy` | Re-add a silent privacy hold | `SilentSessionUpdateHoldTests/roomModesDoNotHoldSilentInfo` | Pass, 97.91s | Killed, test exit 1 |
| `meeting` | Re-add a silent meeting hold | `SilentSessionUpdateHoldTests/roomModesDoNotHoldSilentInfo` | Pass, 30.58s | Killed, test exit 1 |
| `quiet` | Ignore silent queue, listener and final-enqueue quiet checks | `SilentSessionUpdateHoldTests/quietRetainsCardsAndClearDrainsImmediately` | Pass, 37.93s | Killed, test exit 1 |
| `spoken-privacy` | Remove the spoken final-enqueue global privacy fence | `SilentSessionUpdateHoldTests/configuredSpeechPrivacyAtFinalEnqueueRefusesCard` | Pass, 32.27s | Killed, test exit 1 |
| `recipient-hook` | Remove the ambient owner-change silent drain hook | `SilentSessionUpdateRecipientTests` | Pass, 40.47s | Killed, test exit 1 |

Mutations ran one at a time in this worktree against the full package, with no reduced manifest or alternate
harness. After each run, the changed source was restored to its exact original bytes. Both mutated production
files also match their saved SHA-256 snapshots after all five runs. The final restored full-package build
passed in **41.31 s**, followed by the same serial family command: **490 tests in 106 suites passed** in
**240.673 s**. Restored strict lint again passed on all 11 changed Swift files with zero violations.
`git diff --check` passed. No unmutated build/test failure was classified as pre-existing.

## Scope and local evidence

The final production-file count versus the supplied `origin/main`
(`3c6fb4ce62bf52921cd026918620e6357d4a204e`) is **four**, using `scripts/pr-shape.py` exclusions and rename handling:
`LocalSessionUpdate.swift`, `WebSocketListener+SessionUpdate.swift`, `WebSocketListener.swift`, and
`WebSocketPeer.swift`, all under `Sources/HailDaemonKit/Listener/`. This delta changes the first three; the
transport ordering mechanism in `WebSocketPeer.swift` is retained from the previous rework.
`scripts/` and `.github/` are untouched versus both the previous commit and main. `HostSession.swift` also
matches main. No push, PR, live configuration, installation or upload is included.

Local logs are under `/tmp/hs1249-final-delta`: `build.log`, `test.log`, `lint-all-changed.log`,
`mutation-{privacy,meeting,quiet,spoken-privacy,recipient-hook}-{build,test}.log`, `mutation-results.json`,
`restored-sha256.json`, `mutation-runner.log`, `restored-lint.log`, and `restored-{build,test}.log`. The local mutation driver and all
build products remain outside version control.
