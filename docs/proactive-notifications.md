# Proactive notifications

[#609](https://github.com/mickdarling/hailing-station/issues/609) lets a session tell the owner about finished work,
a needed decision or a failure without a pending request. Mick decided on 2026-10-22 that these reach his phone
through our own Hailing Station app, by Apple Push Notification service (APNs) under his own developer team. No
third-party relay is involved, so Zulip's push bouncer is out. This is the design for review. **Nothing here is built
beyond what Status lists**, and implementation waits for Mick's answers to the open questions.

## Status

| Piece | State |
| --- | --- |
| Held-update queue and policy: per-session rate limit, quiet, expiry | Merged (#617, #629–#631). Not deployed. |
| `haild notify` and the `kind: "update"` request on the reply socket | Merged (#643, #679). Not deployed. |
| `session_update` host-to-device frame and its capability | Merged (#624). Nothing sends it yet. |
| Showing an update card in the app | Local branches from 2026-10-20, never pushed or reviewed. |
| Owner devices, draining, speaking, privacy, quiet hours, APNs | Proposed here. |

On `main` today:
- Every update is held: `listeningDevice` is nulled in `LocalSessionUpdate.swift`, and `SessionUpdateQueue.drain` has
  only test callers.
- An `action` update prints `push: suggested` only when a target device is *connected* and quiet is off
  (`SessionUpdateQueue.push`, `NotifyCommand.swift`). Nothing is pushed when no device is connected. This design
  reverses that (rule 7 below).
- `scripts/host.sh` does not pass `--session-updates`.
- Privacy is only duck mode, which is per connection with a one-hour auto-end. The privacy mode this design defers to
  (per connection, in memory, never auto-ending, with replies dropped) is Part 10's open #807, #808 and #813.

## Owner devices

The personal-terminal listener has no TLS and no peer authentication (`docs/security.md`). Anything sent over it,
including any identifier a device presents, can be read by another device on the network. So a device is never
trusted for what it claims. It is trusted only for holding a private key the owner approved.

1. **Device key:** on first use the app makes a P-256 key pair in the Secure Enclave (iPhone, iPad) or the Keychain
   (Mac). The private key never leaves the device.
2. **Challenge:** when both sides advertise `owner_device`, haild sends `device_challenge {nonce}`, with a fresh
   32-byte nonce for each connection. The app answers `device_proof {key, signature, token?, environment?, name,
   kind}`. The signature covers the nonce, the token and the environment. `token` is the APNs token, present only
   when pushes are on.
3. **Fingerprint:** the SHA-256 of the public key, shown as 16 hex characters in four groups (64 bits). An attacker
   cannot choose it without the private key. The name and kind are shown as **unverified** labels.
4. **Approval:** a key starts pending.
   - The owner runs `haild devices` and then `haild devices approve <fingerprint>` over the owner-only socket.
   - `approve` needs the full fingerprint, refuses one that matches more than one entry, and works only while that
     device is connected. The app shows its own fingerprint, so the owner compares them on both screens.
   - `haild devices revoke <fingerprint>` puts the key on a revoked list; it never becomes pending again.
5. **Per connection:** a connection is an **approved device** only after a valid proof from an approved key on that
   connection. Token rotation needs a proof from the same key, so nobody without the private key can replace the
   token or remove it.
6. **Store:**
   - Pending entries live only in memory: at most 8, each expiring after 24 hours, one proof per connection.
     Token, environment, name (at most 64 characters) and kind are validated.
   - Approved and revoked keys, with each approved key's current token, go to `~/.config/hail/devices.json` (0600)
     under the `PolicyFile` checks: owner, 0700 parent, no symlinks.
   - Keys and tokens are never logged or committed.

This is the same rule voice routing follows (`docs/voice-routing.md`): a discovered peer is never trusted on its own.
It does not make the listener confidential. A `session_update` frame to an approved device can still be read on the
wire until the listener has TLS, the same limit every reply has today (`docs/security.md`).

## Delivery ladder

The host decides each update when it is submitted, and again whenever the queue drains or a send is retried. The
first rule that applies wins. Every rule that delivers means an **approved** device. An unapproved connection
receives nothing proactive and does not count as connected.

1. **Private:** while the owner is private (below), the update is **dropped**. Nothing is spoken, shown or pushed,
   matching #813's "dropped, not paused" for replies. `haild notify` answers `dropped: private`.
2. **Quiet** (`haild notify quiet on`) **or quiet hours:** held, never spoken or pushed. A connected device gets the
   card without sound.
3. **`info`:** held. It drains at the next natural pause on a listening device, at the next interaction ("You have
   3 updates"), or when the owner asks. It is never pushed.
4. **`action`, a listening device not in media mode:** spoken now in the house voice, plus the card.
5. **`action`, a connected device with the app in front and not muted:** spoken now through the app's reply
   player, plus the card. The app reports `foreground` changes, and the host speaks with the same host-rendered audio
   it uses for replies. This covers Mick's "spoken clip when the app is foregrounded".
6. **`action`, a connected device otherwise:** a `session_update` frame. The app shows the card and posts a local
   notification. The app is often connected in the background through its audio keepalive (#282, #352), so most
   updates never need APNs.
7. **`action`, no connected approved device:** an APNs push to every approved device with a token. The update stays
   held until its expiry and shows as a card on the next connection; the `update` UUID stops it showing twice.

## How a session triggers one

No new command. `haild notify <target> --say <text> [--card <text>] [--action]` stays the only entry point. It uses
the owner-only reply socket, and its session label comes from the live target registry, never from caller text
(#371). The answer gains outcome tokens: `spoken`, `shown`, `pushed`, `held: quiet`, `dropped: private`,
`push: no_device` and `push: failed`. `push: suggested` goes away. There is no `--speak` flag: speaking is the
host's decision, so a session cannot speak through quiet or privacy. `haild notify quiet off` is added; any local
process can reach the socket, so quiet stays a cooperative control (`docs/host-operations.md`).

## Owner private, across disconnects and restarts

A push goes out exactly when no approved device is connected, so there is no live privacy state to check at that
moment. Proposed in-memory rule, with no state file, to stay compatible with #813:
- **Set** when any approved device turns privacy on.
- **Cleared** when that device turns privacy off, or when an approved device connects or reconnects and reports
  privacy off. Under #813 a reconnect starts public, so this matches Part 10's semantics.
- **At haild start, set.** Pushes stay off until an approved device has connected since the start and reported
  privacy off. A restart while the phone is away and private therefore never starts pushing.
- A dropped private connection does not clear it.

Part 10 owns privacy, so this needs their sign-off (open question 3).

## APNs from haild

- **Key:** a token-based `.p8` key from Mick's developer account with APNs enabled, signing an ES256 JWT that is
  refreshed between 20 and 50 minutes old. Apple's newer team-scoped keys are restricted to either sandbox or
  production. So the host uses one **production** key, which serves TestFlight and App Store builds. Debug builds
  (sandbox tokens) get no pushes unless a second, sandbox key is configured. A token whose environment doesn't match
  a configured key is refused at registration.
- **Files:**
  - `host.json` gains `"apns": "<absolute path to apns.json>"`, which `host.sh` passes as `--apns <path>`.
  - `apns.json` (0600) holds the key ID, team ID, topic and environment.
  - `key.p8` (0600) must be its fixed sibling in the same directory.
  - The owner, 0700-parent and no-symlink checks apply to whatever directory `--apns` names, not only a default.
  - The JWT and key are never printed, logged, audited or committed (`.gitignore` covers `*.p8`).
  - `haild doctor` reports `apns: configured | missing | unreadable`.
  - Mick creates the key and places the files himself. That is an operator step, never done from a transcript.
- **Transport:** HTTP/2 to Apple's production host via `URLSession`, with no new dependency.
- **Payload:** `aps.alert` with a title (the session label) and a body (see open question 1), plus `thread-id` (the
  session), `sound` and `interruption-level: active`. A `hail` object carries only `update`, `session` and
  `priority`. Card text is never pushed.
- **Headers:**
  - `apns-push-type: alert` and `apns-priority: 10`.
  - `apns-expiration`: the update's expiry, converted from its monotonic deadline to wall-clock seconds at send time.
  - `apns-collapse-id`: the update UUID, so a retried send replaces rather than duplicates.
- **Failures:**
  - `410` (Unregistered, ExpiredToken) or `400 BadDeviceToken`: remove that token and keep the key's approval. The
    device registers a new token on its next proof.
  - `403` provider-token errors: refresh the JWT once, never touch a device token, and report in `haild doctor`.
  - `429 TooManyProviderTokenUpdates`: a signing bug, reported, with no retry storm.
  - `429 TooManyRequests` and `5xx`: retry after 15 minutes. A retry re-runs the ladder, so privacy or quiet that
    began since cancels it.
  - Failures are audited as reason tokens only.

## Rate limits and quiet hours

- The existing per-session limit stays: 6 updates an hour, 5 held, 20 in all, 4-hour lifetime.
- **Pushes:**
  - At most 4 an hour for the whole host.
  - Beyond that, one summary push, "N updates waiting", with a fixed collapse ID so later summaries replace it.
  - The summary counts against the cap, and at most one is sent per hour.
- **Quiet hours:**
  - `SessionUpdateQuietHours` exists but is unwired. `host.json` gains `"quietHours": "22:00-07:00"` in the host's
    local time.
  - During quiet hours nothing is spoken or pushed.
  - Pushes are not time-sensitive, so iOS Focus also applies.
- Media mode keeps blocking speech and natural-pause drains, as it does today.

## What the app shows

- **Card:** a conversation entry labelled with the session, like a reply from another session (#636). The card is
  Markdown metadata that is never spoken (#606), and the entry lands in that session's thread.
- **Notification:** titled with the session and grouped by `thread-id`. Tapping it opens the thread. While that
  thread is on screen, the in-app card replaces the banner.
- **Speaking:** only in the house voice, rendered by the host and played by the app's reply player (rules 4 and 5).
  The app gains no on-device synthesiser and no second voice. A push can play its alert sound but cannot speak the
  update. If the app is alive in the background and connected, rules 4 to 6 apply before APNs.
- **Settings:**
  - a push on/off switch, which asks for permission only when turned on;
  - the device fingerprint;
  - the approval state the host reports.

## Protocol shape

New messages are capabilities. The host lists `owner_device` in its own hello, and a device sends nothing of this
kind to a host that did not list it. Likewise the host never sends a command a device did not advertise. There is no
version bump.

| Message | Direction | Capability | Fields |
| --- | --- | --- | --- |
| `session_update` (exists) | host to device | `session_update` | `update`, `session`, `priority`, `text`, `card?` |
| `device_challenge` | host to device | `owner_device` | `nonce` |
| `device_proof` | device to host | `owner_device` | `key`, `signature`, `token?`, `environment?`, `name`, `kind` |
| `device_state` | host to device | `owner_device` | `fingerprint`, `state`: `pending`, `approved` or `revoked` |
| `foreground` | device to host | `foreground` | `active` (bool) |

The APNs JSON is not a hail frame. It lives in a new `Notify/` type, with its schema in `docs/reply-protocol.md`.

## Files this touches, and sequencing after Part 10

Part 10's privacy stack (#807, #808, #813, S-6) is changing `WebSocketListener*`, `HostSession`,
`HostReplyDelivery`, the RightyO input files, and `Control.swift`/`Schema.swift` (for `set_privacy`).

| Area | Files | Overlap |
| --- | --- | --- |
| Device challenge and proof, approved state per connection | a new HostSession command case, a new `Listener/OwnerDevices*.swift` | **HostSession** decodes device commands |
| Drain and deliver `session_update` (rules 3 and 6) | `Notify/*`, `LocalSessionUpdate.swift`, a new `WebSocketListener+SessionUpdate.swift` | **WebSocketListener**: drain state and peer lookup, like `+MediaMode` |
| Privacy, quiet and owner-private (rules 1 and 2) | `LocalSessionUpdate.swift`, `SessionUpdate.swift` | **WebSocketListener**: privacy readable through `AmbientListenerWiring`, like `mediaMode` |
| Speak an `action` (rules 4 and 5) | the reply audio path | **HostReplyDelivery**: requestless delivery must honour the privacy drop |
| Protocol messages | `Control.swift`, `Schema.swift`, fixtures | **Control.swift and Schema.swift**: S-6a adds `set_privacy` there |
| APNs client, key files, device store, `haild devices` | new `Notify/APNs*.swift`, `Sources/haild/DevicesCommand.swift`, `host.sh` | None |
| App: key, proof, card, notifications, foreground, settings | `HailApp.swift`, `HostConnection+Protocol.swift`, `HostConnectionStore.swift`, chat views, `project.yml` | Possibly Part 10's privacy-switch app branch, in the store |

So everything except the APNs client and the device store waits for Part 10's stack to merge.

## Slices

1. **APNs sender:** key files and checks, JWT, HTTP/2, failure handling, `haild doctor`. Synthetic tests against a
   local HTTP/2 stub only; no real push leaves the host until Mick is listening. Can start now.
2. **Owner devices:** the challenge, proof, store and `haild devices`, plus the app's key, proof and fingerprint
   screen. After Part 10.
3. **Updates reach an approved, connected app:** revive the local card branches; drain to approved devices (rules
   3 and 6); a local notification when backgrounded. After Part 10.
4. **Privacy, owner-private and quiet hours in the ladder** (rules 1 and 2). After Part 10.
5. **Speak `action` updates** on a listening device or a foregrounded app (rules 4 and 5). After Part 10.
6. **Pushes end to end** (rule 7):
   - the app's token and entitlement;
   - `project.yml` gains `aps-environment` and the `remote-notification` background mode;
   - the App ID needs the Push capability (Xcode's automatic signing may add it);
   - a new TestFlight build, delivered with Mick listening.
7. **The Mac app:** pushes need signing, a provisioning profile and the macOS entitlement, none of which the
   direct-build Mac app has. Deferred. The Mac is usually connected over loopback, so rules 4 to 6 cover it.

## Open questions for Mick

1. **Push text:** what Apple sees, which is encrypted in transit but readable by APNs infrastructure.
   - Proposed default: the update's words for `action` pushes.
   - Content-free mode: the title "Hailing Station", the body "An update is waiting", and no session label in the
     title, `thread-id` or `hail` object. The words then arrive only over the LAN.
   - Either way, the existence and timing of pushes reach Apple.
2. **While private:** updates are **dropped**, to match #813. Would you rather they were held and delivered after
   privacy ends? Held updates are agent output, not anything heard.
3. **Owner-private:** set at start, set by any approved device going private, cleared by an approved device
   reporting public, and not cleared by a dropped connection. Is that the semantics you want? Part 10 owns the
   privacy design.
4. **Quiet hours:** what window? Should any `action` break through? A breakthrough would need the time-sensitive
   entitlement. Proposed: no breakthrough.
5. **APNs key:** you create a production key and place it with `apns.json` in a directory you choose. Is that
   right, or would you rather use the Keychain?
6. **Mac pushes:** deferred as above. Is that fine?

## Verification

This is a design document. It records no runtime behaviour. The current state was read from `main` at ea6a387:
- the merged #609 queue, `haild notify` and the `session_update` frame;
- `drain` with test callers only, and the connected-device push rule;
- no APNs code;
- the app's single local notification, the empty iOS entitlements and the unsigned Mac app;
- duck mode's one-hour auto-end.

The privacy semantics it defers to are from Part 10's open PRs #807, #808 and #813, not `main`.
