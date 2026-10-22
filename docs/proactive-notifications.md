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
  #813: per connection, in memory, never auto-ending, with replies dropped, and gone after a restart (#809 parked).

## Owner devices

The personal-terminal listener has no TLS and no peer authentication (`docs/security.md`). Anything sent over it can
be read, and frames can be injected, by someone on the network path. So a device is never trusted for what it
claims. It is trusted only for holding a private key the owner approved.

1. **Device key:** on first use the app makes a P-256 key pair in the Secure Enclave (iPhone, iPad) or the Keychain
   (Mac). The private key never leaves the device.
2. **Challenge:** haild lists `owner_device` in its hello. When the device has listed it too, haild sends
   `device_challenge {nonce}`, with a fresh 32-byte nonce, and the app answers `device_proof {key, signature,
   token?, environment?, name, kind}`.
3. **Signed message:** the signature covers a fixed label and length-prefixed fields, so no field can be moved into
   another: `"hail-owner-device-v1"`, then the nonce, the token (empty when pushes are off) and the environment
   (empty when pushes are off), each as a 4-byte big-endian length followed by its bytes. A proof with an empty token
   clears the stored token: the app turned pushes off, and a relay cannot strip a token from a signed proof.
4. **Fingerprint:** the SHA-256 of the public key, shown as 16 hex characters in four groups (64 bits). An attacker
   cannot choose it without the private key.
5. **Approval:** a key starts pending.
   - The owner runs `haild devices` and then `haild devices approve <fingerprint>` over the owner-only socket.
   - `approve` needs the full fingerprint, refuses one that matches more than one entry, and works only while that
     device is connected. The app shows its own fingerprint and its state, so the owner compares them on both
     screens. A device left `pending` after approval means the wrong row was approved.
   - The name and kind are shown as **unverified** until approval, then fixed. Later proofs cannot change them.
   - `haild devices revoke <fingerprint>` demotes the key's live connection at once and puts the key on a revoked
     list. A revoked key never becomes pending again.
6. **Approved connection:** a connection becomes an **approved device** only after a valid proof from an approved key
   on that connection.
   - There is one approved connection per key: a newer proof demotes the older connection.
   - haild re-challenges every 10 minutes, and again immediately before rule 7 counts a device as connected. A
     connection that does not answer a challenge within 5 seconds is demoted.
   - A token can rotate only with a fresh proof answering a challenge.
7. **Pending store:** a pending entry exists only while its connection is open.
   - At most 8 at once; a ninth proof is refused with `device_state {state: "full"}`.
   - One pending proof per connection.
   - Token, environment, name (at most 64 characters) and kind are validated.
8. **Saved store:** approved and revoked keys, each approved key's current token and fixed labels, are kept in
   `~/.config/hail/devices.json` (0600) under the `PolicyFile` checks: owner, 0700 parent, no symlinks. Keys and
   tokens are never printed, logged, audited, put in diagnostics or committed.

This is the same rule voice routing follows (`docs/voice-routing.md`): a discovered peer is never trusted on its own.

**Known limits until the listener has TLS:**
- Frames after a proof are not authenticated.
- Someone on the network path can read every `session_update`, as they can read every reply today.
- While the owner's device is connected, they can relay its proof and the re-challenges to keep a connection of
  their own approved. That connection receives updates and counts as connected, so rule 7 does not push.

Re-challenges limit the last point to the time the real device is online: once it leaves, the relay can no longer
answer, the relayed connection is demoted, and rule 7 pushes. The design reduces these risks but does not remove
them. Removing them needs TLS with a pinned host key, which is out of scope here.

## Owner privacy

Privacy is per device, and its effect on pushes is owner-wide. haild keeps, in memory only, each approved key's last
privacy report.
- **The owner is private** while any approved key's last report is private.
- **Only that key's own device clears its report,** by turning privacy off. Another device connecting never clears
  it, and neither does dropping a connection, so a phone that falls off the network while private stays private.
- **A connection that is private right now** is skipped by every rule. Nothing is spoken to it, shown on it or
  pushed to it, whatever other devices report.
- **After a restart** there is no privacy state. This follows Mick's 2026-10-22 decision: listening is off until he
  turns it on from the app, and privacy does not survive a restart. So the host never pushes to a key before that key
  has connected since the restart. Updates submitted before any approved device has connected wait, held, and drain
  to the first approved connection.

This is stricter than #813, which keeps no host-wide private state, in one way only: one private device stops pushes
to all of them. Part 10 owns privacy and must agree (open question 3).

## Delivery ladder

The host decides each update when it is submitted, and again whenever the queue drains or a send is retried. The
first rule that applies wins. Every rule that delivers means an **approved** device that is not private now. An
unapproved connection receives nothing proactive and does not count as connected.

1. **Private:** while the owner is private, the update is **dropped**, matching #813's "dropped, not paused". Nothing
   is spoken, shown or pushed, and `haild notify` answers `dropped: private`. Updates already held are purged when
   privacy starts, as #813 purges pending replies.
2. **Quiet** (`haild notify quiet on`) **or quiet hours:** held, never spoken or pushed. A connected device gets the
   card without sound.
3. **`info`:** held. It drains at the next natural pause on a listening device, at the next interaction ("You have
   3 updates"), or when the owner asks. It is never pushed.
4. **`action`, a listening device not in media mode:** spoken now in the house voice, plus the card.
5. **`action`, a connected device whose app is in front, not muted, not away and not in media mode:** spoken now
   through the app's reply player, plus the card. The app reports `presence {foreground, muted, away}`. This covers
   Mick's "spoken clip when the app is foregrounded".
6. **`action`, a connected device that is not away:** a `session_update` frame. The app shows the card and posts a
   local notification. The app is often connected in the background through its audio keepalive (#282, #352), so most
   updates never need APNs.
7. **`action`, no approved device connected and present:** an APNs push to every approved key that has connected
   since the restart and has a token. A device counts as present only if it is not `away` and answers a fresh
   re-challenge. A Mac whose user is idle or whose screen is locked reports `away`, so it no longer suppresses the
   phone's push. The update stays held until its expiry and shows as a card on the next connection; the `update` UUID
   stops it showing twice.

## How a session triggers one

No new command. `haild notify <target> --say <text> [--card <text>] [--action]` stays the only entry point. It uses
the owner-only reply socket, and its session label comes from the live target registry, never from caller text
(#371). The answer gains outcome tokens: `spoken`, `shown`, `pushed`, `held: quiet`, `held: no_device`,
`dropped: private`, `push: no_device` and `push: failed`. `push: suggested` goes away. There is no `--speak` flag:
speaking is the host's decision, so a session cannot speak through quiet or privacy. `haild notify quiet off` is
added; any local process can reach the socket, so quiet stays a cooperative control (`docs/host-operations.md`).

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
- **Pushes:** at most 4 in any rolling hour for the whole host, counting the summary.
  - The first 3 go individually.
  - Later ones in that hour collapse into one summary push, "N updates waiting", which takes the fourth slot. It has a
    fixed collapse ID, so a later summary replaces it.
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
  The app gains no on-device synthesiser and no second voice. A push can play its alert sound but cannot speak the
  update. If the app is alive in the background and connected, rules 4 to 6 apply before APNs.
- **Presence:** the app reports when it comes to the front or goes to the back, when its reply mute changes, and (on
  the Mac) when the user goes idle or the screen locks.
- **Settings:**
  - a push on/off switch, which asks for permission only when turned on;
  - the device fingerprint;
  - the approval state the host reports.

## Protocol shape

New messages are capabilities. The host lists `owner_device` and `presence` in its own hello, and a device sends
neither to a host that did not list them. Likewise the host never sends a command a device did not advertise. There
is no version bump.

| Message | Direction | Capability | Fields |
| --- | --- | --- | --- |
| `session_update` (exists) | host to device | `session_update` | `update`, `session`, `priority`, `text`, `card?` |
| `device_challenge` | host to device | `owner_device` | `nonce` |
| `device_proof` | device to host | `owner_device` | `key`, `signature`, `token?`, `environment?`, `name`, `kind` |
| `device_state` | host to device | `owner_device` | `fingerprint`, `state`: `pending`, `approved`, `revoked` or `full` |
| `presence` | device to host | `presence` | `foreground`, `muted`, `away` (booleans) |

The APNs JSON is not a hail frame. It lives in a new `Notify/` type, with its schema in `docs/reply-protocol.md`.

## Files this touches, and sequencing after Part 10

Part 10's privacy stack (#807, #808, #813, S-6) is changing `WebSocketListener*`, `HostSession`,
`HostReplyDelivery`, the RightyO input files, and `Control.swift`/`Schema.swift` (for `set_privacy`).

| Area | Files | Overlap |
| --- | --- | --- |
| Device challenge, proof, re-challenge and presence | a new HostSession command case, a new `Listener/OwnerDevices*.swift` | **HostSession** decodes device commands |
| Drain and deliver `session_update` (rules 3 and 6) | `Notify/*`, `LocalSessionUpdate.swift`, a new `WebSocketListener+SessionUpdate.swift` | **WebSocketListener**: drain state and peer lookup, like `+MediaMode` |
| Owner privacy, quiet and quiet hours (rules 1 and 2) | `LocalSessionUpdate.swift`, `SessionUpdate.swift` | **WebSocketListener**: per-connection privacy readable through `AmbientListenerWiring`, like `mediaMode` |
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
3. **Updates reach an approved, connected app:** revive the local card branches; drain to approved devices (rules
   3 and 6); a local notification when backgrounded; presence. After Part 10.
4. **Owner privacy, quiet and quiet hours in the ladder** (rules 1 and 2). After Part 10.
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
3. **Privacy across devices:** one private device stops pushes to every device, and only that device clears it.
   - Costs: a phone that drops off while private keeps pushes off everywhere until it reconnects and turns privacy
     off. After a haild restart, nothing is pushed to a device until it has connected again.
   - Is that what you want? Part 10 owns the privacy design.
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
- duck mode's default one-hour timeout;
- no report of the app's mute state to the host.

The privacy semantics it defers to come from Part 10's open PRs #807, #808 and #813, not `main`. The restart rule
follows Mick's 2026-10-22 decision recorded with #809.
