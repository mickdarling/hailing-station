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
| Slice 1a: APNs provider token, request and response classification (no network) | Merged (#818). Not deployed. |
| Owner devices, draining, speaking, privacy, quiet hours, the rest of APNs | Proposed here. |

On `main` today:
- Every update is held: `listeningDevice` is nulled in `LocalSessionUpdate.swift`, and `SessionUpdateQueue.drain` has
  only test callers.
- An `action` update prints `push: suggested` only when a target device is *connected* and quiet is off
  (`SessionUpdateQueue.push`, `NotifyCommand.swift`). Nothing is pushed when no device is connected. This design
  reverses that (rule 7 below).
- `scripts/host.sh` does not pass `--session-updates`.
- Privacy is Part 10's, merged: #807, #808 and #813 on the host, and the switch in #815 to #817 (S-6a to S-6c). It
  is per connection, in memory, never auto-ending (Mick: no auto-end), with replies dropped. A fresh connection
  starts public. `set_privacy {on}` is acted on only while the connection has an active stream, and fails closed to
  off when no child can take it. Privacy does not survive a restart (#809 records "Privacy no longer survives a
  restart"). Mick decided on 2026-10-22 that a network drop must never turn privacy into public, so in this design
  a device that was private comes back private or not listening (Owner privacy, Reconnects). Part 10 has proposed
  that as S-7a0 to S-7c; none of it is built.

## Owner devices

The personal-terminal listener has no TLS and no peer authentication (`docs/security.md`). Anything sent over it can
be read, and frames can be injected, by someone on the network path. So a device is never trusted for what it
claims. It is trusted only for holding a private key the owner approved.

1. **Device key:** on first use the app makes a P-256 key pair in the Secure Enclave: on iPhone and iPad, and on Macs
   with Apple silicon or a T2 chip. Other Macs use a Keychain item protected by the user account, which is weaker.
   The key is this-device-only, never synced, and usable after first unlock with no presence check. The private key
   never leaves the device.
2. **Challenge:** haild lists `owner_device` in its hello. When the device has listed it too, haild sends
   `device_challenge {nonce}`, with a fresh random 32-byte nonce, base64 in the frame. The app answers
   `device_proof {key, signature, token?, environment?, name, kind}`. On a normal connection the app proves before
   it starts any audio (the exception is a voice-only reconnect after `superseded`, below). Its key is usable after
   the device's first unlock, so a locked phone reconnecting in the background can still prove.
3. **Encodings:**
   - `key`: the public key as an uncompressed X9.63 point (65 bytes), base64 in the frame.
   - `signature`: ECDSA P-256 over SHA-256, DER-encoded, base64.
   - `token`: the APNs token as lowercase hex; anything else is refused, never normalised.
   - `environment`: `production` or `sandbox`. The token and environment come together or not at all; a proof with
     only one of them is refused.
4. **Signed message:** each of these, in order, as a 4-byte big-endian length followed by its bytes, so no field can
   be moved into another:
   - the ASCII label `hail-owner-device-v1`;
   - the 65 key bytes;
   - the 32 nonce bytes;
   - the token's ASCII hex (empty when pushes are off);
   - the environment's ASCII (empty when pushes are off);
   - the name's UTF-8 bytes;
   - the kind's ASCII.

   A proof with no token clears the stored token: the app turned pushes off, and a relay cannot strip a token from a
   signed proof.
5. **Fingerprint:** the SHA-256 of the 65 key bytes, shown as 16 hex characters in four groups (64 bits). An attacker
   cannot choose it without the private key.
6. **Approval:** a key starts pending.
   - The owner runs `haild devices` and then `haild devices approve <fingerprint>` over the owner-only socket.
   - `approve` needs the full fingerprint, refuses one that matches more than one entry, and works only while that
     device is connected. The app shows its own fingerprint and its state, so the owner compares them on both
     screens. A device left `pending` after approval means the wrong row was approved.
   - The name and kind are signed with the proof, so nobody on the path can relabel a device. They are still
     chosen by the device, so they are shown as **unverified** until approval, then fixed. Later proofs cannot change
     them.
   - `haild devices revoke <fingerprint>` demotes the key's live connection at once, clears the key's privacy report,
     and puts the key on a revoked list. A revoked key never becomes pending again.
7. **Approved connection:** a connection becomes an **approved device** only after a valid proof from an approved key
   on that connection. Proofs from approved keys are never refused for a full pending store.
   - **One per key:** a newer proof supersedes every older open connection of that key, including demoted ones.
     Each is told `device_state {state: "superseded"}`, is not challenged again, and is closed by haild 30 seconds
     later. Closing ends that connection's voice and replies too. If the new proof was not the owner's, the app shows
     that another connection holds the device's key.
   - **Re-challenges:** every 10 minutes, and before rules 4 to 6 count the connection for an `action` (the ladder
     below).
   - **Timeout:** a connection that does not answer within 5 seconds is demoted (`device_state {state:
     "unanswered"}`). It is challenged once more 30 seconds later. Only an answer to that new challenge restores it;
     nonces are single-use. A connection that misses that one retry stays demoted until it reconnects. A newer proof
     from the same key cancels the pending retry, and a connection superseded meanwhile stays demoted.
   - **After `superseded`** the app does not re-prove on its own. It may reconnect for voice and replies without
     listing `owner_device`, so it is not challenged; that works unproven as today but receives nothing proactive.
     It shows the state, and the owner's next step is a reconnect that proves.
   - **After `unanswered`** the app answers the retry challenge if it is still connected. If no `approved` arrives
     within about 40 seconds of `unanswered`, it shows that it is unconfirmed and reconnects to prove again. That
     reconnect follows Owner privacy, Reconnects: the key's report stands, and a private app re-requests privacy.
   - **Privacy changes while demoted:** a privacy-on applies to the key at once (Recording) and is never held; it
     discards any held privacy-off. Only a privacy-off is held, and the connection being superseded or closing also
     discards it. A held off applies at restore only if the connection is public at that moment. A demoted
     connection that is private still counts for "Private now".
   - **No challenge:** if no `device_challenge` arrives within 10 seconds of a hello in which the host listed
     `owner_device`, the app shows that it could not be confirmed and treats itself as unapproved. Voice and replies
     carry on unproven, as today. It still answers a challenge that arrives later. Without `owner_device` in the
     hello, it shows that this host does not offer owner devices.
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
  own. That supersedes the real device's connection, which is told `superseded` and closed 30 seconds later, though
  they can drop that frame too.
- They can forge or replay a privacy report, so privacy set by the owner can be cleared at once. A relayed proof
  alone does not clear it, but it makes the relay's connection the key's current approved connection, so a
  privacy-off sent on it clears the report legitimately. That lasts while the relay answers re-challenges, up to
  about 10 minutes after the owner's device leaves.
- While a relay holds a key's approved connection, the real device gets nothing proactive and no push. Each relayed
  proof also supersedes the real device's connection, which loses its voice session 30 seconds later. If the relay
  drops the `superseded` frame, the app just sees the connection close and reconnects. So a relay can force a
  reconnect about every 30 seconds, and each one stops listening until the host confirms the connection's state
  (Reconnects).
- The reconnect gate is advisory until TLS. They can drop the app's re-sent `set_privacy {on}` and forge the
  `duck_mode {on}` confirmation, so a private app streams to a public host when the owner next listens. "Per host"
  means the app's saved, unauthenticated host entry; a host the app does not know starts not listening. They can also
  change the instance id in a hello (S-7a0), which clears the wish; that is announced. If the wish is persisted, the
  instance id is persisted with it.
- A forged privacy-on drops new updates and purges held ones, so queued agent output is lost. It discloses nothing.
- They can drop a privacy-on frame, so the owner's privacy never takes effect on the host. The app shows privacy only
  once the host confirms it (as in #817), so a dropped frame alone shows as not private. But they can also forge the
  confirmation: the indicator is advisory and unauthenticated until the listener has TLS.
- A connection that never proves protects only itself: its privacy marks no key. The same device can still be pushed
  under its key while that key reports public.
- A push APNs has already accepted cannot be recalled if privacy starts before it arrives; its expiry is at most the
  update's 4-hour lifetime.
- `info` updates and cards drained without an `action` rely on the 10-minute re-challenge. For up to 10 minutes after
  the real device leaves, a relayed or half-open connection can still receive them.

An `action` re-challenges before it counts a connection. So once the real device has left, the relay can't answer,
the relayed connection is demoted, and the update falls through to a push. The design reduces these risks but does
not remove them. Removing them needs TLS with a pinned host key, which is out of scope here.

## Owner privacy

haild keeps, in memory only, each approved key's last privacy report.
- **At every proof** (a fresh connection, a pending connection being approved, or a restore after `unanswered`), a
  private connection marks the key private. So privacy entered before approval, or before the proof completed, is
  kept from the moment the proof lands. A re-challenge answer never clears a report. A restore clears it only by
  applying a held privacy-off, when the connection is public at that moment (Owner devices, item 7). Nothing else
  clears a report (see Clearing).
- **Recording:** privacy turned on from any connection that has proven a key marks that key private. Privacy turned
  off counts only from that key's current approved connection.
- **Clearing:** a key's private report clears only:
  - when that key turns privacy off on its current approved connection;
  - when that key is revoked;
  - when haild restarts, since reports live in memory only.

  Dropping a connection, reconnecting, a fresh proof and another key connecting never clear it.
  - A privacy-off on the key's current approved connection clears the report even when that connection is already
    public, and with no active stream. Slice 2 changes this: on `main` today (#816) such an off does nothing, and the
    host acts on the switch only with a stream. Otherwise a key left private by a discarded held off, or by a
    privacy-on from an older or forged connection, would have no exit but revocation or a restart.
  - While its key reports private and its connection is public, the app shows that proactive updates are paused by
    privacy, with an "End privacy" action that sends that off. #817's switch shows the connection's own listening
    privacy: "Not private" once S-7a has confirmed the connection public.
  - haild sends `device_state` on every change to the key's privacy. Its `privacy` field is the key's report, not the
    owner's; for a pending key it is the connection's own privacy.
  - For proactive delivery, the app shows updates as flowing only when its key reports public, so it never shows
    them unpaused while its key is private.
- **Reconnects:** Mick decided on 2026-10-22: "A network drop should not change it from being private to being
  public." A reconnect never brings a device back listening in public while it was private. Proposed by Part 10 as
  S-7a0 to S-7c; none of it is built.
  - A reconnect leaves the key's report as it was (Clearing). The host starts every connection public and not
    listening. That is listening privacy, per connection; the key's report governs only proactive delivery.
  - **The owner's wish (S-7b):** the app keeps the owner's latest privacy choice for each saved host. A privacy-on
    still waiting for the host's confirmation counts as on. Keeping it in the app's defaults, so it survives the app
    being killed, is proposed and pending Mick, since #809 settled that privacy does not survive a host restart
    (open question 7). Until then, an app killed by iOS and relaunched has no wish, so a listen the owner starts by
    hand starts public even though he chose privacy. A relaunch is not a reconnect, so the rule above does not
    cover it.
  - Proposed for the owner-device slice, needing no decision: on a relaunch, the app treats its own key's
    `device_state {privacy: private}` as the wish and re-requests privacy before any audio. The report lives only in
    haild's memory, so a restart wipes it, and this cannot conflict with #809. It closes the relaunch gap for proven
    devices.
  - A privacy-on that times out (the 10-second wait in #817) or is refused leaves the wish on. The way out is the
    S-7c card's "Listen publicly", a deliberate tap only. It clears the wish and sends `set_privacy {off}`, since a
    timeout may mean the host did go private and only its notice was lost. That is the same off as "End privacy",
    so on a proven connection it also clears the key's report (Clearing) and proactive updates resume.
  - Before any audio or announcement, the app waits up to 10 seconds for the host's answer. haild answers every
    `set_privacy` with the connection's current `duck_mode`, even when nothing changed and no stream is running
    (S-7a; on `main` such an off does nothing and sends nothing). On the off notice: "Privacy is off. Listening
    publicly." and, if its key was private, "Updates resume." With no answer: "The Mac didn't answer. Listening is
    off." With no connection: "Can't reach the Mac. Listening is off." Neither streams. The switch stays bound to
    the host.
  - **Privacy turned on mid-listen** (proposed for S-7b, pending Mick): from the tap, before `set_privacy {on}` is
    sent, the app stops sending audio, and audio captured while it waits is dropped, never buffered or flushed. On
    the notice it carries on privately; on a timeout or refusal it stops listening, and S-7c says "Privacy wasn't
    confirmed. Listening is off." This changes #816 and #817, where a refused on plays `confirm-not-sent` and the
    stream carries on in public. The owner asked for privacy, so this fails closed.
  - **Wish on:** before any audio, the app sends `set_privacy {on}` and waits for the host's `duck_mode` on notice.
    If that is refused or does not come, it stays not listening. S-7a lets the host accept that request with no
    active stream; the next stream on that connection then starts private, or is refused, never public (a named
    S-7a test). This also covers privacy held before a proof, which marked no key.
  - **What the host confirms (S-7a):** haild sends the connection's current `duck_mode` state once after the hello.
    The app treats only a `duck_mode` notice as the host's confirmation; silence never counts as public.
  - **No resume yet:** S-7 does not resume listening on its own. After a reconnect the owner starts listening again,
    and that listen is privacy-first while the wish is on. So the guarantee #817 pins in
    `AmbientBindingChangeRegressionTests`, that listening never starts on a reconnect (key 1's requirement in the
    #808 review), still holds. A later auto-resume PR relaxes it on purpose: a device that was listening in public
    resumes once the host confirms public, and one that was private resumes only through the privacy-first path.
  - **A restart is not a drop (S-7a0):** haild puts a random per-launch instance id in its hello, a protocol field of
    its own. When the id for a saved host changes, the app clears the wish (#809), does not resume, and says "The
    Mac restarted. Listening is off and privacy ended."
  - A reconnect that does not prove (no `owner_device` in the host's hello, no challenge, or the voice-only reconnect
    after `superseded`) follows the same path, since the wish is per host, not per key. A host the app has not saved
    starts not listening.
  - Whenever listening stops on a drop, a handover or a restart, the app says so, aloud and on the card (S-7c,
    #822): "Listening stopped: the connection changed", adding "Privacy is still on." when it is. It never stops
    listening silently.
- **Before a proof or approval:** privacy turned on over a connection that has not yet proven, or whose key is still
  pending, is held by that connection and applied to the key at the proof or approval. A connection that never
  proves protects only itself: it gets nothing proactive, but its privacy marks no key.
- **Private now:** an open connection that has proven an approved key and is private right now also makes the owner
  private, whatever the key's report says, so the backstop reaches every rule, including pushes.
- **The owner is private** while any approved key's report is private, or any such connection is private now. Then
  nothing proactive reaches **any** device: nothing is spoken, shown or pushed (rule 1). Mick's rule is that privacy
  means nothing reaches him until he ends it.
- **After a restart** there is no privacy state. Mick decided on 2026-10-22 that listening is off until he turns it
  on from the app, and that privacy does not survive a restart (#809). So the host never pushes to a key before that
  key has made a proven, approved connection since the restart. Updates submitted before any approved device has
  connected are held (`held: no_device`) and drain to the first approved connection.

Compared with #813, this is stricter in three ways. A key's report outlives its connection until that key turns privacy
off or is revoked. One private device stops all proactive delivery to every device. And a device that was private comes
back private or not listening, never public. Part 10, who owns privacy, accepted the first two as the safe direction on
2026-10-22 (by direct session message), at first with a same-key-reconnect clear. Mick's reconnect decision replaced
that clear, and Part 10 proposed the reconnect path above.

## Delivery ladder

The host decides each update when it is submitted, and again whenever the queue drains or a send is retried. The
first rule that applies wins. Every rule that delivers means an **approved** device. An unapproved connection
receives nothing proactive and does not count as connected. A connection that is private right now receives nothing,
whatever the key reports: a backstop to rule 1.

1. **Private:** while the owner is private, the update is **dropped**, matching #813's "dropped, not paused". Nothing
   is spoken, shown or pushed, and `haild notify` answers `dropped: private`. Updates already held are purged when
   privacy starts, as #813 purges pending replies.
2. **Quiet** (`haild notify quiet on`) **or quiet hours:** held, never spoken or pushed. A connected device gets the
   card without sound, after the same re-challenge as rules 4 to 6 for an `action`.
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

For an `action`, rules 4 to 6 first re-challenge each candidate connection.
- One that does not answer within 5 seconds is demoted and no longer counts, so the update falls through, at worst to
  rule 7.
- While that check runs, the update is held. Other updates and drains in the meantime share the same outstanding
  challenge.
- When it resolves, the ladder runs again from rule 1, so privacy or quiet that began during the wait still applies.
  A connection that has just answered counts in that re-run without a new challenge.
- `haild notify` answers once the decision is made, within about 5 seconds.

A Mac whose user is idle or whose screen is locked reports `away`, so it does not stop the phone's push.

## How a session triggers one

No new command. `haild notify <target> --say <text> [--card <text>] [--action]` stays the only entry point. It uses
the owner-only reply socket, and its session label comes from the live target registry, never from caller text
(#371). There is no `--speak` flag: speaking is the host's decision, so a session cannot speak through quiet or
privacy. `haild notify quiet off` is added; any local process can reach the socket, so quiet stays a cooperative
control (`docs/host-operations.md`).

The answer gains outcome tokens, and `push: suggested` goes away:
- delivered: `spoken` (sent for speaking; under rule 5 the app may still decline and show only the card), `shown`,
  `pushed`, `pushed: summary`;
- held: `held: quiet`, `held: no_device` (rule 7 has no eligible key: none has connected since the restart, or none
  has a token), `held: push_cap`, `held: info`;
- refused: `dropped: private`, `push: failed`.

These go on a new `outcome:` line of the answer. The existing `held: N updates waiting` line, printed with the
answer and by `haild notify status`, stays as it is. An `info` update held for a natural pause answers
`held: info`. An update held while a re-challenge runs gets its final outcome once the challenge resolves.

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
  `priority`; the summary push carries its count as `hail.summary` instead of `update` and `session`. Card text
  is never pushed.
- **Headers:**
  - `authorization: bearer <JWT>`, the current provider token, never logged; and `apns-topic`, the app's bundle ID
    from `apns.json`.
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
- **Pushes:** at most 4 in any 60-minute window ending now, for the whole host, counting the summary. One update
  pushed to several keys counts once.
  - The first 3 in a window go individually.
  - The fourth push is a summary, "N updates waiting" (`pushed: summary`).
  - After that, further updates in the window are held (`held: push_cap`) and show as cards on the next connection.
    No fifth push goes out, and these are not pushed later when the window frees.
  - The summary's N is the number of updates held in the queue when it is sent.
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
  For rule 5, the app plays the speech only if it is really in front and unmuted at that moment, whatever it last
  reported. Rule-5 audio is marked as an update's foreground speech, so the app can tell it from rule-4 and reply
  audio. If it declines, it shows only the card and tells the host nothing. Rule 4 speech on a listening device plays
  as replies do today. The app gains no on-device synthesiser and no second voice. A push can play its alert sound
  but cannot speak the update.
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
| `device_state` | host to device | `owner_device` | `fingerprint`, `state`: `pending`, `approved`, `revoked`, `superseded`, `unanswered` or `full`; `privacy`: `private` or `public` (the key's report; the connection's own for `pending`; absent for `full` and `revoked`) |
| `presence` | device to host | `presence` | `foreground`, `muted`, `away` (booleans) |

The APNs JSON is not a hail frame. It lives in a new `Notify/` type, with its schema in `docs/reply-protocol.md`.

## Files this touches, and sequencing after Part 10

Part 10's privacy stack (#807, #808, #813, S-6) has merged. It changed `WebSocketListener*`, `HostSession`,
`HostReplyDelivery`, the RightyO input files, and `Control.swift`/`Schema.swift` (for `set_privacy`). Its proposed
reconnect work (S-7a0 to S-7c) touches the hello's protocol fields, `WebSocketListener+DuckMode.swift`,
`AmbientAudioGate`, `HostConnectionStore` and the station card.

| Area | Files | Overlap |
| --- | --- | --- |
| Device challenge, proof, re-challenge and presence | a new HostSession command case, a new `Listener/OwnerDevices*.swift` | **HostSession** decodes device commands |
| Owner privacy, quiet and quiet hours (rules 1 and 2) | `LocalSessionUpdate.swift`, `SessionUpdate.swift` | **WebSocketListener**: per-connection privacy readable through `AmbientListenerWiring`, like `mediaMode` |
| Drain and deliver `session_update` (rules 3 and 6) | `Notify/*`, `LocalSessionUpdate.swift`, a new `WebSocketListener+SessionUpdate.swift` | **WebSocketListener**: drain state and peer lookup, like `+MediaMode` |
| Speak an `action` (rules 4 and 5) | the reply audio path | **HostReplyDelivery**: requestless delivery must honour the privacy drop |
| Protocol messages | `Control.swift`, `Schema.swift`, fixtures | **Control.swift and Schema.swift**: S-6a added `set_privacy` there (merged in #815) |
| APNs client, key files, device store, `haild devices` | new `Notify/APNs*.swift`, `Sources/haild/DevicesCommand.swift`, `host.sh` | None |
| App: key, proof, card, notifications, presence, settings | `HailApp.swift`, `HostConnection+Protocol.swift`, `HostConnectionStore.swift`, chat views, `project.yml` | Part 10's privacy switch (merged in #817) and S-7b, in the store |

The stack these build on has merged; owner privacy (slice 3) also waits for S-7.

## Slices

1. **APNs sender:** key files and checks, JWT, HTTP/2, failure handling, `haild doctor`. Synthetic tests against a
   local HTTP/2 stub only; no real push leaves the host until Mick is listening. Can start now.
2. **Owner devices:** the challenge, proof, re-challenge, store and `haild devices`, plus the app's key, proof and
   fingerprint screen.
3. **Owner privacy, quiet and quiet hours** (rules 1 and 2), landing before anything delivers. After S-7.
4. **Updates reach an approved, connected app:** revive the local card branches; drain to approved devices (rules
   3 and 6); a local notification when backgrounded; presence.
5. **Speak `action` updates** on a listening device or a foregrounded app (rules 4 and 5).
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
   ends it, by turning privacy off. Revoking it also clears its report, and someone on the network path could forge
   a clear (Known limits).
   - Answered on 2026-10-22: a reconnect, including the phone rejoining Wi-Fi, never ends privacy (Owner privacy,
     Reconnects).
   - Costs: a phone that drops off while private keeps every device quiet until it comes back and turns privacy off.
     Revoking is permanent (the key never becomes pending again, so the phone re-enrols with a new key). A haild
     restart is the non-destructive way out, since reports live in memory only. After a restart, nothing is pushed
     to a device until it has connected again; a connected Mac still gets rules 4 to 6. A connection that never
     proves protects only itself.
   - Listening privacy stays per connection: a Mac keeps listening in public while the phone is private. Only
     proactive delivery is silenced on every device.
   - Still open: is one private device silencing every device what you want?
4. **Quiet hours:** what window? Should any `action` break through? A breakthrough would need the time-sensitive
   entitlement. Proposed: no breakthrough.
5. **APNs keys:** you create a production key, and optionally a sandbox key, and place them with `apns.json` in a
   directory you choose. Is that right, or would you rather use the Keychain?
6. **Mac pushes:** deferred as above. Is that fine?
7. **Privacy across an app relaunch:** should the app keep your privacy choice when iOS kills it, so the next listen
   asks for privacy first? #809 settled that privacy does not survive a host restart; this is the app being killed,
   with the host still running. Until you decide, a listen you start by hand after a relaunch starts public, except
   on a proven device once the owner-device slice reads its key's report (Reconnects).
8. **Privacy turned on mid-listen that the Mac does not confirm:** today the stream carries on in public after a
   refusal. Proposed: audio pauses while the on waits, and listening stops if it is refused or times out (Reconnects).
   Is that what you want?

## Verification

This is a design document. It records no runtime behaviour. The current state was read from `main` at ea6a387, and
rechecked at 6fabeb2 for this revision:
- the merged #609 queue, `haild notify` and the `session_update` frame;
- `drain` with test callers only, and the connected-device push rule;
- APNs code only for the provider token, request and response classification (#818), with no network client;
- the app's single local notification, the empty iOS entitlements and the unsigned Mac app;
- privacy with no auto-end (`AmbientDuckTimer.timer` is nil for it), and `set_privacy {on}` acted on only with an
  active stream;
- no report of the app's mute state to the host.

The privacy semantics it defers to are Part 10's, merged on `main` (#807, #808, #813, #815 to #817). Part 10 signed
off on this section on 2026-10-22, before Mick's reconnect decision. The reconnect path is Part 10's proposal (S-7a0
to S-7c), which Jarvis put in the privacy deploy set; it is not built. The public resume is Jarvis's answer of
2026-10-22. The restart and reconnect rules follow Mick's 2026-10-22 decisions, and #809 records that privacy no
longer survives a restart. The words "listening is off until he turns it on from the app" and "A network drop should
not change it from being private to being public." are as relayed by Jarvis, not quoted from an issue.
