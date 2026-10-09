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

## Ambient take-over (#366)

The most recent device to start ambient listening on a host takes it over. There is no "ambient busy" refusal.
The wire carries two things for this, and each names a device only by its class (`phone`, `pad` or `mac`,
`AmbientTakeOver.deviceKinds`), never by its name:

- `hello.deviceKind` (optional) is the device's own class. An older device leaves it out. A host keeps a value
  only when it matches the vocabulary byte for byte; any other value decodes as absent and never fails the hello.
- The previous device's next segment is refused with `not_allowed` and the message `ambient moved to <class>`,
  or `ambient moved to another device` when the new device did not give a class. It is an ordinary
  `ambient`-prefixed refusal, so an older device stops as it did before. A newer device shows it as a move, not as
  an error (`AmbientTakeOver.moved(_:)`).
- `{"command": "ambient_moved_here", "from": "<class>"}` tells the new device that its stream took over from a
  device of that class. `from` is optional. The decoder and the schema refuse any other key and any value outside
  the vocabulary. The command grants no authority. A device advertises `ambient_takeover`
  (`AmbientTakeOver.capability`) in its `hello` when it can act on the command, and a host never sends the
  command to a device that did not.
