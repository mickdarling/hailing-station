# Immediate silent session-update cards (#1249)

This local source candidate follows the owner's newest rule: display card content as it arrives, while
keeping voice playback full and ordered.

This supersedes Design A, its settle timer, silent privacy/meeting holds, and terminal-frame ordering.
Verification here is synthetic, including a loopback WebSocket; it is not installation, an app build,
a captured-output round trip, a physical-device check, or proof of seeing/hearing anything.

## Host rule and implementation

With speech status `not_configured`, an ordinary `info` update attempts delivery immediately on submit.
It can enqueue between any two reply frames. Only explicit `haild notify quiet on` holds silent info;
clearing quiet offers it immediately, including during a streaming reply. Privacy, meeting, media, requests,
finalized turns, owner speech and device playback do not hold it. Configured speech and action cards retain
main's behavior. Expiry, capacity, rate budget, exact recipient, capability, selection generation, target
policy and binding authority still apply. No settle setting or new quiet-off CLI/API is introduced.

`WebSocketPeer.swift` is restored byte-for-byte to main: no stream entries, reply-boundary parsing,
silent-card permit, active-stream transport-lock condition, terminal observer, or reply-end silent drain.
Its existing retirement lock and prepared ticket retain live-connection, atomic, one-time transport enqueue.
The listener retains cards until successful completion and coalesces concurrent drains into a follow-up.
A no-recipient card retries when a device begins listening or admitted input establishes its recipient.

The P2 fix retains a `SilentSessionUpdateRecipient` in the audience lease. After all asynchronous preparation,
`enqueueSilentUpdate` checks quiet and absence of a renderer, then validates the current audience while
holding the ambient router state lock and last-input ledger lock through the actual prepared enqueue.
The receiving `HostSession` actor turn also remains held. Its own input cannot run concurrently and invert
transport/ledger locking. Another device cannot change last-input attribution during this enqueue.
An audience mismatch sends nothing to the old peer, retains the original queue entry, and schedules a
fresh-audience offer. Budget and identity are not renewed. Spoken/action output uses its existing path.

Enabled drain logs contain only `session_update_drained trigger=... count=N`, including blocked/empty counts.
Triggers are `asked`, `interaction`, `natural_pause`, `immediate`, `hold_cleared`, `recipient_changed`.
Counts record completed transport sends. No content, target, peer identity, transcript or recording is logged.

## Read-only app findings

No `Sources/HailCore` or `Apps/` source is changed.

(a) A valid negotiated `session_update` between reply audio frames cannot alter reply sequencing, terminal
handling or playback. `HostConnection+Lifecycle.swift:103` processes each socket frame independently;
`HostConnection+Protocol.swift:44` decodes it, and `:60` dispatches session-update controls through
`publishSessionUpdate` (`:73`) and `publishNotice`, separately from `publishReply` (`:124`).
`HostConnectionStore.swift:345` consumes the update before segment wiring, reply history, or `onReplyFrame`;
`:361` records its separate speech receipt and conversation entry. It never reaches ordinary reply ingress.
`ReplyPlaybackController.swift:120` keys audio by reply, `:131` stores it by audio sequence, `:166` schedules
only contiguous frames, and `:187` handles the audio terminal; `ReplyPlaybackController+Segments.swift:84`
selects final playback completion. The card dispatch invokes none of these. Its speech-receipt policy
observation can recheck playback
(`ReplyPlaybackController+Proactive.swift:148`); that retires only marked proactive identities and preserves
ordinary reply FIFO (`:103`). The UI renders the conversation
in `Apps/Hail-iOS/StationLayout.swift:173` and `ConversationChatView.swift:53`, independently of audio controls.

Existing app limitation: `HostConnectionStore+ProactivePlayback.swift:15` still suppresses card presentation
while private/pending privacy or restoring transport (`:20`–`:22`). Thus host delivery in privacy does not
establish app display in privacy. That is a separate app-side follow-up to the general owner rule; it is not
a mid-stream sequencing/playback hazard and is outside this host commit.

(b) In the normal conversation thread, reply text displays on final text-frame receipt, including behind an
earlier reply's queued/playing audio. `HostConnectionStore.swift:348` calls `conversation.noteReply` before
playback ingress (`:350`). `ConversationLog.swift:239` accepts text, `:243` updates existing text, and `:274`
appends a new entry without checking playback. The app passes these entries to the chat
(`StationLayout.swift:173`) and renders every entry (`ConversationChatView.swift:53`).

There is an app-side exception: without a selected conversation thread, `StationLayout.swift:182` uses the
single-reply `ReplyPlaybackView`. Its `:8` chooses `playback.presentationForControls` over the supplied latest
reply, and `:44` renders that chosen transcript. `ReplyPlaybackController.swift:108` selects the active reply,
then the queued head, before latest. Therefore a newly received reply's text can remain hidden behind an earlier
active reply until that playback selection advances. A separate app issue is needed for this fallback panel
to obey the owner's general display-on-arrival rule. This host-only commit changes none of it. Existing
thread/address scopes still apply; these are read-only source findings, not physical UI timing proof.

## Synthetic traceability

| Requirement | Test |
| --- | --- |
| Submit immediately; content-free log | `SilentSessionUpdateTests.silentInfoDeliversOnSubmitAndLogsNoContent` |
| Actual wire card between audio sequence 0 and terminal sequence 1; unchanged reply frames; no duplicates | `SilentSessionUpdateWireTests.silentCardArrivesBetweenReplyAudioFramesWithoutChangingTheReply` |
| Quiet on holds / off delivers | `SilentSessionUpdateHoldTests.quietRetainsCardsAndClearDrainsImmediately` |
| Quiet enters at final peer hop; clears during reply and delivers before terminal | `quietAtFinalPeerHopRefusesSendAndClearDuringReplyDeliversImmediately` |
| Privacy/meeting/media deliver, including mid-reply | `roomModesDoNotHoldSilentInfo`, `roomModesDeliverInsideStreamingReply` |
| Mode changes during preparation/submission do not hold silent cards | `roomModeEntryAtFinalPeerHopDoesNotHoldSilentInfo`, `privacyEntryDuringSubmissionDoesNotDiscardSilentInfo` |
| No recipient -> connects/listens -> exactly once | `SilentSessionUpdateRecipientTests.cardHeldWithoutRecipientDeliversWhenDeviceConnectsAndStartsListening` (both connection cases) |
| P2: two live selected devices, preparation suspended, switch A -> B, never A, once B | `recipientSwitchDuringPreparationSendsOnlyToNewDeviceExactlyOnce` |
| Request/turn/device playback do not hold | `SilentSessionUpdateTests.inputAndDevicePlaybackDoNotHoldSilentCards` |
| Configured speech retains main's submit/drain/action and mode behavior | `configuredSpeechKeepsMainInfoAndActionBehavior`, `configuredSpeechKeepsMainModeBehavior`, `configuredSpeechPrivacyAtFinalEnqueueRefusesCard` |
| Renderer configured during preparation refuses silent handoff | `SilentSessionUpdateRaceTests.configuringSpeechAtThePeerHopRefusesTheSilentAttempt` |
| Action unchanged mid-reply | `SilentSessionUpdateTests.actionCardStillDeliversImmediatelyDuringReply` |
| Closed connection refuses prepared/pending frames | `connectionClosedWithPendingCardNeverDelivers` |
| Concurrent submission while draining goes exactly once | `SilentSessionUpdateRaceTests.submissionDuringAnOutstandingDrainIsDeliveredOnceAfterIt` |
| Other trigger names and empty counts remain content-free | `allExistingDrainTriggersLogEmptyCountsWithoutContent` |

Tests asserting cards wait for terminal frames have been removed/replaced. The ordinary-authority and
listener fixtures retain inert renderers so their tests still cover unchanged configured-speech behavior.
Only the recipient-transition fixture starts a temporary fake ambient child (`/bin/cat`); it captures nothing.

## Commands and executed results

Every build/test phase begins, in order, with:

```sh
"$HOME/.local/share/jarvis/voicework-2026-11-11/hostslot-wait.sh"
"$HOME/.local/share/jarvis/voicework-2026-11-11/voice-quiet.sh"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Full package build and serial family tests:

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build -j 2 --filter 'SessionUpdate|OrdinaryUpdate|TaskProgress|TerminalReplyTransport|PreparedWebSocketReply|WebSocket|AmbientMeeting|AmbientPrivacy|AmbientDuck|AmbientMedia'
```

Strict lint runs on every Swift file changed from main or the starting head (including the new wire test):

```sh
swiftlint lint --strict \
  Sources/HailDaemonKit/Listener/HostReplyDelivery.swift \
  Sources/HailDaemonKit/Listener/LocalSessionUpdate.swift \
  Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift \
  Sources/HailDaemonKit/Listener/WebSocketListener.swift \
  Sources/HailDaemonKit/Listener/WebSocketPeer.swift \
  Tests/HailDaemonKitTests/OrdinaryUpdateAuthorityTestRig.swift \
  Tests/HailDaemonKitTests/SessionUpdateDeliveryTests.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdateHoldTests.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdateRaceTests.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdateRecipientTests.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdateTestSupport.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdateTests.swift \
  Tests/HailDaemonKitTests/SilentSessionUpdateWireTests.swift
```

Mutation phases use the same preflights, followed by:

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build -j 2 --filter "$test_filter"
```

The full-package build passed (`Build complete! (234.93s)`). The serial family run passed **489 tests in
107 suites** in **241.158 s**, including the actual wire-order and two-device P2 tests. Strict lint passed
on all **13** Swift files listed above with zero violations. Initial attempts found new closure/fixture actor
annotation errors and a lint invocation missing the developer-directory environment; those were corrected.
No failure was classified as pre-existing and no main-baseline exemption was used.

All five requested mutations were killed; details follow below. Local logs are under
`/tmp/hs1249-arrival-rework`: `family-{build,test}.log`, `family-result.json`, `lint.log`,
`mutation-*-{build,test}.log`, `mutation-results.json`, and the original/restored SHA-256 manifests.
Build/test phases retain their own host-slot and voice-quiet preflight logs.

## Mutation results

Each deliberate regression compiled and failed the named test through real expectation failures, with no
compiler error, receive timeout, or unrelated failure counted as a kill. The values below are the exact
`test_filter` arguments to the mutation command above; elapsed times are command wall time.

| Mutation | Regression | `test_filter` | Build | Test |
| --- | --- | --- | --- | --- |
| `wait-behind-reply` | Restore reply stream tracking and silent-card waiting behind its terminal | `SilentSessionUpdateWireTests` | Pass, 154.529s | Killed (exit 1), 7.940s |
| `quiet` | Drop queue, listener and final-enqueue quiet checks | `SilentSessionUpdateHoldTests/quietRetainsCardsAndClearDrainsImmediately` | Pass, 160.654s | Killed (exit 1), 7.371s |
| `recipient-transition` | Drop ambient owner-change silent drain | `SilentSessionUpdateRecipientTests/cardHeldWithoutRecipientDeliversWhenDeviceConnectsAndStartsListening` | Pass, 46.791s | Killed (exit 1), 7.782s |
| `recipient-check` | Drop final synchronous audience comparison (P2) | `SilentSessionUpdateRecipientTests/recipientSwitchDuringPreparationSendsOnlyToNewDeviceExactlyOnce` | Pass, 43.408s | Killed (exit 1), 6.552s |
| `ignore-speech-configured` | Treat configured info as silent and ignore the final renderer check | `SilentSessionUpdateTests/configuredSpeechKeepsMainInfoAndActionBehavior` | Pass, 31.265s | Killed (exit 1), 6.062s |

The waiting mutant received a pong before the card, proving the card missed the middle of the reply. The
quiet mutant sent while quiet was on. Dropping the recipient-transition hook left the card held with no sends
in both connection cases. Dropping the P2 check sent once to A and zero times to B. Ignoring the renderer
configuration made configured info deliver immediately instead of retaining main's submit/drain behavior.

After every variant, mutated sources were restored to their exact saved bytes. The original, restored and
current SHA-256 manifests match for all three mutation-touched production files. Restored strict lint passed
on all 13 changed Swift files with zero violations. The restored full-package build passed in **32.87 s**;
the restored serial family run passed **489 tests in 107 suites** in **320.067 s**. `git diff --check` passed.
No unmutated test failure was classified as pre-existing; no baseline exemption was used.

## Scope

Exactly four production files differ from supplied main `3c6fb4ce62bf52921cd026918620e6357d4a204e`, using
`scripts/pr-shape.py` exclusions/rename handling: `HostReplyDelivery.swift`, `LocalSessionUpdate.swift`,
`WebSocketListener+SessionUpdate.swift`, `WebSocketListener.swift`, under `Sources/HailDaemonKit/Listener/`.
`WebSocketPeer.swift` matches main. `scripts/`, `.github/`, `Sources/HailCore/`, `Apps/`, and build identifiers
are untouched. This is one new local commit; no push, PR, live configuration, installation, or upload.
