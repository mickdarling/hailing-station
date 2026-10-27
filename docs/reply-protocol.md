# Reply identity and arbitration metadata

Status: accepted for protocol v1, issue #14.

Hailing Station associates reply text and audio by explicit identity, never by arrival order. Every new host
reply carries a `reply` descriptor in each text and audio payload:

- `id` is the durable reply identity.
- `host` and `target` are provenance and must equal the frame envelope's `source` and `target`.
- `audioStream` identifies the reply's audio stream. It is absent for text-only replies.
- `priority` is `background`, `normal`, or `urgent`.
- `interruption` is sender intent: `enqueue`, `duck`, or `interrupt`. The mobile terminal remains the final
  arbiter across connected hosts.

Audio payloads repeat the stream as `streamId`, retain their zero-based `sequence`, and carry `final` on the
last segment. A reply-associated audio frame is invalid unless its `streamId` matches the descriptor's
`audioStream`. This makes gaps, completion, and cross-reply contamination detectable before playback.

This is a compatible v1 extension. The existing payload shapes remain valid: new decoders accept legacy text
and audio without a descriptor, and older decoders ignore the new keys. A terminal may display or play a
legacy payload, but it must not associate separate legacy text and audio frames based on timing or adjacency.
New host reply producers must supply the descriptor. Unknown enum values fail closed until a later protocol
version defines their semantics.

Frame `id` remains the identity of one transmitted frame; it is deliberately not reused as reply or stream
identity. Multiple segments from one reply therefore keep unique frame IDs while sharing reply and stream IDs.

## Spoken words and metadata (#606)

A reply's text payload has two layers. `text` is the exact words spoken aloud, the same words TTS renders. The
optional `metadata` is Markdown shown beside them and never spoken: links, PR and issue references, file paths,
tables and status. It is a compatible v1 extension: older decoders ignore the key, and a reply without it is
unchanged on the wire.

- `metadata` is a non-empty string of at most 16 KiB of UTF-8 (`PayloadLimits.maxMetadataBytes`). Absent means no
  metadata; `"metadata": null` is invalid, as is an empty string.
- It is only valid beside a `reply` descriptor. The decoder and the schema refuse it on any other text payload.
- The whole frame must still fit the frame cap (`PayloadLimits.defaultMaxFrameBytes`). JSON escaping can grow
  text and metadata within their byte caps past it: a control character is six bytes on the wire.
- It is untrusted content. A client renders it through its safe Markdown model (no raw HTML, no remote images,
  links shown with their real destination), keeps a raw-text fallback, and never passes it to speech.
- `haild reply` sends it with `--metadata <markdown>` or `--metadata-file <path>`, on the text frame of a reply
  sent with `--text` or `--say`. The file must be a regular UTF-8 file: a symlink, pipe, device or directory is
  refused, and there is no `-` for standard input. Without `--text` or `--say`, over the cap, or when the encoded
  text frame would exceed the frame cap, the reply is refused before anything is sent. A daemon that predates
  this field decodes the frame without it and delivers the reply with the metadata dropped.

## Which device a reply reaches (#370)

Tap-to-talk and ambient listening are two ways into one pipeline. haild keeps, for each target, its **last input
device**: the connection that most recently sent that target admitted input, either an ambient request it dispatched
for the streaming device or the device's own final text frame, once the target actually received it. A reply is
routed in this order:

1. **Request reference.** A reply naming a `request` goes only to the connection that owns that host-side record
   (#161, #230). It never falls back, whatever else applies.
2. **Last input device.** A reply with no `request` goes to the target's last input device, text and audio, even
   when several devices select the target.
3. **Single selector.** Otherwise (no last input device, or it disconnected, selected away or reselected, or its
   record is older than 10 minutes), the single-terminal rule applies: the one device selecting the target, else
   `noRecipient`.
4. **Ambient owner (#230).** When two or more devices select the target, the one whose ambient stream feeds the
   active RightyO child (the device the user is listening on) receives it, if it is among those selecting devices.
   Otherwise `notUniqueRecipient`. The owner is only ever chosen from the already-admitted selectors, never added.
   Validated with synthetic loopback sockets (`AmbientWiringOwnerReplyRoutingTests`); not yet proven by device hearing.

Steps 2 to 4 run only on a host started with `--single-terminal-reply-fallback`, which `scripts/host.sh` passes
when `host.json` sets `singleTerminalReplyFallback`. Every frame of one request-less reply goes to the device that
received its first frame, or is refused; a reply never splits across devices.

Sessions need no reply instruction for this. Typed text gets no footer and no reference; ambient prompts keep their
existing [reply block](rightyo-input.md#the-reply-block). The wire format is unchanged. Details and limits:
[request-origin-routing.md](request-origin-routing.md#unified-reply-routing-the-last-input-device-370).

## Stopping reply playback (#309)

`{"command": "stop_playback"}` is a host-to-device control command that tells the device to stop reply audio
at once and drop that host's queued replies. The device's player is shared, so whatever it was playing stops too,
and another host's queued replies then play. It carries nothing else: the decoder and the schema refuse any other
payload key, and it grants no authority. A device advertises `stop_playback` (`PlaybackStop.capability`) in its
`hello` when it can act on the command. A host never sends it to a device that did not advertise it, because an
older device refuses an unknown command as malformed. The host sends it when a RightyO `dismiss` has `playback`
in its scope, and refuses the rest of every reply that was mid-stream on that connection whether or not the device
advertised the command ([rightyo-input.md](rightyo-input.md)).

## Reply segments (#932)

P1 defines the wire vocabulary. P2 implements host-side segmentation and rendering in `haild reply --say`.
P3 adds host listener support: the host advertises `reply_segments` (`ReplySegments.capability`) beside its
other capabilities, strips `segmentEnd` for devices that did not advertise it, handles `reply_yield` and runs the
backstop below. P4a adds device live-stream playback pauses and a callable local yield foundation, with synthetic
coverage only. P4b1 supplies the onset gate; P4b2 wires the device capture, yield, echo-tail handoff,
transport and segmented bulk Replay. The device now advertises `reply_segments` beside `heard_turns`, making
segment pauses and onset yield live in code with a P3 host. This is synthetic VM evidence, not a shipped build
or physically validated behavior. P5 adds the paused notice and Station tools UI below. App/physical validation and TestFlight integration remain host work.
P2 does not change coaching speech, acknowledgement clips or spoken announcements. The host behavior below has
synthetic test coverage, not physical-device or live captured-output proof.

One reply id spans many spoken segments; its text frame still carries the full spoken text. The P2
producer splits at sentence boundaries and puts `"segmentEnd": true` on the last audio frame of each segment
except the final one. The reply's final audio frame already ends its last segment. All audio frames retain the
same reply descriptor and stream id, with increasing frame sequences and distinct envelope frame ids.

`ReplySegmentation` supplies both limits: defaults are **v1, pending Mick**, at most two sentences and thirty
whitespace-delimited words per segment. As with reply pacing, haild reads environment tuning:
`HAILD_REPLY_SEGMENT_MAX_SENTENCES` (1–20) and `HAILD_REPLY_SEGMENT_MAX_WORDS` (1–300). An invalid value falls
back to that value’s default, with a content-free warning naming the variable.
These are piece sizes, not a cap on total spoken length; existing transport and
runaway-renderer safeguards remain. The pure segmenter preserves spelling and internal whitespace, protects
common abbreviations, initials, dotted initialisms, decimals, versions, URL/path internal periods, and closing
quotes/brackets. Newlines separate sentences/list items. `?` and `!` terminate sentences; ellipses (`...`/`…`)
terminate before an uppercase next token. Oversized sentences prefer the last clause end (`,`, `;`, `:`, `—`)
within the word bound, then a word boundary. Ambiguous abbreviations use deterministic lexical rules, not a
language model. Joins may change whitespace only; one-piece input is unchanged.

Each segment has its own owned vbsay renderer, sequentially retired and joined before the next starts. The
context, pacing, total frame budget and timing recorder span the whole reply. A non-final stdout segment
retains its last complete frame until more PCM or EOF: EOF flushes its remainder, or that held complete frame,
with `segmentEnd`. The final segment keeps legacy framing; `sendFinalPCM` still terminates the whole reply.
The files-only fallback also renders per segment and marks only the last frame of its last stable raw file.
Failure, supersession or cancellation stops subsequent renderers and uses existing owned-child retirement,
cancellation signalling and deferred-cleanup semantics. Rendering is sequential to retain this ownership model;
synthetic overhead and byte-identity evidence are in [the host test record](testing/reply-segments-host.md).
This is host-local synthetic proof, not a live captured-output round trip or physical playback validation.

- `segmentEnd` is only `true` or absent, never false, null or another type. It requires reply audio with a
  `streamId` matching `reply.audioStream`, `final: false`, and no `resume`. The property defaults to false and the
  encoder omits it when false, preserving legacy frame bytes. Audio decoding tolerates unknown keys: an older
  device ignores this key and plays audio as before. Even so, a host sends it only to a device that advertised
  `reply_segments`; an older device receives the segments back to back without the key.
- `{"command":"reply_yield","reply":"<UUID>","segment":1}` is DEVICE→HOST. `reply` is the `ReplyDescriptor.id`
  being yielded; `segment` counts segment ends whose playback finished before the owner took the turn. It is
  an integer from 1 through 10,000 (`ReplySegments.maxSegmentEnds`). Only these three keys are permitted;
  missing fields, null, invalid UUIDs, fractional/non-integer counts, out-of-range counts and extras fail decoding.
  A device sends it only to a host that advertised `reply_segments`. An older host refuses the unknown command
  as malformed; a device refuses it from a host through its existing unexpected-control-frame failure.
- P3 gates reply audio at `WebSocketPeer.prepareReplyPublication`, immediately before encoding. A device that
  advertised `reply_segments` receives the original flag; every other device receives `isSegmentEnd = false`,
  whose encoding omits the field and is byte-identical to legacy audio. Correlated replies, fallback/last-input
  routing and host clips (including clips gated by privacy) share this boundary. Device-local replay uses the
  bytes already delivered; there is no separate host replay send path.
- Both built-in host authorizers permit `reply_yield`, but the session additionally requires a ready connection
  whose own peer advertised `reply_segments`. A missing capability gets `unauthorized`,
  `terminal action is not authorized`, with the connection kept open. Before hello, a yield follows the existing
  non-hello rule: `malformed`, `first frame must be hello`, and the connection closes without a `reply_yield` log.
  A custom authorizer can still deny it. An authorized yield stops only that reply id if it is in flight on this
  connection. Later frames are refused as `replyStopped`, so the CLI retires its renderer. No `stop_playback`
  is sent: the device already stopped.
  Unknown, finished, already-stopped and other-connection replies do nothing and produce no response frame.
  `segment` is an informational count, never evidence of authority.
- After input from this connection is handed off (a delivered phone final text or ambient dispatch, the #370
  last-input condition), P3 stops every in-flight reply on that connection that has had a segment end enqueued.
  This backstop runs only on connections whose peers advertised `reply_segments`; older devices retain their
  existing behavior. Refused, held, unconfirmed and `.unowned` handoffs do not trigger it. It sends no
  `stop_playback` and leaves unsegmented and other-connection replies alone.
  Tracking is a subset of the existing 64-entry in-flight list, removed at final audio, stop or teardown. Stopped
  ids enter the listener's 64-entry stop ledger synchronously, so disconnect cannot hand later frames elsewhere.
- Content-free logs use `reply_yield` with `outcome=accepted|ignored|not_authorized` and `segment=<count>`, and
  `reply_backstop` with `outcome=stopped count=<count>` only when at least one reply is stopped.
  Neither reply ids nor request/reply text is logged by these events. Stop, dismiss and privacy still stop whole
  reply ids. Echo handling, acknowledgements and the not-sent clip retain their existing behavior.

Device playback (P4a/P4b2, synthetic only; not shipped or physically validated): the live-stream controller schedules
through a segment marker, then waits for its actual `.dataPlayedBack` completion before opening `segmentPause`.
Later frames queue under the same descriptor. After the configured window it drains them normally. The marker
barrier and pause hold the idle watch; resume gets a fresh frame-arrival deadline. The PCM player's expected
boundary neither raises its adaptive catch-up target nor records a playout gap, and even a short marker releases
an earlier catch-up hold. Stop/cancel invalidates callbacks and timers. The reply remains output-busy across the
pause, preserving the existing echo-guard mask and tail rather than unmasking between segments. Existing mute,
headset stop-and-mute and capture-suppression policies remain in force.

`ReplySegmentSettings` merges all validated values into the UserDefaults dictionary
`hailing-station.reply-segments.v1`, preserving other keys. Defaults **v1, pending Mick**: `pauseAfterSegment = 1.5` (0.1–10 seconds),
`sustainedOnset = 0.3` (0.05–2 seconds), `onsetThresholdDBFS = -35` (−60…−15 dBFS). Each invalid/nonfinite
value falls back independently. A controller reads saved settings at creation; Station tools assigns and saves a
validated copy on each edit, preserving sustained onset and unknown dictionary keys. A pause already open keeps
its original deadline; following windows use the edited settings. There is no
spoken "go on" resume in v1.

`yieldPausedReply(ambientListening:privacyOn:)` is a callable local foundation, permitted only in a played pause
window with ambient on and privacy off. It retires only that reply, ignores its late frames, preserves queued
other replies and exposes bounded, content-free `lastSegmentYield` (endpoint, descriptor UUID, played-marker count).
It accepts/retains no mic audio. P4b2 calls it from the pre-mask onset signal with fresh main-actor ambient
and privacy state, scoped to the current ambient endpoint. A refused yield does nothing. On success the device
synchronizes reply audibility (including any queued replacement), calls `endReplyTailForYield()` before closing
the analysed window, and then attempts `reply_yield` through the store's owned connection for that endpoint.
Both store and connection require ready state, the negotiated `reply_segments` capability and the captured
connection generation; reconnect/replacement never redirects a yield. A failed/unsupported send leaves the local
stop in force. Tail release fails closed if its safety interval is not met or another reply is audible; then the
normal reply tail applies. The tap-capture mask and its tail are untouched. Onset audio choice **B**: accept
losing the triggering onset; no pre-roll storage or replay path. Subsequent samples use the normal ambient path,
never a new privacy bypass.

P4b1 (synthetic only, **v1, pending Mick**) supplies the energy gate at the existing `EchoMaskedCapture`
PCM tap, before masking. P4b2 installs its caller once before capture; every buffer reads the current played
window and fresh main-actor ambient/privacy state. The onset handler reads those flags again, so a privacy or
ambient change after capture authorization still refuses yield. Window closure explicitly clears analysis
without waiting for another buffer. The capture forwarder synchronizes with the main actor; no real-time audio
render callback waits on it. The installed wiring never synchronously reconfigures/stops the tap from a callback. Calibration starts **after** the configured echo-guard tail
(default 400 ms), then measures 200 ms of floor RMS power. Only afterward can a sustained onset meet both
−35 dBFS and floor +6 dB for the configured 300 ms. The tail comes from `AmbientReplyEchoGuard`, not a second
constant. Calibration/tail audio cannot fire. A short window cannot fit these stages and never signals.

P4b1 retains only scalar detection state, clears it at window close, retains no PCM and emits a content-free callback
once per window. The gate itself only signals; P4b2 owns yield, mask handoff and transport. Diagnostics are counts only:
onsets, onsets without an admitted ambient request within N=5 s, and analysed-level/floor histograms with buckets
<−60, [−60,−45), [−45,−35), [−35,−25), [−25,0] dBFS. The injected clock expires diagnostic deadlines at 5 s;
P4b2 feeds the actual `ambient_heard` admission hook with an opaque scope token per endpoint/connection generation.
A timely request satisfies only the oldest pending onset in that scope; late requests cannot remove expired
counts. Pending entries are capped at 16, with overflow dropping the oldest as missed. Tokens are never logged
or persisted. This detects energy from any sound, not an identified owner or verified speech.

Bulk Replay containing segment markers re-enters the controller FIFO and honors actual-playback barriers and
pauses, preserving other queued replies and the existing late-frame ledger. Unsegmented Replay retains its
existing player path. The store publishes content-free `segmentYieldEvent` values with monotonically increasing
`UInt64` ids, distinguishing repeated successful local yields after Replay. Reply generation and admission scope
bind at frame ingress and remain fixed across reconnect and later windows.

P5 observes changes to `segmentYieldEvent.id` above the shared adaptive station view. A dismissible material banner,
“Paused — go ahead”, appears alongside the existing announcement banners for four seconds. It contains no
reply text and is never passed to the reply player or Announcer. With VoiceOver running, the change posts one
platform accessibility announcement; rendering, dismissal, repeated identical state, timeout and enabling
VoiceOver afterward do not repost it. Mounting the view does not announce an existing historical yield. A new
yield id replaces the notice and restarts its deadline, even for identical endpoint/reply/segment values after
Replay; an older timer cannot hide the newer notice.

Station tools → Turn-taking exposes “Pause between reply segments” (0.1–10 s, steps of 0.1 s) and “Voice needed
to take the turn” (−60…−15 dBFS, steps of 1 dB, Quieter–Louder with a numeric readout). Defaults remain **v1,
pending Mick**: 1.5 s and −35 dBFS; this qualifier appears only in comments/docs. Bindings use
`ReplySegmentSettings` validation and its dictionary-preserving save. The read-only “Turn-taking diagnostics”
section refreshes once per second while open: yield signals, signals without an admitted request within five
seconds, and all five buckets of both analysed levels and calibrated floors, as plain counts. P4b1 counts onset
signals (including signals refused by fresh ambient/privacy state), not confirmed successful yields or identified
speech. The UI says so. There is no reset API, reset button, persistence or new diagnostic logging.

`StationPlatform` handles UIKit/AppKit announcements; the same `Apps/Hail-iOS` views belong to both `Hail-iOS`
(iPhone/iPad) and `Hail-macOS` in `project.yml`. VM tests prove only the pure presentation/binding logic. The host
must build both targets and check VoiceOver once, dismissal/timeout, Dynamic Type, light/dark, and Mac, iPhone
and iPad layouts (including expanded chat, rotation and narrow Mac windows). Physical acoustic/transport checks
remain required; see the P5 host gate in the device test record.
See [the device test record](testing/reply-segments-device.md) for the split, synthetic checks and deferred work.
Synthetic P1 verification is recorded in [reply-segments-protocol.md](testing/reply-segments-protocol.md), and
P3 listener verification in [reply-segments-listener.md](testing/reply-segments-listener.md).

## Muting reply audio (#404)

`{"command": "set_reply_mute", "muted": true}` is a host-to-device control command that mutes the device's reply
audio, as its own mute control does. Later replies still arrive, and their text shows, but their audio plays
silently, so a replay still works. `"muted": false` unmutes. It carries only `command` and the boolean `muted`: the
decoder and the schema refuse any other key, and it grants no authority. A device advertises `reply_mute`
(`ReplyMute.capability`) in its `hello` when it can act on the command. A host never sends it to a device that did
not advertise it, because an older device refuses an unknown command as malformed. The host sends it when the owner
says "mute" or "unmute". To cut the reply now playing, it sends `stop_playback` first.

## Ambient take-over (#366)

The most recent device to start ambient listening on a host takes it over. There is no "ambient busy" refusal.
The wire carries two things for this, and each names a device only by its class (`phone`, `pad` or `mac`,
`AmbientTakeOver.deviceKinds`), never by its name:

- `hello.deviceKind` (optional) is the device's own class. An older device leaves it out. A host keeps a value
  only when it matches the vocabulary byte for byte; any other value fails the hello. Schema and decoder are both
  strict (only `phone`, `pad` or `mac`), so a device name can never be sent here. Absent stays valid.
- The previous device's next segment is refused with `not_allowed` and the message `ambient moved to <class>`,
  or `ambient moved to another device` when the new device did not give a class. It is an ordinary
  `ambient`-prefixed refusal, so an older device stops as it did before. A newer device shows it as a move, not as
  an error (`AmbientTakeOver.moved(_:)`).
- `{"command": "ambient_moved_here", "from": "<class>"}` tells the new device that its stream took over from a
  device of that class. `from` is optional. The decoder and the schema refuse any other key and any value outside
  the vocabulary. The command grants no authority. A device advertises `ambient_takeover`
  (`AmbientTakeOver.capability`) in its `hello` when it can act on the command, and a host never sends the
  command to a device that did not.
- `"resume": true` on an ambient segment (#373) marks a device's own automatic restart after the host ended its
  last stream, not a start someone asked for. It is allowed only on a stream's first segment (sequence 0, with a
  `streamId`). `false`, `null` or any later segment is refused by both the decoder and the schema, and an absent key
  means the start was asked for. A host never lets a resume start take listening over: while another device holds
  the stream, the start is refused with that device's `ambient moved to <class>`. The restarting device then shows
  the move, as if it had been taken over directly. With nobody listening, a resume start opens normally.

### The host's launch (#735 S-7a0)

`haild`'s hello may carry `hostInstance`, a random UUID made once per `haild` process. A device compares it with the
last one it saw for that host: the same id means the connection only dropped; a new id means the host restarted, so
privacy (in memory only, #809) has ended and the device does not resume. Only an exact match with a stored id counts
as a dropped connection: no id (an older host, or one that sent an id before and now does not) proves nothing either
way, so a device never resumes on it and keeps any privacy wish it holds (fail closed). Optional, so an older host's
hello is unchanged; a device never sends it, and `haild` ignores one a device sends. Schema and decoder are strict:
anything that is not a UUID fails the hello. It is advisory until the transport is authenticated (TLS).

### The user's own ambient request (#318)

`{"command": "ambient_heard", "target": "<target>", "text": "<words>"}` gives the device that spoke the request its
ambient stream just handed to `target`, as heard, so the thread can show the user's own words as their message.
The host sends it at most once per request it admits for delivery (after the echo, withdrawal and duplicate checks),
only to that device and only while it still selects `target`, just before the dispatch step. So it arrives ahead of
the acknowledgement clip and the reply. It is sent before dispatch's own checks: a dispatch refused after it (policy,
lockdown, a changed binding or selection, an audit failure) leaves the words shown, and the refusal reaches the device
as before. A heard turn over the 8 KiB cap is not shown (RightyO admits turns up to 16,000 bytes). Both are tracked in
#392. `text` is the request's heard turn
(the user's own words), never the prompt envelope or a producer's formed request. It is 1 to 8 KiB of UTF-8, the text
payload's cap. Besides the optional `turn` below, the decoder and the schema refuse any other key. The command grants
no authority, and a host refuses it from a device. A device advertises `ambient_heard` (`AmbientHeard.capability`) in
its `hello` when it can show the text, and a host never sends the command to a device that did not. The host never logs the text.

### Optional heard-turn correlation (#923)

The protocol accepts an optional `turn` UUID string on `ambient_heard` and on an `error` with code
`voice_route_refused`. Omit it for the legacy shape; null, invalid UUIDs and `turn` on any other control command or
error code are refused. Frames carrying `turn` refuse unknown payload fields; legacy error extension tolerance is
unchanged. `heard_turns` (`HeardTurns.capability`) is the device capability that permits the host to send this field,
in addition to the frame's existing capability requirements.

The host mints a fresh random UUID at the speaking connection's heard-frame enqueue boundary, independently of
content. It records a host-local request key → turn only after a successful queue, in a 64-entry in-memory FIFO for
that connection. A matching `voice_route_refused` consumes the record; completion, connection teardown, and oldest
entry eviction discard it. A request with no successfully queued heard turn on that connection has no turn on its
refusal. Both frames require `heard_turns` plus their existing capability (`ambient_heard` or `request_refusals`);
legacy frames omit the field entirely. No other command or error carries it. Neither heard words nor turn IDs are
logged. The identifier grants no authority.

The device model (PR C1) stores a received heard UUID on its chat entry within the existing 200-entry in-memory
history. A `voice_route_refused` with the same UUID on the same endpoint's current connection marks that entry's
`notSent` state; the separate refusal notice and announcement remain unchanged. Matching uses only UUIDs, never
content. Missing or unknown turns leave entries unchanged. Correlation is consumed by a matching refusal, evicted
with its entry, and cleared on disconnect, reconnect, endpoint replacement or removal without rewriting history.
A heard entry without a refusal stays sent. Neither heard text nor correlation is logged.

The device advertises `heard_turns` alongside `ambient_heard` and `request_refusals` (PR C2). A refused heard entry
shows "You · not sent" with secondary text and heading on a greyed `.quinary` bubble. VoiceOver labels it "You said,
not sent" before the message text, like "You said, heard but not sent" for overheard entries. The overheard setting
still hides only overheard entries, so a refused heard request remains visible. An older host simply omits the
optional turn and needs no change. Synthetic verification is recorded in [the PR B host test
record](testing/heard-turn-host.md), [the PR C1/C2 app test record](testing/heard-turn-app.md) and [the PR A protocol
test record](testing/heard-turn-protocol.md). The app still needs physical accessibility checks; this is not
physical-device proof.

### Overheard remarks (#398)

Both sides advertise `ambient_overheard` (`AmbientOverheard.capability`) in their `hello`. A device sends
`overheard_scope` only to a host that advertised it, because an older host refuses the command.

`{"command": "overheard_scope", "scope": "off" | "owner" | "everyone"}` is sent by a device to choose which turns its
ambient stream heard but did **not** send it wants to see. A host starts every connection at `off`, so nothing is sent
until the device asks. The scope applies to that connection only and resets on reconnect. `owner` means only turns
attributed to the enrolled owner; `everyone` includes other speakers. The decoder and the schema refuse any other key or
value.

`{"command": "ambient_overheard", "target": "<target>", "text": "<words>", "speaker": "owner" | "other"}` gives the
device one such turn, within its scope, only while it still selects `target`, and only when it advertised
`ambient_overheard` (`AmbientOverheard.capability`). `text` is the heard turn, 1 to 8 KiB of UTF-8. The command
grants no authority, and a host refuses it from a device. A host never sends the assistant's own reply heard back, and
never logs the text.

**Named guests (#434).** A turn with `"speaker": "other"` may also carry `"name": "<display name>"`: the display name
of the enrolled guest RightyO bound that turn's voice to (`rightyo enroll --name`). It is absent when the speaker is not
bound to an enrolled guest, so a device shows "Someone" as before; a tentative or unknown speaker is never named. A
device that can show it advertises `ambient_overheard_names` (`AmbientOverheard.namesCapability`) as well, and a host
sends `name` only to such a device, because an older device refuses the unknown key. `name` is 1 to 64 Unicode
scalars (RightyO's own bound) with no control, format or line-breaking characters and no leading or trailing
whitespace, and is never sent with `"speaker": "owner"`; the decoder refuses anything else, and the schema checks the
type and length. Like the text, the name is shown on that one device only and never logged by the host.

### Owner voice status and input route (rightyo#164)

A voiceprint enrolled on one input chain can fail on another (a USB mic, CarPlay), and then every owner-only feature
(the spoken stop confirmation, voice mute, "Just me") fails silently. Two commands make that visible and attributable.

`{"command": "owner_voice", "state": "unrecognized" | "recognized"}` is sent by a host to the device whose ambient
stream it is: `unrecognized` when RightyO has heard enough speech on this input without binding the enrolled owner,
`recognized` once it does. It is sent only to a device that advertised `owner_voice_status`
(`OwnerVoice.capability`), because an older device refuses an unknown command. It carries no name, score or audio
detail, and grants no authority.

`{"command": "ambient_input", "route": "<route>"}` is sent by a device to a host that advertised `ambient_input_route`
(`AmbientInput.capability`), at the start of an ambient stream and when its input route changes. `route` is one of the
diagnostic `route` tokens (`built_in_mic`, `usb_audio`, `car_audio`, `bluetooth_hfp`, ...): a route kind, never a port
or device name. The host logs it with the stream so a speaker-ID mismatch can be attributed to an input chain.

The decoder and the schema refuse any other key or value in either command.

### Host health summary (#614)

A device's Mac Setup shows the host's `haild doctor` result, so a broken host is visible from the phone. A device
sends `{"command": "health"}` (nothing else) only to a host that advertised `host_health` (`HostHealth.capability`).
The host answers on the same connection:

`{"command": "health_report", "report": {"version": "0.1.0", "build"?: "<16 hex>", "checks": [{"name": "<check>", "ok": true | false}, ...]}}`

- `version` is the host's release version.
- `build` is the first 16 hex digits of the running executable's SHA-256.
- `checks` holds 1 to 16 checks, each name at most once. Each check is one of the `haild doctor` names, with whether it passed: `daemon_running`, `build_match`, `host_id_match`, `listener_ready`, `ambient_listening`, `device_connected`, `recent_refusals`, `audit_history`.

The doctor's free-text detail and fix never cross the wire, because they can name paths, ports and identities. The device words each check itself and points to `haild doctor` on the Mac for the detail.

The report is read-only and grants no authority. The decoder and the schema refuse any other key or value. Only the decoder checks that a name appears once.

## Session update cards (#609)

A local session can give the user an update without a pending request: finished work, a decision it needs, or a
failure. The host decides when to speak it (see `SessionUpdateQueue`); this command is how a device shows it.

`{"command": "session_update", "update": "<uuid>", "session": "<name>", "priority": "info" | "action", "text": "<line>",
"card": "<detail>"}` is sent by a host to a device that advertised `session_update` (`SessionUpdateCard.capability`),
because an older device refuses an unknown command.
- `session` is the speaking session's name (#371), the target id or its display name: 1 to 64 printable scalars with no
  surrounding whitespace, by the same rule as a guest's name. The host fills it from the live registry target the
  update was submitted for, never from text the caller supplied.
- `text` is the short line that is or will be spoken.
- `card` is optional detail (links, PR numbers) that is shown and never spoken. It is a plain string for now. If the
  reply metadata field from #606 lands, the card body may move to it.
- `update` identifies the update, so a device shows a resent one once.

The command selects nothing and grants no authority. The decoder refuses any other key, an unknown priority, an
explicit null or empty card, and text over the text payload cap. The schema checks the shape and lengths.

### Media mode state (#612)

Media mode (#551) is the owner's spoken "media mode" / "done watching": while it is on, RightyO attends only to the
owner naming the assistant, so replies stop. It lives on the host, so a device needs to be told, or replies just seem
to stop.

`{"command": "media_mode", "on": true | false, "reason"?: "voice" | "timeout", "expires"?: <Unix ms>}` is sent by a
host to the device whose ambient stream it is, each time the mode changes for that stream. `reason` says why: `voice`
when the owner said so, `timeout` when an on mode turned itself off. `expires` comes only with `on: true`: when the
mode will turn itself off, in Unix milliseconds like a frame's `ts`. It is sent only to a device that advertised
`media_mode` (`MediaMode.capability`), because an older device refuses an unknown command. It shows state only: it
grants no authority, and a device cannot change the mode with it.

The decoder refuses any other key, an unknown `reason`, a non-positive `expires`, or `expires` with `on: false`; the
schema refuses all but the last, which only the decoder can check.

### Duck mode state (#735)

Duck mode is the owner's rubber-duck mode ("let me think out loud"): while it is on, the owner's turns are kept for
later instead of being sent as requests. Like media mode it lives on the host, so a device needs to be told.

`{"command": "duck_mode", "on": true | false, "reason"?: "voice" | "timeout" | "device", "expires"?: <Unix ms>}` is
shaped exactly like `media_mode`. `reason` says why it last changed: `voice` when the owner said so, `timeout` when an
on mode turned itself off, `device` when a device asked. `expires` comes only with `on: true`. It is sent only to a
device that advertised `duck_mode` (`DuckMode.capability`), because an older device refuses an unknown command. It
shows state only and grants no authority. Nothing turns duck mode on yet; the host behaviour comes later in #735.

The decoder and the schema refuse the same things as for `media_mode`.

#### The privacy switch (#735 S-6)

`{"command": "set_privacy", "on": true | false}` is sent by a device to a host that advertised `set_privacy`
(`DuckMode.privacySwitchCapability`), when the owner flips the privacy switch in the app. Privacy is duck mode
internally. It carries nothing else: no target, connection, reason or words. The host turns privacy on or off for that
connection's own ambient stream only, and only while that connection has one. An on from a connection that has not
opened a stream yet is its pre-arm (#904): the device re-asserts privacy before it resumes after a reconnect, and the
connection's first stream then starts private. An on after the connection's stream ended is not acted on. It answers
only with its `duck_mode` notice, `reason: "device"`; there is no reply frame. A request that matches the state
already held does nothing, and so does a refused pre-arm, so a device that hears no notice fails closed.

The device shows privacy as on only once a `duck_mode` notice says so on a live connection; until then (a pending
switch, connecting, a stale or lost connection, an older host) it shows not private. An older host does not advertise
the capability, so a device never sends the command there (an older host would refuse it). The decoder and the schema
refuse any other key, and the decoder refuses a missing or non-boolean `on`.
