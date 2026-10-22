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
- Privacy is only duck mode, which is per connection and ends after a timeout: one hour by default, settable in
  `host.json` from 1 minute to 4 hours. The privacy mode this design defers to is Part 10's open #807, #808 and
  #813: per connection, in memory, never auto-ending, with replies dropped. A fresh connection starts public, and
  privacy does not survive a restart (#809 records "Privacy no longer survives a restart").

## Owner devices

The personal-terminal listener has no TLS and no peer authentication (`docs/security.md`). Anything sent over it can
be read, and frames can be injected, by someone on the network path. So a device is never trusted for what it
claims. It is trusted only for holding a private key the owner approved.

1. **Device key:** on first use the app makes a P-256 key pair in the Secure Enclave (iPhone, iPad) or the Keychain
   (Mac). The private key never leaves the device.
2. **Challenge:** haild lists `owner_device` in its hello. When the device has listed it too, haild sends
   `device_challenge {nonce}`, with a fresh random 32-byte nonce. The app answers `device_proof {key, signature,
   token?, environment?, name, kind}`.
3. **Encodings:**
   - `key`: the public key as an uncompressed X9.63 point (65 bytes), base64 in the frame.
   - `signature`: ECDSA P-256 over SHA-256, DER-encoded, base64.
   - `token`: the APNs token as lowercase hex. `environment`: `production` or `sandbox`. The two come together or
     not at all; a proof with only one of them is refused.
4. **Signed message:** each of these, in order, as a 4-byte big-endian length followed by its bytes, so no field can
   be moved into another:
   - the ASCII label `hail-owner-device-v1`;
   - the 32 nonce bytes;
   - the token's ASCII hex (empty when pushes are off);
   - the environment's ASCII (empty when pushes are off).

   A proof with no token clears the stored token: the app turned pushes off, and a relay cannot strip a token from a
   signed proof.
5. **Fingerprint:** the SHA-256 of the 65 key bytes, shown as 16 hex characters in four groups (64 bits). An attacker
   cannot choose it without the private key.
6. **Approval:** a key starts pending.
   - The owner runs `haild devices` and then `haild devices approve <fingerprint>` over the owner-only socket.
   - `approve` needs the full fingerprint, refuses one that matches more than one entry, and works only while that
     device is connected. The app shows its own fingerprint and its state, so the owner compares them on both
     screens. A device left `pending` after approval means the wrong row was approved.
   - The name and kind are shown as **unverified** until approval, then fixed. Later proofs cannot change them.
   - `haild devices revoke <fingerprint>` demotes the key's live connection at once, clears the key's privacy report,
     and puts the key on a revoked list. A revoked key never becomes pending again.
7. **Approved connection:** a connection becomes an **approved device** only after a valid proof from an approved key
   on that connection. Proofs from approved keys are never refused for a full pending store.
   - **One per key:** a newer proof demotes the older connection, which is told `device_state {state: "superseded"}`
     and not challenged again. If that was not the owner, it shows that another connection holds the device's key.
   - **Re-challenges:** every 10 minutes, and before rules 4 to 6 count the connection for an `action` (the ladder
     below).
   - **Timeout:** a connection that does not answer within 5 seconds is demoted (`device_state {state:
     "unanswered"}`). It is challenged once more 30 seconds later, and a valid answer restores it.
   - **Tokens** rotate only with a fresh proof answering a challenge.
8. **Pending store:** a pending entry exists only while its connection is open.
   - At most 8 at once; a ninth proof from a new key is refused with `device_state {state: "full"}`.
   - One pending proof per connection.
   - Token, environment, name (at most 64 characters) and kind are validated.
   - A peer holding 8 connections open can block a new device from enrolling until those connections close. This is
     an accepted nuisance: it blocks enrolment only, never an approved device.
9. **Saved store:** approved and revoked keys, each approved key's current token and fixed labels, are kept in
   `~/.config/hail/devices.json` (0600) under the `PolicyFile` checks: owner, 0700 parent, no symlinks. Keys and
   tokens are never printed, logged, audited, put in diagnostics or committed.

This is the same rule voice routing follows (`docs/voice-routing.md`): a discovered peer is never trusted on its own.

**Known limits until the listener has TLS:**
- Frames after a proof are not authenticated, so `presence` and privacy reports can be forged or replayed by
  someone on the network path.
- They can read every `session_update`, as they can read every reply today.
- While the owner's device is connected, they can relay its proof and the re-challenges to hold a connection of their
  own. That demotes the real device's connection, which is told `superseded`.
- `info` updates and cards drained without an `action` rely on the 10-minute re-challenge. For up to 10 minutes after
  the real device leaves, a relayed or half-open connection can still receive them.

An `action` re-challenges before it counts a connection. So once the real device has left, the relay can't answer,
the relayed connection is demoted, and the update falls through to a push. The design reduces these risks but does
not remove them. Removing them needs TLS with a pinned host key, which is out of scope here.

## Owner privacy

haild keeps, in memory only, each approved key's last privacy report.
- **Recording:** privacy turned on from any connection that has proven a key marks that key private. Privacy turned
  off counts only from that key's current approved connection. Privacy on an unapproved connection marks no key.
- **Clearing:** a key's private report clears only when that key turns privacy off, when that key's own device makes
  a fresh proven connection (which starts public, as under #813), or when the key is revoked. Another key connecting
  never clears it, and dropping a connection does not.
- **The owner is private** while any approved key's report is private. Then nothing proactive reaches **any**
  device: nothing is spoken, shown or pushed (rule 1). Mick's rule is that privacy means nothing reaches him until he
  ends it.
- **After a restart** there is no privacy state. Mick decided on 2026-10-22 that listening is off until he turns it
  on from the app, and that privacy does not survive a restart (#809). So the host never pushes to a key before that
  key has made a proven, approved connection since the restart. Updates submitted before any approved device has
  connected are held (`held: no_device`) and drain to the first approved connection.

Compared with #813, this is stricter in two ways. A key's report outlives its connection until that key reconnects or
turns privacy off. And one private device stops all proactive delivery to every device. Part 10, who owns privacy,
accepted both as the safe direction on 2026-10-22, with the same-key-reconnect clearing rule above.

## Delivery ladder

The host decides each update when it is submitted, and again whenever the queue drains or a send is retried. The
first rule that applies wins. Every rule that delivers means an **approved** device. An unapproved connection
receives nothing proactive and does not count as connected.

1. **Private:** while the owner is private, the update is **dropped**, matching #813's "dropped, not paused". Nothing
   is spoken, shown or pushed, and `haild notify` answers `dropped: private`. Updates already held are purged when
   privacy starts, as #813 purges pending replies.
2. **Quiet** (`haild notify quiet on`) **or quiet hours:** held, never spoken or pushed. A connected device gets the
   card without sound.
3. **`info`:** held. It drains at the next natural pause on a listening device, at the next interaction ("You have
   3 updates"), or when the owner asks. It is never pushed.
4. **`action`, a listening device not in media mode:** spoken now in the house voice, plus the card.
5. **`action`, a connected device whose app is in front, not muted, not away and not in media mode:** spoken now
   through the app's reply player, plus the card. This covers Mick's "spoken clip when the app is foregrounded".
6. **`action`, a connected device that is not away:** a `session_update` frame. The app shows the card and posts a
   local notification. The app is often connected in the background through its audio keepalive (#282, #352), so most
   updates never need APNs.
7. **`action`, otherwise:** an APNs push to every approved key that has connected since the restart and has a token.
   The update stays held until its expiry and shows as a card on the next connection; the `update` UUID stops it
   showing twice.

For an `action`, rules 4 to 6 first re-challenge each candidate connection. One that does not answer within 5 seconds
is demoted and no longer counts, so the update falls through, at worst to rule 7. While that check runs the update is
held, and `haild notify` answers once the decision is made, within about 5 seconds. A Mac whose user is idle or whose
screen is locked reports `away`, so it does not stop the phone's push.

## How a session triggers one

No new command. `haild notify <target> --say <text> [--card <text>] [--action]` stays the only entry point. It uses
the owner-only reply socket, and its session label comes from the live target registry, never from caller text
(#371). There is no `--speak` flag: speaking is the host's decision, so a session cannot speak through quiet or
privacy. `haild notify quiet off` is added; any local process can reach the socket, so quiet stays a cooperative
control (`docs/host-operations.md`).

The answer gains outcome tokens, and `push: suggested` goes away:
- delivered: `spoken`, `shown`, `pushed`, `pushed: summary`;
- held: `held: quiet`, `held: no_device`;
- refused: `dropped: private`, `push: failed`.

## APNs from haild

- **Keys:** token-based `.p8` keys from Mick's developer account with APNs enabled, signing an ES256 JWT.
  - The JWT is refreshed between 20 and 50 minutes old, never more often than every 20 minutes. A `403` within that
    window is reported rather than retried with a new token.
  - Apple's newer team-scoped keys work in either sandbox or production, not both. One **production** key serves
    TestFlight and App Store builds and is the default.
  - An optional second, **sandbox** key serves debug builds. Without it, debug builds get no pushes.
  - A token whose environment has no configured key is refused at registration.
- **Files:**
  - `host.json` gains `"apns": "<absolute path to apns.json>"`, which `host.sh` passes as `--apns <path>`.
  - `apns.json` (0600) holds the team ID, the topic, and one or two keys, each with its environment and key ID.
  - Each key file is a fixed sibling in the same directory: `production.p8`, and `sandbox.p8` when configured.
  - The owner, 0700-parent and no-symlink checks apply to whatever directory `--apns` names.
  - The JWT and keys are never printed, logged, audited or committed (`.gitignore` covers `*.p8`).
  - `haild doctor` reports `apns: configured | missing | unreadable` and the environments configured.
  - Mick creates the keys and places the files himself. That is an operator step, never done from a transcript.
- **Transport:** HTTP/2 via `URLSession` to Apple's production host, `api.push.apple.com`, or for sandbox tokens
  `api.sandbox.push.apple.com`. No new dependency.
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
  - `403` provider-token errors: refresh the JWT once if the 20-minute limit allows, never touch a device token, and
    report in `haild doctor`.
  - `429 TooManyProviderTokenUpdates`: a signing bug, reported, with no retry storm.
  - `429 TooManyRequests` and `5xx`: retry after 15 minutes. Apple gives 15 minutes for `5xx`; using it for `429` is
    this design's choice. A retry re-runs the ladder, so privacy or quiet that began since cancels it.
  - Failures are audited as reason tokens only.

## Rate limits and quiet hours

- The existing per-session limit stays: 6 updates an hour, 5 held, 20 in all, 4-hour lifetime.
- **Pushes:** at most 4 in any 60-minute window ending now, for the whole host, counting the summary.
  - The first 3 in a window go individually.
  - Later ones collapse into one summary push, "N updates waiting" (`pushed: summary`), which takes the fourth slot.
    It has a fixed collapse ID, so a later summary replaces it.
  - A retry of the same push does not count again.
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
  The app plays proactive speech only if it is really in front and unmuted at that moment, whatever it last
  reported. It gains no on-device synthesiser and no second voice. A push can play its alert sound but cannot speak
  the update.
- **Presence:**
  - The app sends `presence {foreground, muted, away}` once approved, then on every change: coming to the front or
    going to the back, its reply mute, and (on the Mac) the user going idle or the screen locking.
  - The host ignores presence before approval.
  - Until the first report, or for an app without the capability, the host assumes not in front and not away. So
    the device gets frames (rule 6) but no speech (rule 5).
- **Settings:**
  - a push on/off switch, which asks for permission only when turned on;
  - the device fingerprint;
  - the approval state the host reports, including `superseded`.

## Protocol shape

New messages are capabilities. The host lists `owner_device` and `presence` in its own hello, and a device sends
neither to a host that did not list them. Likewise the host never sends a command a device did not advertise. There
is no version bump.

| Message | Direction | Capability | Fields |
| --- | --- | --- | --- |
| `session_update` (exists) | host to device | `session_update` | `update`, `session`, `priority`, `text`, `card?` |
| `device_challenge` | host to device | `owner_device` | `nonce` |
| `device_proof` | device to host | `owner_device` | `key`, `signature`, `token?`, `environment?`, `name`, `kind` |
| `device_state` | host to device | `owner_device` | `fingerprint`, `state`: `pending`, `approved`, `revoked`, `superseded`, `unanswered` or `full` |
| `presence` | device to host | `presence` | `foreground`, `muted`, `away` (booleans) |

The APNs JSON is not a hail frame. It lives in a new `Notify/` type, with its schema in `docs/reply-protocol.md`.

## Files this touches, and sequencing after Part 10

Part 10's privacy stack (#807, #808, #813, S-6) is changing `WebSocketListener*`, `HostSession`,
`HostReplyDelivery`, the RightyO input files, and `Control.swift`/`Schema.swift` (for `set_privacy`).

| Area | Files | Overlap |
| --- | --- | --- |
| Device challenge, proof, re-challenge and presence | a new HostSession command case, a new `Listener/OwnerDevices*.swift` | **HostSession** decodes device commands |
| Owner privacy, quiet and quiet hours (rules 1 and 2) | `LocalSessionUpdate.swift`, `SessionUpdate.swift` | **WebSocketListener**: per-connection privacy readable through `AmbientListenerWiring`, like `mediaMode` |
| Drain and deliver `session_update` (rules 3 and 6) | `Notify/*`, `LocalSessionUpdate.swift`, a new `WebSocketListener+SessionUpdate.swift` | **WebSocketListener**: drain state and peer lookup, like `+MediaMode` |
| Speak an `action` (rules 4 and 5) | the reply audio path | **HostReplyDelivery**: requestless delivery must honour the privacy drop |
| Protocol messages | `Control.swift`, `Schema.swift`, fixtures | **Control.swift and Schema.swift**: S-6a adds `set_privacy` there |
| APNs client, key files, device store, `haild devices` | new `Notify/APNs*.swift`, `Sources/haild/DevicesCommand.swift`, `host.sh` | None |
| App: key, proof, card, notifications, presence, settings | `HailApp.swift`, `HostConnection+Protocol.swift`, `HostConnectionStore.swift`, chat views, `project.yml` | Possibly Part 10's privacy-switch app branch, in the store |

So everything except the APNs client and the device store waits for Part 10's stack to merge.

## Slices

1. **APNs sender:** key files and checks, JWT, HTTP/2, failure handling, `haild doctor`. Synthetic tests against a
   local HTTP/2 stub only; no real push leaves the host until Mick is listening. Can start now.
2. **Owner devices:** the challenge, proof, re-challenge, store and `haild devices`, plus the app's key, proof and
   fingerprint screen. After Part 10.
3. **Owner privacy, quiet and quiet hours** (rules 1 and 2), landing before anything delivers. After Part 10.
4. **Updates reach an approved, connected app:** revive the local card branches; drain to approved devices (rules
   3 and 6); a local notification when backgrounded; presence. After Part 10.
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
2. **While private:** updates are **dropped**, and held ones purged, to match #813. Would you rather they were held
   and delivered after privacy ends? Held updates are agent output, not anything heard.
3. **Privacy across devices:** while any device is private, nothing proactive reaches any device. Only that device
   ends it, by turning privacy off or reconnecting. Part 10 has accepted this.
   - Costs: a phone that drops off while private keeps every device quiet until it reconnects. After a haild
     restart, nothing is pushed to a device until it has connected again; a connected Mac still gets rules 4 to 6.
   - Is that what you want?
4. **Quiet hours:** what window? Should any `action` break through? A breakthrough would need the time-sensitive
   entitlement. Proposed: no breakthrough.
5. **APNs keys:** you create a production key, and optionally a sandbox key, and place them with `apns.json` in a
   directory you choose. Is that right, or would you rather use the Keychain?
6. **Mac pushes:** deferred as above. Is that fine?

## Verification

This is a design document. It records no runtime behaviour. The current state was read from `main` at ea6a387:
- the merged #609 queue, `haild notify` and the `session_update` frame;
- `drain` with test callers only, and the connected-device push rule;
- no APNs code;
- the app's single local notification, the empty iOS entitlements and the unsigned Mac app;
- duck mode's default timeout;
- no report of the app's mute state to the host.

The privacy semantics it defers to come from Part 10's open PRs #807, #808 and #813, not `main`, and Part 10 signed
off on this section on 2026-10-22. The restart rule follows Mick's 2026-10-22 decision. #809 records that privacy no
longer survives a restart. The words "listening is off until he turns it on from the app" are as relayed by Jarvis,
not quoted from an issue.
