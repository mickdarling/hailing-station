# Request-origin reply routing

Issue #161 requires replies to a personal request to return only to the requesting
connection, even when another iPhone or iPad selects the same target. A target,
display name, current speaker, or most recently received response is not origin
evidence.

## Request contract and current implementation boundaries

`ReplyDescriptor.requestID` is an optional UUID encoded as `request`. The host
mints it when accepting contextual input and binds it to the actual requesting connection,
selection generation and exact target binding. The same descriptor, including
this request reference, accompanies final text and every audio segment. It is
distinct from the reply ID and audio stream ID. A string supplied by a caller is
not, by itself, proof of any device's ownership.

`haild reply --request <opaque-request-UUID>` now preserves the request reference
across text, static PCM, streamed speech and final markers. Its built-in usage
and synthetic CLI tests cover the flag. Malformed UUIDs are refused before
publication or speech. The CLI must not choose a recipient, search for the latest
speaker, infer an origin, or establish a request merely by accepting a flag.

The field is optional in protocol v1. Existing peers can decode old descriptors
and ignore unknown fields, while omitted request references remain uncorrelated.
An explicitly null, non-string or malformed request is rejected, not silently
downgraded to a legacy reply. Decoding compatibility is not routing compatibility: the
origin-bound publisher never silently broadcasts an ambiguous personal
reply. No new negotiation capability is advertised in this contract-only slice.

Host ingress and publication now enforce connection-owned request identity as
described in [recipient enforcement](request-recipient-enforcement.md). Synthetic
two-client isolation is not physical proof, and a concrete programmatic bridge
is still needed before migrating the live Claude route. Do not close #161.
This describes the source implementation, not the running daemon or installed
TestFlight builds. Admission also requires cooperative binding leases and retains
its original revocable policy/binding tickets through actual network enqueue;
snapshots alone do not establish continuous authority (#167).

## Remaining implementation and proof

1. Integrate and physically validate the implemented bounded ingress ownership
   and recipient checks. Unknown/expired and uncorrelated replies are refused;
   selection changes invalidate requests and reconnect cannot inherit ownership.
2. Integrate a concrete supported programmatic bridge through the explicit
   contextual adapter. Ordinary tmux remains a legacy adapter; no implicit metadata
   prefix, policy grant, capture grant or provider enablement is permitted. The
   one exception is the host-minted ambient reply reference
   ([below](#ambient-reply-references-on-plain-tmux-targets-230)).
3. Prefer a programmatic bridge retaining correlation outside generated text.
   An LLM choosing which valid token to echo can still misassociate output; a
   voluntary CLI bridge must not be described as proven semantic attribution or
   a replacement for host-owned capture. #230 accepts that risk for ambient
   replies on plain tmux targets, where the alternative was no reply at all; the
   echoed reference is a routing handle, never origin evidence. Structured provider groundwork remains
   disabled until its independent live-enablement requirements are met.
4. Test two real listener clients selecting the same target, interleaved requests
   in both orders, early/late replies, refusal/partial delivery, reconnect,
   timeout, replay and stream mismatches. Then validate on the actual iPhone and
   iPad with independently recorded installed version/build and explicit hearing
   confirmation. No transcript, recording or private identifier belongs in the
   public record.

Unsolicited announcements are a different explicit publication scope. They must
not quietly inherit a personal-response recipient or broadcast fallback.

## Ambient reply references on plain tmux targets (#230)

[#230](https://github.com/mickdarling/hailing-station/issues/230) (P0) found that with an iPhone and an iPad both
selecting the same plain `tmux:` target, every ambient reply was refused `notUniqueRecipient`: the pane had no
request reference to send, so the reply fell to the [single-terminal fallback](single-terminal-reply-fallback.md),
which refuses when two connections select the target. The requirement is that a reply goes to the device its
input came from. This section records a deliberate change of doctrine for that one path.

**What changed.** Until now the reply block never named a request UUID, because a session echoing a token is not
trusted origin attribution. For an ambient request to a legacy (plain `tmux:`) target, the host now mints an
opaque **reply reference** and writes it into that prompt's own reply block:

```
haild reply <target> --request <reference> --say '<spoken answer>'
```

The reference is a routing handle, not an origin claim:

- **Plain legacy targets only** (an adapter without contextual delivery, such as `tmux:`). For each admitted
  ambient request to such a target, `WebSocketListener.referenceAmbient` mints a fresh UUID in the daemon. It
  rewrites only the prompt's trailing request-less block for that target (`RightyoInputEvent.referencing`).
  A contextual adapter (`tmux-reply:`, the Codex app-server adapter, any `ProviderContextDelivering`) gets no
  reference and its original block. The UUID never enters a bridge's model prompt, and the bridge keeps its own
  out-of-band context id, as the programmatic-bridge rules above require. The session enforces this too: a
  contextual adapter never adopts a bound reference as its context id.
- The rewrite happens before the fail-closed `ambient-dispatch` audit record, so the record's byte count is the
  size of the prompt actually dispatched. The reference is then bound only for that one dispatch
  (`HostSession.ambientReplyReference`, a task-local). The local socket's
  `dispatch` request kind, `haild rightyo --reply-to`, phone text frames and every other ingress path cannot set
  it, and they are unchanged.
- The connection's own `HostSession` records it in `replyRequests`. The record goes through the same ingress path
  as any request: authorizer, selection generation, exact listed binding, host reply permit, 64-request capacity
  and 120-second lifetime. It is committed only after a successful complete handoff. A reference already held is
  never overwritten.
- The reply path trusts only that host-side record. A reply naming the reference reaches exactly the connection
  that owns the record, while it still selects that target on the same selection generation, with the same media
  pinning (one final text, ordered audio, duplicate frame refusal) as any correlated reply. A reference that is
  unknown or expired, names another target, or whose owner selected away or disconnected, reaches nobody
  (`noRecipient`). An explicit reference never falls back to another connection, whatever the fallback flag says.
- Plain tmux cannot lease its binding (see [reply-binding-leases.md](reply-binding-leases.md)), so the record is
  **unleased**: `HostReplyRequest.bindingLease` is nil, and no lease is invented. In its place, the target's
  listing is re-read before every enqueue (`unleasedBindingIsCurrent`). A rebound, vanished or dead target refuses
  the reply (`publicationFailed`) and drops the record. This check is a snapshot one actor hop from the enqueue,
  not a gate. The host policy permit still gates the enqueue, so policy changes, lockdown and a locked tier revoke
  the record.

**Residual risk.** Correlation is only as good as the session's echo. A session that copies the wrong reference
can misdirect an answer. The only connections that can receive it are ones that sent ambient input to that same
pane within the lifetime and still select it; nobody else can be reached. A reference grants no authority beyond
that delivery. A programmatic bridge that keeps the identity out of generated text (above) remains the stronger
design and is unchanged. Ordinary tmux remains a legacy adapter, and no contextual capability is implied.

**Since #370.** A reply without a reference no longer depends on there being a single selecting connection: it
goes to the target's last input device ([below](#unified-reply-routing-the-last-input-device-370)). Tap-to-talk
text frames to plain tmux still create no request record and get no reference. The sourceHostMismatch
host-identity item in #230 is separate work.

**Optional follow-ups, not in this change:**

- References for tap-to-talk text and for `haild rightyo --reply-to` prompts. #370 made them unnecessary for
  routing between devices; they would still make a late or overlapping reply more precise.
- The app's "disconnect from this Mac" control, and deselecting the reply target when ambient listening is
  turned off.

Verification is synthetic only (`AmbientReplyReferenceTests`, `AmbientReplyReferenceRoutingTests`,
`AmbientReplyReferenceScopeTests`, `AmbientWiringReplyReferenceTests`). It is not device hearing, and nothing here changes the running daemon or
installed builds until deployed.

## Unified reply routing: the last input device (#370)

[#370](https://github.com/mickdarling/hailing-station/issues/370) (P0) makes #230's last-resort rule the default.
Tap-to-talk and ambient listening are two ways into one pipeline, so a reply goes to the device that last sent
input to that session, whichever way it came in. Sessions need no reply instruction, footer or reference for this.
The closed PR #367 tried a footer on typed text; that approach is not used.

**The record.** `WebSocketListener.lastInput` (`LastInputLedger`) holds, per target id, one entry: the connection,
its selection generation and the time. It is host-side only. It is written in exactly two places, both inside
`HostSession.deliver` and only after the handoff succeeded, in the same actor turn that confirmed the captured
selection:

- an ambient request the listener dispatched for the streaming device (`WebSocketListener.dispatchAmbient` binds
  the task-local `HostSession.ambientInputDispatch` for that one dispatch), and
- the device's own final text frame (tap-to-talk), after the session's authorizer admitted it.

A refused, unconfirmed, rate-limited or ownerless handoff records nothing. The local socket's `dispatch` kind
(`haild rightyo --reply-to`) is operator input on a connection's behalf, not that device's input, and records
nothing. No frame field, device name, hello or reply reference can write the record. A newer input to the same
target, from any connection, replaces it.

**Routing a reply.** In the listener's publication path (`HostReplyDelivery.swift`):

1. A reply naming a `request` takes the correlated path unchanged and never falls back.
2. A request-less reply goes to the last input device when that connection is still live and negotiated, still
   selects the target **on the same selection generation** (selecting away and back invalidates it), the entry is
   younger than the lifetime, and the host issues a reply permit for the target's exact listed binding. Selection,
   generation and lifetime are checked again in the actor turn of the enqueue, inside the permit's gate, with the
   same prepared transport as every reply. Several devices selecting the target do not matter on this path.
3. Otherwise the [single-terminal rule](single-terminal-reply-fallback.md) runs unchanged: one selecting
   connection, else `noRecipient` or `notUniqueRecipient`.

Steps 2 and 3 need `--single-terminal-reply-fallback` (set by `scripts/host.sh` from `host.json`). Without the
flag, request-less replies are still refused `noRecipient`, as before.

**Lifetime: 10 minutes.** A reply to a long task can arrive minutes after the input, so the 120-second request
lifetime is too short. Ten minutes covers a long turn, while a device left selecting a target overnight does not keep
receiving its replies by default. Expiry is not a refusal: it hands the reply to the single-selector rule. The entry
ends sooner when its connection disconnects or changes selection.

**One reply, one device.** The first delivered frame of a request-less reply pins that reply to its connection and
selection (64 most recent replies). Its later frames go only there, even if another device sends input mid-reply,
and are refused `noRecipient` rather than moved when that device is gone or selected away. This applies to replies
the single-selector rule started too.

**Audit.** The listener log records `reply_routed` once per reply, with `path=request`, `path=last_input` or
`path=single_selector`. The event
carries only the listener connection id that `session_connected` already logs. No text, target binding or device
name is added.

**Residual risk.** The last input device is a recency rule, not origin evidence. If two devices talk to the same
session within one reply's latency, the answer to the first goes to the second. A request reference, where the
session sends one, still routes precisely. Ambient take-over (#366) may dispatch a request the previous device's
child had already admitted; that dispatch is the previous device's input and makes it the last input device again
until the new device speaks.

Verification is synthetic only (`LastInputReplyRoutingTests`, `LastInputRecordTests`, and the updated
`SingleTerminalReplyFallbackTests`, `AmbientReplyReferenceRoutingTests`, `AmbientWiringReplyReferenceTests`):
loopback devices and a fake tmux-kind adapter, not device hearing. Nothing here changes the running daemon or
installed builds until deployed.

## Explicit programmatic tmux bridge input (prerequisite)

`TmuxReplyAdapter` is a separate `tmux-reply` adapter. It implements the existing
host-local `ProviderContextDelivering` contract, not output observation. The CLI
registers it only when the operator explicitly supplies a nonempty JSON array of
adapter-local session names in `HAIL_REPLY_BRIDGE_TARGETS`. Missing configuration
or an empty array leaves it off; invalid, duplicate, oversized or control-bearing
names fail closed. This is local configuration, never mobile-supplied settings.
It does not implement cooperative `ProviderReplyBindingLeasing`: external tmux
rebinding cannot participate in host publication locks. Consequently personal
contextual ingress refuses this adapter until a concrete supervised bridge owns
the binding authority. A configured session name is not such a lease.

Only named bridge sessions are listed as `tmux-reply:<name>`. Their distinct IDs
require separate exact-binding target policy approval: permission for
`tmux:<name>` does not authorize the bridge target. Generic tmux delivery is
unchanged, and ordinary shell/TUI sessions must not be configured as bridges.
The adapter does not start a bridge, identify one heuristically, create a target
grant, enable capture, register the experimental Codex adapter, or imply that an
existing Claude Code session understands this contract.

After original text passes host sanitization, confirmation, policy and input-shape
checks, contextual delivery sends exactly one JSON line and Enter through the
existing literal, serialized tmux path. The envelope is:

```json
{"request":"00000000-0000-4000-8000-000000000001","text":"synthetic input","version":1}
```

The example is synthetic. `request` is the host-owned `ProviderTurnContext.id`,
not a device name, CLI-selected recipient or client-supplied turn authority.
Connection and private session-binding metadata are not forwarded. Unsupported
legacy delivery refuses without a write; the exact target/pane binding is checked
before sending and again before Enter. Escape remains separately policy-controlled
and bound. No snapshot or output observer is added.

A compatible **programmatic bridge** must parse the envelope, retain its request
UUID outside model prompts and generated text, submit only the original `text`
to a provider or utility, and use that retained UUID when returning actual output
through `haild reply <tmux-reply-target> --request <UUID>`. It must not ask an LLM
to select or echo a routing token, infer a token by latest request/FIFO, or send
raw envelopes into a shell. A future host-owned structured adapter can satisfy
the same correlation boundary without tmux.

**Not yet implemented or validated:** a concrete programmatic bridge process,
provider inference and physical two-client routing. Host ingress and publication
are implemented but the existing live Claude tmux route still lacks programmatic
context retention. Do not enable this profile on a live target or deploy the
prerequisites as a completed #161 fix. Synthetic tests prove configuration,
literal handoff, context/binding refusals, recipient isolation and existing host
policy boundaries only.
