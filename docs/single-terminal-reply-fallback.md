# Single-terminal reply fallback

Part of [#188](https://github.com/mickdarling/hailing-station/issues/188) item 1 (part A), keeping
[#161](https://github.com/mickdarling/hailing-station/issues/161)'s owner-only rule as the default. This is
a demo-era bridge for one phone and one Mac, not a return to selected-target broadcast and not physical
proof. It is source behaviour; the running daemon and installed TestFlight builds are unchanged until
deployed.

## Why

Since #161 a reply is delivered only to the connection that owns the correlated request ID. `haild reply
--say …` without `--request`, or with an ID nobody holds, reaches nobody. `haild rightyo <target>` submits
a prompt with no reply owner at all, so the ambient path (RightyO → request in the pane → the AI runs
`haild reply --say`) produced no voice on the phone. The next slice gives `haild rightyo` request ownership
(`--reply-to`); until then this fallback lets the single-phone demo hear its answer.

## The rule

With `haild run … --personal-terminal --single-terminal-reply-fallback` (off by default, and refused
without `--personal-terminal`), the listener handles an **uncorrelated** reply as follows. Uncorrelated
means the descriptor carries no `request`, or carries one that no live connection currently holds
(unknown, or expired after the 120-second request lifetime).

1. The correlated scan runs first, unchanged. A reply whose request is owned by a connection goes only to
   that owner, pending handoffs still answer `requestPending`, and ambiguous owners still answer
   `notUniqueRecipient`. The flag never changes a correlated reply's recipient.
2. If no owner exists, every live negotiated connection is asked whether it currently selects the reply's
   target and whether the host would issue a reply permit for that exact target binding right now.
3. **Exactly one** selecting connection receives the reply. Zero selecting connections answers
   `noRecipient`; two or more answer `notUniqueRecipient`. Both are the existing refusal codes, logged and
   returned over the local reply socket the same way; neither permits retry.
4. A connection that holds a current record for the reply's request is reported as the owner even when the
   correlated path refused the frame (duplicate frame ID, wrong audio sequence, pinned descriptor
   mismatch). The fallback never second-guesses that refusal: the result is `noRecipient`, not delivery.

The check lives in the listener's publication path (`HostReplyDelivery.swift`). It reads the existing
`WebSocketListener.peers` set and each `HostSession`'s `selectedTarget`, `state` and `replyRequests`;
no second registry or selection cache is introduced.

## Gates that still apply

- **Policy and lockdown**: the fallback asks `HailHost.replyPublicationPermit(for:)` for the target's exact
  listed binding. A denied target, a `locked` tier, a rebound session, unusable policy or engaged lockdown
  yields no permit, so the connection is not a candidate and the reply is refused before any enqueue. The
  permit is re-issued at enqueue time and the enqueue runs inside its gate, so a revocation that lands
  between the snapshot and the enqueue refuses too (`publicationFailed`).
- **Selection**: a connection whose selected target differs is never a candidate, and selection is
  rechecked in the same actor turn as the enqueue. A connection that has not selected anything is not a
  candidate.
- **Transport**: a retiring or closed peer cannot be the single recipient; the same prepared-transport
  permit and completion handling as correlated delivery are used.
- **Rate limit and shape**: the local reply socket's admission budget, audit record, frame size, provenance
  (`source` must be this host) and descriptor validation run before the fallback is consulted, unchanged.

Like the correlated scan, the single-connection decision is an admission snapshot across actors, not a
transactional directory: a second phone selecting the target between the scan and the enqueue is a race
the existing design also accepts. Uncorrelated replies have no retained request record, so there is no
host-side pinning of reply, stream or request identity across their frames; the terminal's own
descriptor and `streamId` checks ([reply protocol](reply-protocol.md)) remain the guard against
cross-reply contamination. Operate this flag only on a host with a single terminal.

## Not in this slice

- `haild rightyo --reply-to <connection>` request ownership (next slice). The RightyO prompt does not yet
  name the target or the reply command; that file would have exceeded the four-production-file limit here.
- `haild` usage text for the new flag (same limit); the daemon option parser is covered by tests.
- Live or physical proof. Nothing here changes the running daemon, any device or an installed build.

## Verification

Synthetic only, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- `SingleTerminalReplyFallbackTests` (loopback sockets): the only selecting connection receives text, audio
  and an unknown-request reply while a second connection on another target hears nothing; a correlated
  reply still reaches its owner and the owner's refused duplicate is `noRecipient`; with two connections
  selecting the target a correlated reply reaches its owner and an uncorrelated one is
  `notUniqueRecipient`; the flag is off by default; the option requires `--personal-terminal`.
- `SingleTerminalReplyFallbackRefusalTests` (never-started transports): zero selecting connections,
  three selecting connections, a known request's media refusal, lockdown, deny, locked tier, rebound
  binding and deselection each refuse before any enqueue; an expired request becomes uncorrelated again.
- Existing reply suites (`HostReplyDeliveryTests`, `HostReplyRecipientRoutingTests`,
  `CorrelatedReplyPublicationTests`, `LocalReplyEndpointTests`) are unchanged and pass with the flag off.
