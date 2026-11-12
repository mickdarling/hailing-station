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

### Held ambient requests (#1120) — PROPOSED

PR 1 defines protocol types only. No host or app behavior, capability advertisement, Send / Discard UI or
physical-device validation ships in this slice. A future device advertises `held_requests`
(`HeldRequests.capability`) only when it can show a clear held-message notice, its reasons and Send / Discard.
The host sends the following notices and resolutions only to that capable device:

```json
{"command":"request_held","held":"00000000-0000-4000-8000-000000001120","turn":"00000000-0000-4000-8000-000000000923","reasons":["rule_match","guard_timeout"],"rules":["sudo","custom"],"expires_in":60}
{"command":"held_resolution","held":"00000000-0000-4000-8000-000000001120","outcome":"refused","reason":"policy_changed"}
```

The device's explicit choice has this shape:

```json
{"command":"held_decision","held":"00000000-0000-4000-8000-000000001120","action":"send"}
```

`held` is a fresh opaque UUID, never a hash, binding or text. Optional `turn` correlates the #923 heard entry
and requires `heard_turns` as well. This proposed extension permits `turn` on `request_held`; current supported
heard-turn commands retain their existing rules. Omission is valid; null and invalid UUIDs are refused.

`reasons` is a nonempty unique list of at most four closed tokens: `rule_match`, `guard_timeout`, `confirm_tier`,
`rate_limited`. Both a rule match and timeout can survive the same evaluation. `rules` is required but may be
empty, with at most 16 tokens of at most 32 UTF-8 bytes each. Its closed vocabulary normalizes the built-in guard
names to `rm_rf`, `sudo`, `force_push`, `git_reset_hard`, `git_clean`, `destructive_git`, `branch_delete`, `delete`,
`disk_write`, `permissions`, `shell`, `fork_bomb`, `credential`; all configured rules use `custom`, never their
name, pattern or request text, even when a configured name matches a built-in name. This vocabulary is
**frozen for `held_requests`**: adding a daemon default does not add a wire token. `HeldRequestRule.wireRule`
in HailProtocol collapses runs of spaces and hyphens to one underscore **only for trusted built-in names**;
if the result is outside the frozen set it returns `custom`. Every configured name returns `custom` without
normalization. The closed hold reason remains present regardless of this mapping: unknown rule names never
fail open, suppress the hold, or appear raw on the wire. `HeldRequestRuleVocabularyTests.everyDaemonDefaultMapsToAFrozenWireRule`
permits new defaults mapped to `custom` and rejects any mapping emitting an unfrozen token; the protocol mapping
contract has separate synthetic coverage. `expires_in` is this notice's remaining Send authority from issuance,
in whole seconds from 1 through 3,600 inclusive, rather than a wall-clock timestamp or content lifetime.

The only actions are `send` and `discard`. Outcomes are `sent`, `discarded`, `notice_expired`, `refused`, `stale`.
The unshipped `expired` spelling is replaced by `notice_expired` to avoid implying content deletion; it is rejected.
Only `refused` requires `reason`, a closed `HeldRequestRefusalReason` value; other outcomes forbid it.
All three controls reject unknown fields, unknown enum values, missing required
fields, null optional fields, invalid UUIDs and out-of-bounds values. The generated schema mirrors these bounds.

**PROPOSED Send refusal checks.** The future held handler must revalidate against the real host gates below
immediately before handoff. These are proposed mappings to existing checks, not shipped held-request handling.
The nine reasons distinguish changes to pinned authority, current denials, and resource/liveness failures;
none can contain a name, request fragment, hash, pattern or underlying error string. When several checks fail,
use the first applicable row in this order so the reason is deterministic.

| Closed reason | Host check that refuses Send (PROPOSED mapping) |
| --- | --- |
| `connection_lost` | Owning `WebSocketPeer.isLive` / listener peer membership fails before handoff. Record locally if the transport can no longer carry a resolution. |
| `selection_changed` | `HostSession` selection generation or selected-target scope differs from the held snapshot (`LocalDispatch.requireSelection`). |
| `target_unavailable` | `host.registry.listing()` has no live entry for the pinned target. |
| `binding_changed` | The live listing binding differs from the held binding (`LocalDispatch.dispatchScoped` binding check). |
| `policy_changed` | The snapshot captured with `HailHost.inputPolicyGeneration(for:)` fails `TargetPolicyGeneration.requireCurrent()`, including a reload, tier change or unreadable policy. |
| `lockdown` | Current `Policy.evaluate` returns `.denied(.lockdown)`. |
| `denied` | Current authorizer/policy/delivery gate refuses for another reason: missing authorization, allowlist/tier denial, confirmation still required, renewed guard match/timeout, pending target input or adapter refusal before handoff. Send never bypasses these checks. A continuing hold condition also produces a fresh `request_held` for the same content. |
| `rate_limited` | Current `Policy.evaluate` returns `.denied(.rateLimited)` for target/device rate limits. |
| `capacity` | `HostSession` delivery admission cannot reserve a live reply/request slot. |

**PROPOSED decision lifecycle and outcomes.** Content stays `held` until `sent` (one successful, validated
handoff) or `discarded` (an explicit Discard, including after notice expiry). `refused` is a failed Send attempt,
not a content disposition: **every** refusal reason keeps the content held, tells the device the closed reason,
and leaves Send again later / Discard available. `notice_expired` means only "this notice's Send authority
ended; content still held". `stale` means this connection cannot access a record; it is never delivery authority
or, by itself, evidence that content was deleted. Holding and all outcomes leave the ambient stream running;
none sends an ambient stop or restarts it.

The host serializes decisions, expiry and handoff per held UUID. Every Send, even during an unexpired notice,
runs **every** current authority, policy, scope, target, binding, selection, guard, rate, capacity and connection
check afresh immediately before handoff. Never deliver based on an old notice or cached evaluation. An expired
notice cannot authorize delivery: a later explicit Send starts a fresh evaluation of the **same held content**
with the same held UUID. If any hold condition still applies, refuse the attempt with the applicable closed reason
and issue a fresh `request_held` with current reasons/rules and a new notice deadline; the device shows "Still held"
and requires another explicit Send or Discard. Other refusal checks also retain the content and show their reason.
If all checks pass in that fresh evaluation, that explicit Send may authorize exactly one handoff. A changed pinned
target/binding/selection cannot silently redirect it, and a changed policy cannot reuse old authority. No expiry,
retry timer, reconnection or rule-name fallback may release content or inject it into provider context.

**PROPOSED replay and late decisions.** Record successful Send / explicit Discard before a competing decision
can run. Duplicate or conflicting decisions after either terminal disposition replay it unchanged and cannot
hand off again. Coalesce overlapping Send attempts into one evaluation/handoff; a refusal or notice expiry must
not be cached as a permanent final resolution that prevents a subsequent explicit retry or Discard. A notice
expiry timer reports `notice_expired` once for that notice without consuming the content. A late Discard still
discards it; a late Send takes the fresh evaluation path above. An uncertain handoff stays held with delivery
status visibly unresolved; never retry automatically or permit another Send until reconciliation establishes
whether it succeeded. An unknown or inaccessible UUID gets `stale`, without revealing whether another owner has
it. These controls alone do not implement decision serialization or delivery reconciliation.

**PROPOSED retention, distinct from Send authority.** Mick's requirement is verbatim: "the fix shouldn't be to
find out which are the bad phrases the fix should be to fail safe". Undelivered held content is never dropped.
Retain the original content, heard-turn correlation, hold reasons and pinned target/binding/policy/selection
metadata **inertly in host memory until successful Send or explicit Discard**. No age-based purge, refused Send,
notice expiry, admission pressure or connection teardown deletes it. Terminal Send / Discard may release its
content; keep minimal terminal resolution records for duplicate protection for the owning connection's lifetime.
No recordings or disk persistence are introduced.

**PROPOSED connection teardown and re-offer — deferred blocker.** Disconnect ends that connection's notices'
authority, but retains its content and ownership metadata. The owner's next connection **from that device** must
be offered its pending holds again only after an authenticated device/owner association, fresh evaluation and
new notice authority; never identify an owner by a display name, source string or possession of a UUID alone.
This protocol-only slice cannot safely define that association, inventory/re-offer exchange or acknowledgement
against the current unauthenticated listener. They are explicit deferred #1120 requirements before advertisement.
Until recovery succeeds the app must keep its pending entry visible as "Held on host; disconnected — recovery
pending", with Send disabled; it must not show discarded, sent or lost merely because the connection ended.
A `stale` response on an unassociated new connection does not remove that entry or purge the host content.
A later implementation must define authenticated re-offer and access to explicit Discard, including a visible
host-local recovery path, before enabling holds; this slice makes no claim to ship that behavior.

**PROPOSED bounding by admission, never eviction.** Reserve a possible hold slot **before accepting a new request**:
at most **8 unresolved held messages/reservations per connection allocation** and **64 host-wide**. Disconnected
holds continue counting against their original allocation and the host limit; reconnect cannot reset these limits
or create a fresh allowance for the same owner. Successful Send / explicit Discard frees a slot; expiry/refusal
never does. When either bound is reached, do not accept more content into host processing, evict an old hold, or
claim a new hold was accepted. The app retains the new, unadmitted content locally and visibly says "Host is
holding too many messages; Send or Discard one to continue. This new message is waiting on this device." Block
further submission/capture admission until a slot is reserved; do not overwrite that waiting message. A request
already accepted under a reservation can always become a hold, including when it fills the last slot. A Send
refused for delivery `capacity` retains its existing slot/content. The admission/backpressure exchange and app
buffer handling are deferred host/app requirements, not invented fields in these controls; enabling the capability
is blocked until they guarantee no accepted content can be silently lost at a bound.

**Known limitation — daemon restart loses content.** Host shutdown, crash or restart loses these in-memory holds;
this proposal does **not** specify persistence. On a confirmed host-instance change / unrecoverable missing record,
the app must show the pending hold as `stale`: "Host restarted; held content was lost. Nothing was sent."
If handoff status was uncertain, show "Delivery status unknown; held copy was lost" instead of claiming nothing
was sent. Do not automatically resubmit. Unknown ownership on reconnect is distinct from confirmed restart loss.
Defining the restart/instance reconciliation exchange is also deferred before advertisement. This known loss
limitation must remain visible; a durable never-loss guarantee requires an issue-level persistence requirement.

**Open questions for #1120 (not decided).** Does privacy-on or lockdown require deleting undelivered held content?
Either would be an **explicit, visible exception** to the never-drop contract and needs an issue-level requirement,
including owner notice, scope and recovery implications. Neither is permission to purge in this proposal; lockdown
currently maps only to a retaining Send refusal. What authenticated device association and recovery UI/protocol
will safely re-offer disconnected holds and allow Discard? What admission/backpressure and device-buffer contract
will implement the 8/64 bounds? How will restart loss and uncertain handoff be reconciled visibly, and does #1120
require persistence to remove the stated restart limitation? These remain open; no privacy deletion, recovery or
persistence behavior is advertised as implemented.

These types provide no delivery authority or host retention mechanism. The lifecycle, refusal mapping and
retention above are **PROPOSED**; host handling, guard outcomes, context exclusion, UI and audit remain later
#1120 slices. Synthetic validation is recorded in [the PR 1 protocol test record](testing/held-requests-protocol.md).

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
- `checks` holds 1 to 16 checks, each name at most once. Each check is one of the `haild doctor` names, with whether it passed: `daemon_running`, `build_match`, `host_id_match`, `listener_ready`, `ambient_listening`, `device_connected`, `recent_refusals`, `audit_history`. The doctor's `target_input` check (#894) is not one of them, so it is left off.

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
mode will turn itself off, in Unix milliseconds like a frame's `ts`. Changes are sent only to a device that advertised
`media_mode` (`MediaMode.capability`), because an older device refuses an unknown command. It shows state only: it
grants no authority, and a device cannot change the mode with it.

The decoder refuses any other key, an unknown `reason`, a non-positive `expires`, or `expires` with `on: false`; the
schema refuses all but the last, which only the decoder can check.

### Effective first-start mode snapshot (#941 PR B)

`mode_snapshot` (`ModeSnapshot.capability`) is advertised by haild. A device opting in receives exactly one
`duck_mode {on}` followed by `media_mode {on, expires?}` immediately after the host hello, before the peer reads
another frame or admits audio. This opt-in permits these two existing frames independently of the individual
`duck_mode` and `media_mode` capabilities. Older devices receive no snapshot. Capabilities are free strings in the
hello schema, so no schema change or new command is needed.

The snapshot reports effective first-start privacy (own duck/pre-arm, counting live source, park or overflow) and
unexpired media state with its original expiry. Privacy wins; otherwise the latest held/parked media-or-meeting
arming wins. It carries no reason, claims, words, names or hashes, and does not arm or consume anything. There is no
meeting frame: meeting state remains unresolved on the device and must block any restore requiring it. See
[rightyo-input.md](rightyo-input.md#effective-modes-after-hello-941-pr-b-host-side) for the admission rule and limits.

An authorized `set_privacy {off}` from an opting-in, live connection clears privacy parks and overflow even if it
never streamed or armed. Under the same router lock, the host then re-evaluates the snapshot's effective privacy
rule. If an unrelated counting live holder still applies, the unarmed connection receives `duck_mode {on:true,
reason:"held_elsewhere"}`; otherwise it receives `duck_mode {on:false, reason:"device"}`. Neither response arms the
connection, holds its replies or starts a child. An armed one uses the existing switch exit. The initial
after-hello snapshot itself remains boolean with no reason (#993). Stopping, closed and ended peers cannot use this
new path. An older connection's unarmed off still does nothing. This is host groundwork, with synthetic tests only;
app opt-in and automatic restore are later work, and missing or unresolved state blocks restore.

### Duck mode state (#735)

Duck mode is the owner's rubber-duck mode ("let me think out loud"): while it is on, the owner's turns are kept for
later instead of being sent as requests. Like media mode it lives on the host, so a device needs to be told.

`duck_mode` is shaped exactly like `media_mode`: `command` and boolean `on`, with optional `reason` and `expires`
(Unix milliseconds). Its reason tokens are `voice`, `timeout`, `device` and `held_elsewhere`. `reason` says why it
last changed: `voice` when the owner said so, `timeout` when an on mode turned itself off, `device` when a device
asked, or the fixed token `held_elsewhere` when a capable off cleared parks but another counting live holder keeps
the next start private. `expires` comes only with `on: true`. It is sent only to a device that advertised
`duck_mode` (`DuckMode.capability`), apart from the explicit `mode_snapshot` opt-in above. It shows state only and
grants no authority. The host privacy behavior is described in `docs/rightyo-input.md`.

The decoder and the schema refuse the same things as for `media_mode`.

#### The privacy switch (#735 S-6)

`{"command": "set_privacy", "on": true | false}` is sent by a device to a host that advertised `set_privacy`
(`DuckMode.privacySwitchCapability`), when the owner flips the privacy switch in the app. Privacy is duck mode
internally. It carries nothing else: no target, connection, reason or words. The host turns privacy on or off for that
connection's own ambient stream only, and only while that connection has one. An on from a connection that has not
opened a stream yet is its pre-arm (#904): the device re-asserts privacy before it resumes after a reconnect, and the
connection's first stream then starts private. An on after the connection's stream ended is not acted on. It answers
only with its `duck_mode` notice, `reason: "device"`; there is no reply frame. Except for the snapshot-capable owner-off above, a request that matches the state
already held does nothing, and so does a refused pre-arm, so a device that hears no notice fails closed.

The device shows privacy as on only once a `duck_mode` notice says so on a live connection; until then (a pending
switch, connecting, a stale or lost connection, an older host) it shows not private. An older host does not advertise
the capability, so a device never sends the command there (an older host would refuse it). The decoder and the schema
refuse any other key, and the decoder refuses a missing or non-boolean `on`.

## Device local voice-stop report (#1212, host slice)

`voice_stopped` is a device-to-host control report that playback has already stopped locally. Its only optional
field is `latency_ms`, an integer from 0 through 60,000 measured on the device from the end of the spoken word.
Omit it when unavailable. Explicit null, other types, out-of-range values, and all other payload keys are refused.
It carries no words, audio, identity, target, or withdrawal authority.

```json
{"command":"voice_stopped","latency_ms":123}
```

The **host** advertises `device_voice_stop` in its negotiated hello only when its ambient gate and report handler
are wired. A device must send this command only after seeing that capability; older hosts reject unknown commands.
`DeviceVoiceStop.report(latencyMs:hostCapabilities:)` returns no report without that capability or for invalid
latency. The caller must additionally enforce privacy and stop local playback before reporting. This is a compatible
v1 extension; this PR carries `protocol:compatible` and `security:critical`. Existing capability directions are unchanged.

The host accepts the report only on its negotiated, ready connection with that connection's active ambient stream
and privacy off. A report before hello fails closed as malformed; a closed session ignores further reports. It logs `ambient_voice_stop_ignored reason=not_ready`, `reason=private`, or
`reason=no_active_stream`; every authorization denial uses `reason=unauthorized`, including read-only probes. It uses the
existing playback stop to retire that connection's in-flight replies and may
send an idempotent `stop_playback` back. The existing `ambient_dismissed` event records
`reason=device-voice-stop scope=playback source=device withdrawn=0 delivered=0 playback=<token>` and optional
`latency_ms`. The hyphenated `reason=device-voice-stop` follows RightyO's `reason=stop-phrase` style.
Playback tokens retain their existing meaning. No sentence or confirmation clip is sent for this report.

For ten seconds after a valid report, measured with a host monotonic clock, a RightyO playback-scope dismissal
on the same connection still applies its usual dismissal and playback stop, but skips its spoken #418 confirmation
and logs `ambient_stop_confirmed outcome=skipped reason=device_stopped`. At ten seconds and beyond, normal
confirmation rules apply. Valid reports retire pending confirmations; the suppression is rechecked atomically
with the final clip enqueue. Bytes enqueued before the report is recorded cannot be recalled. PR 3 will mitigate
that ordering bound by having the device drop a host stop-confirmation clip arriving shortly after its local stop.
Every valid report retires that connection's in-flight replies and pending confirmations and refreshes the ten-second
confirmation-suppression window. A separate last-accepted timestamp bounds outbound stop coalescing: within one second,
only when no reply has entered flight on that connection since the last accepted stop, the redundant `stop_playback`
and dismissal log are coalesced. Coalesced reports do not refresh the accepted timestamp. New audio, including audio
that has already completed, requires another `stop_playback`. Coalesced reports log
`ambient_voice_stop_ignored reason=coalesced`. Ignored/coalesced log lines are limited to one per reason per
connection per ten seconds, with `suppressed=N` on the next line for that reason. Teardown removes these records
and the device-stop window. Late reports and dismissals cannot recreate connection records; completed confirmation
work removes its token set when empty. A held confirmation retired by teardown logs `reason=connection_closed`.
Device playback diagnostics remain the source of actual playback-end reports to RightyO; the report adds no second
reply-ended notification.

The original host slice added the protocol and host handling; the queued CLI audio boundary is implemented below.
Device detection, app wiring and physical latency/self-trigger proof remain later work. Neither host slice enables
a stop detector or changes its default.

## Queued CLI audio and stop ordering (#1212, PR 1b)

This host implementation has synthetic coverage only. The owner-only reply socket now recognizes
`kind: "reply-audio"`; the device WebSocket protocol is unchanged. Each transaction is one JSON line and one
`LocalReplyResponse`. Queue requests retain the socket's ownership, size, connection and shared rate limits.
Wrapped final audio retains the independent terminal-frame budget. Actual publication is audited before delivery.

- `{"kind":"reply-audio","action":"enqueue"}` returns `delivered: 0` and
  `replyAudio: {"skipped":false,"ticket":{"epoch":"<daemon UUID>","position":N,"releaseKey":"<random UUID>"}}`.
  The daemon increments one global UInt64 counter; it refuses exhaustion rather than wrapping.
- `action: "check"` additionally requires `ticket` and `frame`. The frame is a synthetic two-byte audio probe
  carrying the job's ordinary reply descriptor, source and target. It is never published. Normal recipient
  resolution and validation run, without advancing request/flight state or acquiring a routing pin. The response
  has `delivered: 0` and `replyAudio: {"skipped":false}` or `{"skipped":true}`.
- `action: "publish"` requires the same ticket and the actual audio `frame`. It uses ordinary reply routing,
  policy, binding, transport, privacy and stop gates, plus the ticket check at final transport enqueue. Successful
  publication returns `delivered: 1` and `replyAudio: {"skipped":false}`. A queue-stop skip returns
  `delivered: 0`, no error/code, and `replyAudio: {"skipped":true}`. Other refusals retain the existing codes.
- `action: "release"` requires only the ticket, with its unguessable `releaseKey`; no frame or content is accepted.
  It removes only that reservation, without a stop or floor change. A wrong key, unknown/expired/finished ticket,
  or repeated release is a no-op. A released ticket cannot be associated or published again. Cleanup remains
  available when the shared publication rate bucket is full.
- Unknown outer request/ticket keys, malformed shapes, foreign epochs, zero and unissued positions fail closed.
  A ticket grants no recipient or policy authority. Daemon restarts invalidate tickets. A CLI cannot infer support
  from an ordinary reply acknowledgement: missing `replyAudio` is a refusal.

Every detached audio job requests its ticket before submitting text or optional Markdown metadata, then attempts
`reply-audio.lock`. Enqueue may include the job's audio probe as `frame`, establishing its reply id and target.
A failed ticket request still delivers text and metadata. Capacity returns a non-retryable
`replyAudio: {"skipped":true,"reason":"capacity"}` outcome; the CLI prints `reply audio dropped: capacity`
and exits 0 after text delivery. Doctor counts this as `replyAudioCapacity`, separately from `publicationFailed`.
Other issuance errors still refuse audio. On lock acquisition it checks admission before
reading/synthesizing audio, and wraps every later audio frame with its ticket. This includes jobs that take the
lock without waiting, covering the preceding reply's device playout tail. Foreground publication stays unchanged.

Each accepted playback stop marks its connection and every associated reply target with the current counter
before retiring in-flight replies. Every stop source captures its position synchronously when accepted, before
scheduling work or awaiting another actor. Delayed connection/target marks use `max(existing, captured)`; they
never read a newer counter. Only live registered connections can apply marks, so late work cannot recreate
connection state after teardown. Privacy entry marks unconditionally at entry; its delayed announcement does not
mark again. The host association set includes selected/covered voice-route targets, targets
of in-flight and pinned replies, and request owners on the connection. Hello names and device kinds are
unauthenticated and are never identity keys. Target marks retain the 1024 most recently stopped targets (refreshing
a target moves it to the end), outlive connection teardown and expire with the daemon epoch. Only host stop and
privacy-entry paths write marks; local socket enqueue/check/publish requests cannot create or refresh them.
In-flight target bookkeeping
is bounded by the existing 64 flights per connection; pins retain their existing global bound of 64.
Evicting a target raises a daemon-wide floor to the maximum of its previous value and the evicted mark. Every
admission and final enqueue skips tickets at or below that floor for every target. This may silence unrelated old
jobs if 1024 targets are stopped, but eviction can never make stopped audio playable. The floor resets only with
the daemon epoch; newer tickets remain playable.

Both a RightyO playback-scope dismissal and an accepted device `voice_stopped` mark the queue, including repeated
reports whose outbound `stop_playback` is coalesced. Privacy entry also marks the queue: its unconditional pending
reply drop resolves the entry's captured stop before any exit releases the hold, even if no entry clip is announced.
Spoken mute explicitly does not mark the queue. Privacy's separate delivery hold still prevents text and audio
publication while private.

Acceptance registers a pending-stop token (id, connection, cutoff) under the same mutex as ticket issuance and
final audio enqueue, while the connection is registered. Capture after teardown returns no token and marks nothing.
A first-audio admission at or below any pending cutoff waits asynchronously on a continuation. The final enqueue
checks pending stops again under the mutex, so a stop accepted during routing cannot lose to a first frame.
Tickets above every pending cutoff proceed immediately. Resolving the session's selected/covered, pinned,
in-flight and request-owner targets writes their marks at the captured cutoff even after connection teardown,
then removes the pending stop and resumes admissions outside the lock. Only the connection mark needs liveness.
Queue retirement is recorded before in-flight ledger entries are dropped.
Current in-flight retirement and the `stop_playback` send precede target resolution; neither waits on this
first-audio barrier or the session snapshot. The snapshot includes the just-retired flight IDs.
**O:** If lookup or the snapshot fails, including the 250 ms stop-resolution timeout, resolution raises only
`unpublishedFloor`, and only when no association snapshot was captured. A captured timeout retains its exact
connection/target marks and never cuts uncovered jobs. Already streaming jobs on other connections bypass this
unpublished floor. A late snapshot cannot undo a floor or cover post-cutoff tickets.

The first barrier encounter starts one shared **250 ms** budget across wait, routing and final-enqueue retries.
Overlapping covering pending stops do not restart it. `wait_budget` applies only while a stop still covers the
job: an unknown scope may cover every pre-cutoff job; a captured scope covers its retained targets/destination.
Marks and floors are checked first, so a known covered job logs `stopped`. With no covering pending stop, the job
may play even after that budget deadline. An admitted check clears its deadline, expired flag and timer under
the lock, so a renderer's later first frame receives a fresh barrier budget if another stop intervenes.
Admissions recheck all marks after waking. Cancellation and expiry pruning remove/resume registered waiters
independently of whether their job record remains; all continuations resume outside the queue lock.
No actor or cooperative thread is blocked while waiting, and no cross-process wall clock is involved.

The target is checked before routing, so a disconnected text pin cannot turn a stop skip into a routing refusal.
Ordinary routing still resolves request owner, existing text/first-frame pin, current last input, single selector
or ambient owner. Admission and final enqueue skip a ticket at or below the resolved connection's mark, the frame
target's mark, or the global eviction floor. This prevents a pin eviction or reconnect from reviving pre-stop audio.
A ticket greater than all three marks can play immediately, including after reconnect. A shared target stop covers queued replies owned
by another connection for that target. Playback stops leave delivered text/cards intact and do not withdraw the
request. Privacy retains its existing request drop and delivery hold.
A separate outstanding-job record retains ticket position, reply id, target, delivered-text connection (once known),
and whether first audio publication succeeded. Successful text delivery records that destination independently of
the 64-pin cache. Stops also mark every target whose outstanding text destination was that connection, even if
its pin was evicted before the stop. **Q and L:** The record holds at most 1024 reservations. Capacity refuses
new reservations without evicting an older job or raising a floor. Each reservation expires 26 hours after
issuance (the CLI's 24-hour queue bound plus two hours for streaming/cleanup); access prunes expired jobs without
raising a floor. Check/publish of an issued ticket whose record vanished returns an audio-only `expired` skip,
including disappearance during routing. Text/cards and request ownership remain intact.

Skipped tickets, cancellation, completed final publication and explicit release remove reservations and destination
associations. The CLI releases its reservation on refused text, request-bound give-up, exhausted retry windows,
renderer/audio bounds, cancellation (including SIGTERM and wall-clock cancellation), and normal completion.
SIGKILL or a lost cleanup transaction relies on expiry. A transient mid-stream publication failure preserves a
terminal-only reservation: only that reply's own two-byte final marker may pass ordinary routing/policy gates;
no further audio data is accepted (`terminal_only` skip, retaining the terminal reservation). The transient
failure logs `reply_audio_refused reason=publication_failed request=<UUID|none> ticket=N`; a later data attempt
logs `reply_audio_skipped reason=terminal_only request=<UUID|none> ticket=N`. Final publication or release retires it.
Target marks apply only before the first successful
audio enqueue. Another connection's already streaming reply continues to its final frame; its own connection
marks and in-flight retirement retain the existing `stop_playback` behavior.

The daemon emits the content-free event
`reply_audio_skipped reason=<stopped|wait_budget|expired> request=<UUID|none> ticket=N`.
Capacity logs `reply_audio_refused reason=capacity request=<UUID|none>`. Every audio skip/refusal keeps text/cards. A bounded cache of 256 skipped ticket positions
deduplicates probe/publish and mid-stream terminal-marker attempts; after cache eviction a repeated old request
may log again. Actual queued publication keeps the ordinary audit-before-delivery boundary and records refused
delivery codes for doctor counts. A missing target is refused before any `pushed` audit entry.

A daemon restart makes a waiting job's ticket stale: the CLI exits with an error (exit 1 in the waitable job), keeps
its already delivered text/card, sends no audio and produces no `reply_audio_skipped` event. It does not retry with
an unguarded frame or silently reinterpret a refusal as a stop.

The job handles the skip as success and
writes `reply audio skipped after a stop` to stderr. As with other post-readiness diagnostics, a detached job's
stderr follows its existing redirection to `/dev/null` after releasing its caller; the daemon event is the durable
observable diagnostic. There is no terminal audio marker for a job whose audio never started.

During install/restart version skew, legacy unticketed behavior is selected only for a zero-delivery **enqueue**
response with code `decodeFailure`, error exactly `reply refused [decodeFailure]: frame decode failure`, and an
**absent** `replyAudio` field. At both `f3f97bc7` and `cc36af90`, the older endpoint routes the unrecognized
`kind: "reply-audio"` (enqueue, check or publish) through `submitReply`, where Frame decoding produces that exact
coded refusal. The queue-aware endpoint always includes `replyAudio` in queue responses, including decode
refusals, so it cannot produce the legacy signal for a valid queue request. Explicit null does not count as absence.
The CLI logs `reply_audio_queue unsupported` once to stderr and keeps the ordinary audio turn lock. Missing or
malformed acknowledgements, inexact/uncoded decode errors, connection failures, timeouts and stale tickets remain
fail closed. The exact old signal during check or publication also remains fail closed: only initial enqueue can
negotiate legacy operation. Legacy fallback cannot provide queue-stop ordering.
Foreground (non-detached) jobs take no ticket and therefore have no queued-audio guarantee. A device
`voice_stopped` ignored with `reason=no_active_stream` marks nothing.
