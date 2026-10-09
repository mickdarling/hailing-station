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

## Stopping reply playback (#309)

`{"command": "stop_playback"}` is a host-to-device control command that tells the device to stop reply audio
at once and drop that host's queued replies. The device's player is shared, so whatever it was playing stops too,
and another host's queued replies then play. It carries nothing else: the decoder and the schema refuse any other
payload key, and it grants no authority. A device advertises `stop_playback` (`PlaybackStop.capability`) in its
`hello` when it can act on the command. A host never sends it to a device that did not advertise it, because an
older device refuses an unknown command as malformed. The host sends it when a RightyO `dismiss` has `playback`
in its scope, and refuses the rest of every reply that was mid-stream on that connection whether or not the device
advertised the command ([rightyo-input.md](rightyo-input.md)).

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
   record is older than 10 minutes), the single-terminal rule applies unchanged: the one device selecting the
   target, else `noRecipient` or `notUniqueRecipient`.

Steps 2 and 3 run only on a host started with `--single-terminal-reply-fallback`, which `scripts/host.sh` passes
when `host.json` sets `singleTerminalReplyFallback`. Every frame of one request-less reply goes to the device that
received its first frame, or is refused; a reply never splits across devices.

Sessions need no reply instruction for this. Typed text gets no footer and no reference; ambient prompts keep their
existing [reply block](rightyo-input.md#the-reply-block). The wire format is unchanged. Details and limits:
[request-origin-routing.md](request-origin-routing.md#unified-reply-routing-the-last-input-device-370).
