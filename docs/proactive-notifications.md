# Proactive notifications

[#609](https://github.com/mickdarling/hailing-station/issues/609) lets a session tell the owner about finished work,
a needed decision or a failure without a pending request. Mick decided on 2026-10-22 that these reach his phone
through our own Hailing Station app, by Apple Push Notification service (APNs) under his own developer team. No
third-party relay is involved, so Zulip's push bouncer is out. This is the design for review. **Nothing here is built
beyond what Status lists**, and implementation waits for Mick's review of the open questions.

## Status

| Piece | State |
| --- | --- |
| Held-update queue and policy: per-session rate limit, quiet, expiry | Merged (#617, #629–#631). Not deployed. |
| `haild notify` and the `kind: "update"` request on the reply socket | Merged (#643, #679). Not deployed. |
| `session_update` host-to-device frame and its capability | Merged (#624). Nothing sends it yet. |
| Showing an update card in the app | Local branches from 2026-10-20, never pushed or reviewed. |
| Draining held updates to a device, speaking, privacy, quiet hours, APNs | Proposed here. |

Today every update is held (`LocalSessionUpdate.swift`), `drain` has no caller, and an `action` update only prints
`push: suggested` so the session can raise its own notification. `scripts/host.sh` does not pass
`--session-updates` yet.

## Delivery ladder

An update is decided once, when it is submitted and again when the queue drains. The first rule that applies wins.

1. **Private:** while privacy mode is on, nothing is spoken, shown or pushed. The update stays held (see open
   question 2).
2. **Quiet:** quiet (`haild notify quiet on`) or quiet hours: held, never pushed. An `action` update is shown on a
   connected device without sound.
3. **`info`:** always held. It drains at the next natural pause on a listening device, at the next interaction ("You
   have 3 updates"), or when the owner asks for updates. It is never pushed.
4. **`action`, a listening device not in media mode:** spoken now in the house voice and shown as a card. This uses
   the existing `listeningDevice` decision, which is nulled today.
5. **`action`, a connected device that advertises `session_update`:** a `session_update` frame. The app shows the card
   and, when it is not in front, posts a local notification. The app is often connected in the background through
   its audio keepalive (#282, #352), so most updates never need APNs.
6. **`action`, no connected device:** an APNs push to the owner's approved devices. The update is still held and
   shows as a card on the next connection. The `update` UUID stops a device showing it twice.

## How a session triggers one

No new command. `haild notify <target> --say <text> [--card <text>] [--action]` stays the only entry point. It uses
the owner-only reply socket, and its session label comes from the live target registry, never from caller text
(#371). The answer gains outcome tokens for what this design adds: `pushed`, `shown`, `spoken`, `held: private`,
`held: quiet`, `push: no_device` and `push: failed`. `push: suggested` goes away once APNs is wired. There is no
`--speak` flag: speaking is the host's decision by the ladder, so a session cannot shout through quiet or privacy.

`haild notify quiet off` is added for the owner. The rule "a session cannot turn quiet off" holds only in spirit,
because any local process can reach the socket (the same cooperative limit as today, `docs/host-operations.md`).

## APNs from haild

- **Auth:** token-based. A `.p8` key from Mick's developer account, with the APNs service enabled, signs an ES256
  JWT. The JWT is refreshed between 20 and 50 minutes old, which is inside Apple's rules. One key serves every app
  under the team and never expires. The existing App Store Connect API key is a different key type and is not reused.
- **Where the key lives:** `~/.config/hail/apns/` (0700), holding `key.p8` (0600) and `apns.json` (0600) with the key
  ID, team ID and topic. It is owner-checked with no symlinks, like `PolicyFile`. `host.json` gains
  `"apns": "<absolute path to apns.json>"`, which `host.sh` passes as `--apns <path>`. The key ID, team ID and token
  are never printed, logged, audited, put in diagnostics or committed. `.gitignore` already covers `*.p8`.
  `haild doctor` reports `apns: configured | missing | unreadable` only. Mick creates the key in the developer portal
  and places the files himself. That is an operator step, never done from a transcript.
- **Transport:** HTTP/2 to Apple's production host for TestFlight and App Store builds, or the sandbox host for
  debug builds. Each token is stored with its environment. Uses `URLSession`, with no new dependency.
- **Payload, minimal by default:** `aps.alert.title` is the session label and `body` is the update text (see open
  question 1), plus `thread-id` = session, `sound`, and `interruption-level: active`. A `hail` object carries `update`
  (UUID), `session` and `priority` only. The card text is never pushed; it arrives over the LAN connection.
  `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration` = the update's expiry, and `apns-collapse-id` =
  the update UUID.
- **Failures:** a `410 Unregistered` or `400 BadDeviceToken` removes that token. A `429` or `5xx` backs off and keeps
  the update held. Failures are audited as reason tokens only.

## Owner devices only

The personal-terminal listener has no peer authentication (`docs/security.md`). Anyone who reaches the bind address
could otherwise register a token and receive the owner's updates. So registration is never trusted on its own:

1. The app gets an APNs token, then sends `register_push {install, token, environment}` over its connection.
   `install` is a random UUID the app keeps in its Keychain, a stable identity that `connectionID` is not.
2. haild stores it as **pending** in `~/.config/hail/push-devices.json` (0600), with the self-asserted device name and
   kind and a short fingerprint of `install`.
3. The owner approves it from the host over the owner-only socket: `haild push devices` lists pending and approved
   entries by name, kind and fingerprint, and `haild push approve <fingerprint>` or `haild push revoke <fingerprint>`
   changes one. The app shows the same fingerprint, so the owner can match them.
4. Only approved tokens are pushed. A new token for an approved `install` (Apple rotates tokens) replaces the old one
   without a new approval. A new `install` always starts pending.

This follows the voice-routing rule "never auto-trust a discovered session". Tokens are device identifiers, so they
are never committed or logged (`docs/security.md`).

## Suppressed while private

Privacy mode (#735, Part 10's stack) is in memory and per connection, and it is cleared when that connection ends.
A push goes out exactly when no device is connected, so there is no live privacy state to check at that moment.
Proposed rule: haild keeps one in-memory **owner private** flag, set when any connection turns privacy on. It is
cleared only when privacy is turned off, or when haild restarts. Ending a private connection by dropping it does not
clear it, so a phone that drops off while private never starts receiving pushes. The flag holds no content, which
fits "privacy keeps nothing". The owner rules (S-5) apply as well: nothing proactive while private.

## Rate limits and quiet hours

- The existing per-session limit stays: 6 updates an hour, 5 held, 20 in all, 4-hour lifetime.
- **Pushes:** at most 4 an hour for the whole host. Beyond that they collapse into one push, "N updates waiting",
  with the session labels only.
- **Quiet hours:** `SessionUpdateQuietHours` already exists. `host.json` gains `"quietHours": "22:00-07:00"`, in
  the host's local time. During quiet hours nothing is pushed or spoken. iOS Focus also applies to pushes, because
  they are not time-sensitive.
- Media mode keeps blocking speech and natural-pause drains, as it does today.

## What the app shows

- **Card:** a `session_update` becomes a conversation entry labelled with the session, like a reply from another
  session (#636), with the card as Markdown metadata that is never spoken (#606). It lands in that session's thread.
- **Notification:** title is the session label and body is the text, grouped by `thread-id`. Tapping it opens that
  session's thread. While the thread is on screen, the in-app card replaces the banner.
- **Speaking:** the app has no on-device speech and should not gain a second voice. An update is spoken only by the
  host's house voice, over an open connection, by rule 4. A push alone cannot speak, because iOS does not let a push
  start audio. When the app is connected in the background through its keepalive, rule 4 or 5 applies before APNs.
- **Settings:** a push on/off switch (it asks permission only when turned on), the device's fingerprint, and the
  approval state the host reports.

## Protocol shape

Each new message is a capability advertised in `hello`, so a host never sends a command a device did not advertise.
There is no version bump.

| Message | Direction | Capability | Fields |
| --- | --- | --- | --- |
| `session_update` (exists) | host to device | `session_update` | `update`, `session`, `priority`, `text`, `card?` |
| `register_push` | device to host | `push_registration` | `install` (UUID), `token` (hex), `environment` |
| `push_registration` | host to device | `push_registration` | `install`, `state`: `pending`, `approved` or `revoked` |

The APNs JSON is not a hail frame. It lives in a new `Notify/` type in HailDaemonKit, with schema, fixtures and docs
in `docs/reply-protocol.md`.

## Files this touches, and sequencing after Part 10

Part 10's privacy stack (#807, #808, #813, S-6) is changing `WebSocketListener*`, `HostSession`,
`HostReplyDelivery`, the RightyO input files, and `Control.swift`/`Schema.swift` (for `set_privacy`).

| Area | Files | Overlap |
| --- | --- | --- |
| Drain and deliver `session_update` (rules 3 and 5) | `Notify/*`, `LocalSessionUpdate.swift`, a new `WebSocketListener+SessionUpdate.swift` | **WebSocketListener**: the state for draining, and finding the peer, as `+MediaMode` does |
| Privacy and quiet in the audience (rules 1 and 2) | `LocalSessionUpdate.swift`, `SessionUpdate.swift` | **WebSocketListener**: privacy must be readable through `AmbientListenerWiring`, like `mediaMode` |
| Speak an `action` update (rule 4) | the reply audio path | **HostReplyDelivery**: requestless delivery must honour the privacy hold |
| Receive `register_push` | a new HostSession command case | **HostSession**: decoding device commands |
| Protocol messages | `Control.swift`, `Schema.swift`, fixtures | **Control.swift and Schema.swift**: S-6a adds `set_privacy` there |
| APNs client, key, token store, `haild push` | new `Notify/APNs*.swift`, `Sources/haild/PushCommand.swift`, `host.sh` | None |
| App: card, local notification, registration, settings | `HailApp.swift`, `HostConnection+Protocol.swift`, `HostConnectionStore.swift`, chat views, `project.yml` | Possibly Part 10's privacy-switch app branch, in the store |

So everything except the APNs client and the CLI waits for Part 10's stack to merge.

## Slices

1. **Updates reach a connected app:** revive the local card branches; the host drains to devices that advertise
   `session_update` (rules 3 and 5); a local notification when backgrounded. After Part 10.
2. **Privacy and quiet hours in the ladder** (rules 1 and 2), with the owner-private flag. After Part 10.
3. **Speak `action` updates on a listening device** (rule 4). After Part 10.
4. **APNs sender:** key files, JWT, HTTP/2, `haild doctor`. Synthetic tests against a local HTTP/2 stub only; no
   real push leaves the host until Mick is listening. This slice can start now.
5. **Registration and approval:** `register_push`, the pending/approved store, `haild push`, and the app's token,
   entitlement and settings. `project.yml` gains `aps-environment` and the `remote-notification` background mode.
   The App ID needs the Push capability, which Xcode's automatic signing may add, and a new TestFlight build is
   needed with Mick listening.
6. **The Mac app:** pushes need signing, a provisioning profile and the macOS entitlement, which the direct-build Mac
   app has none of. Deferred. The Mac is usually connected over loopback, so rule 5 covers it.

## Open questions for Mick

1. **Push text:** show the update's words in the push (it passes through Apple, encrypted in transit but readable by
   APNs infrastructure), or a content-free "Jarvis has an update" with the words only over the LAN? The default
   proposed here is the words for `action` only; content-free is one switch away.
2. **While private:** keep updates held and deliver them after privacy ends, or drop them? Held updates are agent
   output, not anything heard, so keeping them does not break "privacy keeps nothing". Proposed: keep them.
3. **The owner-private flag** outliving a dropped connection (above). Is that the semantics you want? Part 10 owns
   the privacy design.
4. **Quiet hours:** what window, and should any `action` break through (time-sensitive, which needs an
   entitlement)? Proposed: no breakthrough.
5. **APNs key:** you create one in the developer portal and place it under `~/.config/hail/apns/`. Is that the right
   home, or would you rather use the Keychain?
6. **Mac pushes:** deferred as above. Is that fine?

## Verification

This is a design document. It records no runtime behaviour. The current state it describes was read from `main`:
the merged #609 queue, `haild notify` and the `session_update` frame; the absence of any APNs code; the app's
single local notification; and the empty iOS entitlements.
