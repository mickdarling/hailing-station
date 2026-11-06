# Connected proactive update cards

Part of #609. This candidate receives the existing capability-gated `session_update` frame in the Apple device
connection and places a card in its exact target's conversation. The display label comes from the frame's session
label; the host supplies that label from its live target registry. The device never guesses a target from a name.

The device advertises `session_update`. A host that did not advertise the same capability cannot send updates.
A card must belong to the current ready socket generation and an exact live target in that connection's listing.
A stale or disconnected socket, missing/unknown target, confirmed privacy, pending privacy-on, or an in-progress
transport restore suppresses the card. These checks supplement the host's delivery policy; they do not enroll or
authenticate a device and do not implement the proposed approved-key or APNs ladder.

A card retains the update UUID, endpoint, target, session label, priority, words, and optional unspoken Markdown.
Its receipt key includes the endpoint and update UUID. Recent duplicate receipts survive reconnects in memory;
both receipt history and visible conversation history are bounded to 200 entries. Duplicates do not rewrite a
card. A card never satisfies an outstanding paste/request or consumes a named-session reply placement.

The app labels cards as session updates, including in their own thread and in VoiceOver. They do not acquire
unrelated playback controls. No device synthesizer, speech request, playback interruption, microphone change,
local notification, APNs request, host/device configuration, installation, or release is added by this slice.
Spoken update delivery remains a separate host-rendering and existing-player integration requirement.

## Synthetic verification

- `SessionUpdateConversationTests`: injected date, target/thread attribution, metadata, per-endpoint UUID dedup,
  bounded receipts/history, and independence from pending paste and addressed reply state.
- `HostConnectionSessionUpdateTests`: actual scripted negotiated socket delivery, duplicate-frame receive barrier,
  playback-ingress exclusion, capability failure, exact current-generation/ready/target admission, confirmed privacy,
  and a pending privacy-on while the socket send is suspended.

These are authored synthetic tests. Their executed command/results are recorded in the implementation PR.
No physical device, audible output, APNs delivery, deployment, or shipped behavior is proved here.
