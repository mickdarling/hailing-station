# Spoken handover between devices: design spike

Part of #714. **Proposed, not built.** Nothing here is shipped or validated on a device. It's left open for Mick's decisions, below.

## Goal

The owner says "I'm moving to the iPad" (or "I'm switching devices"), and the conversation follows cleanly. Listening stops on the device that heard it, and the next device the owner picks up carries on, without a "busy" refusal and without losing the thread. Today the same move needs a tap on the new device's "Listen here", and the old device only learns it lost the stream when its next segment is refused.

## What exists today (main)

- **Take-over (#366, #368, #372):** the most recent device to *start* a stream holds it. `AmbientAudioGate.start()` (`Sources/HailDaemonKit/Listener/AmbientAudioGate.swift`) ends the old stream as superseded once the new one's first segment passes every check.
  - The new device gets `ambient_moved_here`, if it advertises `ambient_takeover`.
  - The old device gets `not_allowed` "ambient moved to <kind>", but only on its next segment.
- **No stealing back (#373):** an automatic retry's start (`resume: true`) is refused while another connection holds the stream.
- **Device identity:** the host knows each connection by a fresh UUID and a device class from the hello (`phone`, `pad` or `mac`; `HelloInfo.deviceKind`). Every app sends the same device name, so **two iPads can't be told apart**; only the connection is unique.
- **Owner-only spoken commands:** voice mute (#551), media mode and destination notes are matched in `RightyoInputConsumer`. On an *enrolled* session a command counts only when both RightyO's transcript role and its attention record say "owner", and either can demote it. Destination notes require enrolled plus owner. A guest's phrase passes to the agent as an ordinary request.
- **State on take-over (#425, open, not built):**
  - **Thread:** the conversation log is device-side only, in memory, keyed by host and target.
  - **RightyO:** a fresh child starts for the new stream, with no context carried.
  - **Selection:** per connection; the new device must already select the target.
  - **Last-input ledger (#370):** host-side, keyed by target, not moved.
  - **Media mode:** keyed by connection, dropped when the stream stops.
  - **Buffered audio:** never moves.
- **Acknowledgement clips:** reserved keys such as `confirm-muted` play only to a connection that still selects the target (`acknowledgeAmbient`).

## Recommended design

### 1. The cue never turns a microphone on

A spoken command can stop listening **here** and open a **handover window**. It never starts capture on another device. Pickup stays a deliberate act on the device the owner is now holding: a tap on "Listen here", or a start the owner already set to happen (for example, opening the app with ambient on). This bounds the cue's worst case to what voice mute can already do (listening stops on this device) and rules out remote microphone activation by voice, recorded or synthesised.

### 2. Recognising the command

- **The matcher:** a new `VoiceHandover.command` in the host's `RightyoInputConsumer`, beside `VoiceMute`. It uses the same candidate stripping (greeting, addressing name, "please"). A small fixed phrase set: "I'm moving to (the) <device>", "switching to (the) <device>", "I'm moving devices", "hand over (to the) <device>". `<device>` maps to `phone`, `pad` or `mac` by a small table: iPhone, phone, iPad, pad, tablet, Mac, laptop, computer.
- **The owner gate is stricter than mute's.** It requires an **enrolled** session, and both RightyO records saying owner, the same as destination notes. On an anonymous session the phrase is not a command; it passes to the agent as today. A handover moves where replies and the conversation go, so it shouldn't rest on "any voice".
- **Echo:** host-spoken phrases are already held as echo (`HostPhrases`), so a reply that says "moving to the iPad" can't trigger it.

### 3. On the device that heard it

1. The host ends that device's stream as `handedOver`, a new end reason next to `superseded`, so the old device's automatic restart is not attempted. The existing resume rule (#373) also refuses one.
2. The host sends that connection a new control, `ambient_handover { to: <kind>?, window_seconds }`, only to a device advertising a new capability, `ambient_handover`. An older device sees only the stream ending, as today.
3. A reserved clip, `confirm-moving`, plays on the old device before the stream ends: for example, "Moving. Pick up on the iPad." The device shows "Moved: listening paused here".

### 4. The handover window

- **Host state:** `PendingHandover { target, fromConnection, preferredKind?, expiresAt, carried }`, in memory only, one at a time. It defaults to 2 minutes (Mick to confirm) and is configurable in `host.json`. A new handover replaces an older one.
- **Pickup:** the first ambient start for the same target, from a **different connection**, before `expiresAt`, takes the window.
  - The start still passes every existing check: a selected target, its shape, the daemon-wide rate.
  - If `preferredKind` is set and the picking device is a different class, it still picks up, and the host says so once ("Picked up on the phone, not the iPad").
  - The two iPad case can't be pinned to one device, since devices of one class share a name. Naming a specific device would need per-device names first, which is a separate issue.
- **What the window adds over plain take-over:**
  - the old stream has already ended, so there's nothing to supersede and no "busy";
  - the carried state (below) is applied;
  - the new device gets `ambient_moved_here { from, handover: true }`.
- **Expiry:** nothing is lost. The thread stays where it was, and the next start behaves exactly as today. No clip plays on expiry, since no device may be listening to hear it.
- **Cancel:** the owner saying "stay here", or starting listening again on the old device within the window, cancels the handover. Starting again there is an ordinary start from the same connection.

### 5. What moves

| State | Where it lives today | On pickup |
|---|---|---|
| Media mode | host, per connection | copied to the new connection |
| Selected target | per connection | the new device must already select it, unchanged; no remote selection |
| Last-input ledger (#370) | host, per target | re-pointed at the new connection, so a reply to a request made on the old device lands on the new one |
| In-flight reply audio | routed by `ambient_owner` | follows the new owner automatically once the stream moves; a reply mid-stream finishes where it started |
| RightyO context | per child, not carried | the last N turns' text seeds the new child, which is #425's job; until then, nothing |
| Conversation thread (on screen) | device only, in memory | not moved by this issue. The new device shows its own log. A host-side copy, owner-private, memory-only and expiring with the window, belongs with #425 or #265 |
| Buffered audio | device or child | never moves, by design: audio stays where it was heard |

### 6. Security of the cue

- **Who:** enrolled owner only, with both RightyO records agreeing. Guests and anonymous sessions can't hand over.
- **What it can do:** stop listening on one device and open a time-limited window for the same target. It can't start a microphone, select a target, change routes or reach another host.
- **Replay or synthesis:** a recording or clone of the owner's voice that passes speaker ID can, at worst, stop listening and open a window. That's the same exposure as voice mute today, and the window does nothing unless the owner picks up a device in it.
- **Window abuse:** only a connection that selects the same target on the same host, already authorised through pairing, can pick up. The window adds no new authority; it only skips the busy refusal and copies per-connection settings.
- **Logging:** the audit and diagnostics record the handover, its pickup or expiry, and the device classes involved, never transcript text.

## Proposed slices (each small, default-off behind `voiceHandover` in `host.json`)

1. **Matcher and gate:** `VoiceHandover.command` and the enrolled-owner gate, with tests only. The command is recognised and logged, and does nothing yet.
2. **Stop here:** end the stream as `handedOver`, play the `confirm-moving` clip, and keep the resume rule.
3. **The window:** `PendingHandover`, pickup by a different connection, expiry and cancel, plus `ambient_moved_here.handover`.
4. **Carry:** media mode and the last-input ledger re-pointed at the new connection.
5. **App:** the `ambient_handover` capability, the "Moved" state and the "Picked up" confirmation, on iPhone, iPad and Mac.
6. **#425 tie-in:** seed RightyO from the last turns. That's tracked there.

Slices 3 and 5 change the protocol and need `protocol:compatible`. Any slice touching `Sources/HailDaemonKit/Listener/` is security:critical.

## Open decisions for Mick

1. **Phrases:** the fixed set above, or should any addressed sentence containing "moving" or "switching" plus a device word count?
2. **The old device:** stop listening entirely (recommended), or mute until pickup?
3. **Window length:** 2 minutes? Should it be configurable?
4. **A clip on the old device:** "Moving. Pick up on the iPad." Wording?
5. **Naming a device of the same class** (two iPads): needs per-device names. Worth an issue?
6. **The conversation on screen:** should the new device show the recent thread? That's a host-side copy, and #425 or #265 territory.
7. **Anonymous sessions:** keep handover enrolled-only (recommended), or allow it like mute?
