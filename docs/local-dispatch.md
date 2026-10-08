# Local dispatch over the reply socket

Part of [#188](https://github.com/mickdarling/hailing-station/issues/188) item 1 (part B), keeping
[#161](https://github.com/mickdarling/hailing-station/issues/161)'s owner-only rule. This slice gives a
locally submitted prompt a reply owner: the host runs the named connection's own ingress path, so the phone
that selected the target hears the answer through the unchanged correlated path. It is source behaviour; the
running daemon and installed builds are unchanged until deployed. The CLI side is `haild rightyo --reply-to`
([rightyo-input.md](rightyo-input.md#reply-ownership-with---reply-to)); the prompt's
[reply block](rightyo-input.md#the-reply-block) tells the AI how to reply.

## Shape

The owner-only local socket (`replies.sock`, 0600 under the 0700 private directory) now accepts a second
request kind on the same one-frame-per-connection, newline-terminated contract:

```json
{"kind":"dispatch","connection":"<peer UUID>","target":"<target id>","binding":"<pinned binding>","text":"<prompt>"}
```

- `connection` is the listener's own peer UUID: the `sessionID` logged on `session_connected` and
  `session_disconnected`. It is minted by the host when the socket is accepted. A Hello `deviceName` is
  never matched; two phones calling themselves the same thing are two different connections.
- `target` must be the target that connection currently selects.
- `binding` is the listing binding the caller saw when it chose the target. It pins the program behind
  the name; a different current binding refuses rather than following the rebind.
- `text` is the prompt, at most 1,200,000 bytes of UTF-8 (`LocalDispatchRequest.maxTextBytes`, the local
  RightyO prompt cap, [#200](https://github.com/mickdarling/hailing-station/issues/200)). It takes the same
  sanitizer, shape, policy, tier, confirmation, rate-limit and lockdown path as a phone utterance through
  `HailHost.send`, except that the sanitizer's length cap is `HailHost.localPromptSanitizing` (1,200,000
  characters/bytes, the direct `haild rightyo` policy) instead of the default 2,000 characters / 8,192 bytes.
  That cap is bound only for the dispatch handoff (a task-local scope set by `HostSession.dispatch`); phone
  text frames keep the default. The dangerous-pattern guard runs on the whole prompt, so its 20 ms per-rule
  budget can make a very large prompt `confirmationRequired` on a slow host (fail closed). The socket line
  cap is `max(frame cap, 2 × 1,200,000 + 4,096)` bytes so JSON escaping fits; a non-dispatch (reply) line over
  the existing frame cap is still answered `frame too large`. The audit `delivered` record names the device
  `rightyo-local`.

A submission without `kind`, or with any value other than exactly `dispatch`, is a reply frame and behaves
as before. A dispatch is audited as `pushed` with tool `local-dispatch` before it reaches the listener and
spends the same 120-per-minute admission budget as replies; a rate-limited request of either kind receives
the shared `{"delivered":0,"error":"rate limited"}` answer.

The response extends the reply response with one field that only dispatch answers carry:

```json
{"delivered":1,"request":"<host-minted UUID>"}
{"delivered":1,"request":null}
{"delivered":0,"request":null,"error":"dispatch refused [unknownConnection]: no live connection has that id","code":"noRecipient"}
```

`request` is the ID the pane receives in the `TmuxReplyAdapter` bridge envelope; the bridge retains it outside
the model prompt and attaches it itself, while the prompt's [reply block](rightyo-input.md#the-reply-block)
asks the session only for a brief spoken answer. `haild reply --request <uuid>` then publishes through the existing correlated path to exactly that connection; a reply carrying
that ID reaches nobody else, and once the record is gone it reaches nobody. Reply responses omit the key
byte for byte as before. `code` reuses the reply vocabulary (`noRecipient` for a connection that cannot be
the recipient, `publicationFailed` for every refusal of a live, selecting connection); `error` names the
exact dispatch reason in brackets. The socket's own refusals (`decodeFailure`, `auditFailure`,
`listenerNotReady`, `internal`) keep their shared code and wording on a dispatch, with `request: null`.

## Gates

Each gate refuses before the handoff; nothing falls back to whichever connection selects the target.

| Refusal | When |
| --- | --- |
| `unknownConnection` | no live peer has that id (never connected, or already removed) |
| `connectionEnded` | the peer is still listed but its transport has ended |
| `sessionNotReady` | the connection has not completed Hello |
| `notAuthorized` | the session's authorizer refuses the final text frame the dispatch builds (judged exactly once, before the listing; its frame id is the utterance id the host receives), so a connection-probe session can never reach `HailHost.send` whatever its selection says |
| `targetNotSelected` | the connection selects nothing or another target; rechecked after authorization, after the listing and, inside `deliver`, again before the handoff, so a `select` that lands while the dispatch is suspended refuses before anything is sent |
| `selectionChanged` | the connection's selection generation moved while the dispatch was suspended, even back to the same target (A → B → A); the generation seen at the first check is required at every later one and is the one `deliver` snapshots, so a reselection revokes the pending dispatch and nothing is sent |
| `bindingMismatch` | the current listing binding differs from the pinned one, or the target is not listed alive |
| `confirmationRequired` | the policy answered with a read-back; the minted record is removed and nothing is delivered |
| `capacityExceeded` | the connection already holds 64 live requests |
| `deliveryRefused` | sanitizer, policy, lockdown, unknown target, a contextual adapter without a cooperative lease, or an adapter failure. A multi-line prompt whose later line needs confirmation or is denied is `HostError.partial`: earlier lines have landed, the minted record is removed, and the answer is still `deliveryRefused` with `delivered: 0` |
| `ownershipLost` | the handoff completed but the selection or authority changed before commit; `delivered` is 1 and `request` is `null` |
| `connectionLost` | the peer ended or began closing, or left the listener's peer table, while the handoff was in flight; the minted record is revoked, `delivered` is 1 and `request` is `null` |

The dispatch and the phone's text frame share one `HostSession.deliver` path: listing, cooperative
binding lease, host reply permit, capacity, lifetime and selection generation, then `HailHost.send`, then
commit only after a successful complete handoff. The pinned binding is checked once before the listing
inside the session and again inside `HailHost.send` (`expectedBinding`), so a rebind between the two
listings refuses too. A dispatched request then lives exactly like a spoken one: 120 seconds from
admission, cleared when the connection selects another target, pruned on disconnect, and never revived
by reselecting or restoring authority.

The dispatch is bound to the peer's own lifecycle (ended, closing, or retired transport) at both ends of
the session handoff (`connectionEnded` before, `connectionLost` after). The handoff itself cannot hold the
peer's transport gate, because the session actor cannot read it synchronously, so a phone that disconnects
while the adapter is accepting the prompt is treated like a spoken utterance in flight at disconnect: the
prompt may still execute, but no owner is reported and no record survives.

The caller's own cancellation (the socket's 10-second submission deadline, or a client that hangs up) is
a separate outcome and never counts as the peer's state. Before the handoff the host refuses the cancelled
caller and nothing is sent; after it, the named connection keeps its ownership and only the answer is
lost: the socket retires the caller without a response and logs that the handoff completed.

## Legacy adapters: no invented lease

For a target whose adapter accepts only legacy generic input (plain `tmux:` sessions), the host delivers
the literal text and reports `"request": null`. No request record exists, no lease is minted, and the
pane has nothing to echo back; the caller must know that no reply ownership was established. This follows
[reply-binding-leases.md](reply-binding-leases.md): external tmux processes cannot be given a
cooperative gate merely by being listed. A contextual adapter that lacks the leasing capability refuses
(`deliveryRefused`) before any handoff, as the phone path does.

## Trust boundary

The reply socket previously carried only output. It now also carries input on behalf of a connection,
and the caller is not authenticated beyond the filesystem: the 0600 socket mode, its uid, and the 0700
private directory are the whole boundary, exactly as for replies. Anything that can write to the socket
can submit a prompt to any selected target as the local owner. The prompt still passes the full sanitizer
and policy path inside `HailHost.send`, so dispatch grants no authority a `haild send` from the same user
would not have; what it adds is reply ownership for the named connection.

## Verification

Synthetic only, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- `LocalDispatchTests` (loopback sockets): with two connections selecting the same target, the dispatched
  reply reaches only the named connection, the other is reachable only by its own id, and the first
  owner's duplicate is refused; the response encoding carries `request` (UUID or explicit `null`) only
  for dispatch answers and round-trips.
- `LocalDispatchRefusalTests` (never-started transports and direct sessions): unknown and ended
  connections, a stopped listener, unnegotiated, unselected and elsewhere-selected sessions, a
  connection-probe session with a forced selection refused `notAuthorized`, a wrong target, a stale
  pinned binding, a rebound target, selection change and lifetime expiry after dispatch, confirmation
  required, the 64-request capacity, a legacy adapter delivering with `request: null`, and a contextual
  adapter without a lease refusing before handoff.
- `LocalDispatchLifecycleTests`: a peer that ends while the adapter holds the prompt has its record
  revoked and answers `connectionLost`, a closing peer refuses `connectionEnded`, a caller cancelled after
  the handoff leaves a live peer's record intact and routable, a caller cancelled before the handoff
  sends nothing, a `select` landing while the dispatch is suspended in the listing refuses before any
  handoff, reselecting the same target (A → B → A) during the listing refuses `selectionChanged` with
  nothing sent and no record minted, and the dispatch authorizes exactly one frame whose id is the
  utterance id.
- `HostReplyRecipientRoutingTests`: a spoken and a dispatched request interleave on one connection while
  a second connection selecting the same target stays silent.
- `LocalReplyEndpointTests`: the exact wire shape over the socket mints an owned request that the pane's
  reply reaches, a `kind: "reply"` frame and a stale connection id refuse in their own shapes, dispatches
  are audited as `local-dispatch`, a legacy adapter answers `request: null`, `ownershipLost` answers
  `delivered: 1` with explicit null `request` and its named reason, and both kinds share the admission
  budget. `LocalDispatchTests` also pins the response encoding (`request` only on dispatch answers).
- `LocalDispatchCapTests` (#200, direct sessions): a 1 MiB dispatch is delivered while a 2,001-character phone
  frame on the same session is refused; a dispatch over 1,200,000 characters is refused; a 3,000-character
  dispatch carrying a default dangerous pattern is `confirmationRequired`, the same decision the direct
  `haild rightyo` host gives; a locked tier and host lockdown refuse a large dispatch.
  `LocalReplyEndpointTests.mebibyteDispatchCrossesTheSocketWhileReplyFramesKeepTheirCap` sends a fully
  JSON-escaped 1 MiB prompt (a ~2 MiB line) over the socket and sees it delivered, and a reply line over the
  frame cap is still answered `frame too large`.

No device, running daemon or installed build is involved.

The CLI client (`RightyoSocketDispatcher` in `haild`) sends this shape for each admitted RightyO request and
maps the answer as documented in [rightyo-input.md](rightyo-input.md#reply-ownership-with---reply-to):
`delivered: 1` with a `request` is an owned reply, with `null` is "no reply ownership" (the daemon's reason,
if any, is noted on stderr), and a refusal keeps the direct path's exit code where the outcome is the same
(`confirmationRequired` 8, `bindingMismatch` 7) and otherwise exits 1 with the daemon's reason. The client
refuses a prompt over `RightyoSocketDispatcher.maxPromptBytes` (266,400 bytes: what the daemon can fill into its paste
buffer within 4 s of its 10-second submission deadline, the rest kept for the 5 s paste-acceptance wait and 1 s of
margin, #304; never above the daemon's 1,200,000-byte dispatch cap,
[#200](https://github.com/mickdarling/hailing-station/issues/200)) before connecting and says why. When a dispatch's
submission deadline fires during delivery, the tmux adapter either abandons it before its commit point
(no further chunk, no Enter, typed text left unsubmitted with no rollback) or, once committed, sends the Enter
anyway. A pane left holding typed-but-unsubmitted text is tainted: every later delivery to it, queued or new,
refuses before typing (`deliveryRefused`) until the pane is cleared by hand and `haild` restarted
(`TmuxTaintedPaneTests`). The client reports a written-but-unanswered dispatch as an unknown outcome and says to check the pane
before retrying (`TmuxDeliveryCommitTests`,
`LocalReplyEndpointTests.timedOutDispatchNeverPressesEnterAndARetryRefusesOnTheTaintedPane`, slow scripted runner).
`LocalDispatchProductionAdapterTests` (scripted runner, no tmux process) dispatches 1 MiB through the
production `TmuxAdapter` and sees the whole text chunked into the pane, and shows a `tmux-reply:` bridge
target refusing a dispatch before any text at 16 bytes and at 1 MiB (it grants no reply-binding lease).
