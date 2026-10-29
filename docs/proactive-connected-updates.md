# Connected proactive update candidate (#609)

This candidate implements connected update cards under the existing experimental personal-terminal trust
boundary. It is source work, not an enabled host capability, an installed app, or physical hearing proof.
The approved-device-key and APNs ladder in `proactive-notifications.md` remains deferred; a connected peer is
not represented as a cryptographically approved owner device.

With the existing explicit `--personal-terminal --session-updates` opt-in, a local `haild notify` can reach
the exact active ambient connection or the target's last input connection. The selected target or still-current
last-input generation must cover that target, the peer must advertise `session_update`, and the target must be
alive in the host registry and have a current publication policy permit. The frame carries the registry's
display label and exact target ID separately. There is no reply-request creation, reuse, renewal, recovery,
destination fallback, or broadcast.

An action offers its card immediately. Routine information waits for a real successful input interaction or an
admitted playback-end diagnostic that did not finish a question. The queue retains the original update until
the exact transport completes; unsupported, closed, quiet, media and unavailable recipients leave it held.
Transport failure can be ambiguous: the same update UUID is retained so the device can deduplicate a retry.
No timer polls a model or an inbox. A concurrent offer coalesces while delivery is outstanding.

Privacy prevents new updates and discards held updates. A monotonic privacy-entry revision catches an on/off
pair between listener actor turns, and every actual enqueue repeats the global private-reply hold plus the
router's live and parked privacy checks under their locks. Quiet and listener retirement have a synchronous
final fence. Media mode prevents delivery. Cooperative providers retain an exact binding lease through enqueue;
legacy tmux uses the existing request-less path's fresh listing snapshot plus policy and selection checks, not
a fictitious cooperative lease. An external tmux change can still race a snapshot.

The card slice is independent of spoken admission. A follow-on host slice configures the existing owned house
renderer explicitly and emits PCM only to a peer advertising the distinct `session_update_audio` capability.
Every frame carries the accepted update UUID in its reply descriptor's `update` marker, background priority and
enqueue intent. The device must require the matching accepted card and current generation, then apply its local
capture-activity and playback admission. Finalized transcripts or old silence timestamps cannot authorize speech.
Rendering is asynchronous, bounded to one job, 60 seconds of PCM and a 90-second job cancellation deadline;
quiet/stop cancels the owned child, and listener shutdown joins retirement. A busy renderer still delivers cards.
An enqueued frame or completed card is not evidence that the device admitted playback or that anyone heard it.

Quiet and every global privacy entry retract known proactive audio by its exact update identity, including audio
already buffered on the device after rendering finished. Retraction preserves conversation cards and ordinary
replies. The host retains at most 128 content-free retraction identities; at capacity it reports `receipt_capacity`
and declines additional speech rather than forget potentially queued audio. Quiet/privacy retractions clear those
identities. A delayed privacy entry retracts only output admitted before its epoch, preserving newer public work.

Synthetic coverage is in `SessionUpdateDeliveryTests`, the acknowledge/privacy-budget test in
`SessionUpdateQueueTests`, and neighboring local-socket and private-hold suites. Build and test results are
recorded with the candidate PR; simulator and physical-device proof remain separate. No host/device
configuration, service installation, restart, signing/APNs setup, build installation or deployment is performed.
