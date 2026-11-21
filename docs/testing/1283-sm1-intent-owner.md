# SM1 · One writer of listening intent per controller

Part of #1283. This working-tree refactor starts at `38518b93a5bacd868211f5169c62b971a572d11a`. Host, simulator and physical-device results are pending.

## What moved

`AmbientListeningState.transition` computes the next intent state. The controller initializes in `off`. The existing write in `turnOn` publishes `on(intent)` immediately after assigning the session generation. The existing write in `end` publishes `stopped(reason)` after resetting the session and calling `captureResumed()`, immediately before clearing `isListening`. It uses the retiring generation passed to `end`. The public toggle reads whether the reducer has an intent.

The intent contains the owner generation, host ID, endpoint URL, target ID and selection serial. The store includes its endpoint URL when it issues a binding. Binding comparison and hashing continue to use the original host, target, socket generation and selection serial.

## Invariants

- Only an owner start can enter `on`. Ordinary transport, interruption, route, scene, mic retry, preference, capture invalidation and rebuild events preserve the complete state. A stop applies once to the matching active generation.
- Owner Off, reselect, remove, disconnect and a privacy tap each have a distinct stop reason. The command that retires a selection supplies its attribution for that generation. A scene callback observing a changed binding has no owner authority of its own.
- Policy denial, microphone permission denial, authoritative target or capability removal, unsafe endpoint change and moved-away each have a terminal reason. A ready host's live target with changed metadata can still fail the existing full-target comparison during recovery.
- The reconnect coordinator carries attribution beside its existing first veto. Capture, send admission, release, retry scheduling, privacy decisions, handoff, drain and notification order still follow the existing controller paths.
- Existing stop text and diagnostic fields retain their meanings. Owner Off and Audio Diagnostics Back during a pending start record `ambient_stop` with `reason=user`. Other legacy stops keep their existing tokens, including route reasons, `capture_ended`, `background`, `start_failed`, `binding_changed`, `send_failed` and `host_refused`. The typed reasons stay local to the controller.

## Legacy stop inventory

The slice column identifies follow-up scope in #1283. SM1 preserves every stop in the table.

| LegacyStopPath | Existing callers and cause | Slice |
| --- | --- | --- |
| `systemCaptureEnded` | Controller `observeSystemEnd` receives a system ending, `watch` observes an ended stream with no recorded send failure, or reconnect `resume` cannot restore the retained capture. | 5, 7 |
| `socketBindingLost` | `destinationLost`, `ownerChangedDestination` and `updateDestination` reconcile a changed binding. `recordSendFailure` receives an unrecovered socket or binding error. Store `upsert` and `selectionFailed`, controller `update`, and reconnect `receive` and `restore` also have binding-loss paths. These include a changed live target during reauthorization. | 3 |
| `privacySendFailed` | Store `setPrivacy` records a failed send. Restore privacy `begin` and `sendFailed` supply the same attribution to the existing confirmation completion. | 4 (#1305) |
| `privacyUnconfirmed` | Store `receiveModeNotice` and reconnect `drop`, `restore` and `prepareCaptureResume` encounter an unsettled request. Restore privacy `begin`, `receive` and `completeIfReady` report an unsuccessful confirmation. | 4 (#1305) |
| `leftForeground` | Both foreground checks in controller `start`, and the scene fallback in `updateDestination`, end a pending start. | 2 |
| `captureStartFailed` | Controller `start` catches a construction or startup error on the initial capture. | 5, 7 |
| `sendCancelled` | `recordSendFailure` records a cancelled operation or URL request. `watch` ends the stream. | 3 |
| `encodingFailed` | `recordSendFailure` receives an encoding or ambient audio error. `watch` ends the stream. | 3, 7 |
| `sendFailed` | `recordSendFailure` receives another local send error, which `watch` reports on stream end. | 3 |
| `hostRefused` | An ordinary host refusal reaches `watch` through `recordSendFailure`, or reaches `end` through `receiveAmbientRefusal`. | 3 |
| `retriesExhausted` | Controller `recover` reaches the existing transient-refusal retry cap. `watch` reports the recorded failure. | 3 |
| `replacementFailed` | Reconnect `receive` sees a failed replacement or `selectionFailed` receives a non-transport selection failure outside the recognized authorization and capability cases. | 3 |
| `diagnosticsDismissed` | Back from Audio Diagnostics cancels a pending start through `turnOff` and retains the historical `user` diagnostic token. | 2 |

## Verification pending

The reducer tests cover destination identity, all automatic events, one stop per generation and obsolete stops after restart. The source inventory counts production stop constructions, callback references and aliases, retaining duplicate sites within a function. Controller tests add exact typed outcomes to the existing text, diagnostics, capture and recovery assertions. The controller invariant test follows one original intent through a mask preference change, an interruption and microphone recovery, then an armed socket loss and restoration.

Strict SwiftLint passed for the Swift files changed from the SM1 base. Host builds, synthetic tests, simulator checks and physical-device checks are pending. Slice 4 owns the privacy work in #1305. SM2 owns scene-specific activation and capture lifetime on Audio Diagnostics Back. The same-window reselect during a pending start remains separate follow-up work.

## SM2 · Device scope and scene lifecycle

Device-wide intent and UI event wiring move together to SM2. Proposed multi-window requirements from round 1 include the following.

- Keepalive in one window must respect capture owned by another window.
- Back from Audio Diagnostics must cancel only the pending start associated with that window. A pending start or live capture in another window must survive.
- Each scene must release the activation it acquired, including when teardown overlaps a start in another scene.
- After the capturing window closes, evaluate foreground eligibility from the surviving scenes before opening a new capture.
- VoiceOver in every window must name the actual listening destination, including when the local card displays another host.
- Retain the originating store through an authorized final-tail drain after its window closes. Deliver the tail only on its original binding and release the store when the drain ends.

The two-window toggle, single-microphone and cross-window Off checks belong to SM2.

Attribution left for SM2: when the root clears its selection while both the old and the new destination are valid, it calls `destinationLost()` without the binding it just compared, so the store can attribute that stop to an owner reselect. SM2 passes the reconciled binding at that call so the stop is attributed exactly. Control flow is unaffected.
