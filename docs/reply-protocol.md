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
payload's cap. The decoder and the schema refuse any other key. The command grants no authority, and a host refuses
it from a device. A device advertises `ambient_heard` (`AmbientHeard.capability`) in its `hello` when it can show the
text, and a host never sends the command to a device that did not. The host never logs the text.

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
