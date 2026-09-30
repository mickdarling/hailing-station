# Request-origin reply routing

Issue #161 requires replies to a personal request to return only to the requesting
connection, even when another iPhone or iPad selects the same target. A target,
display name, current speaker, or most recently received response is not origin
evidence.

## Request contract and current implementation boundaries

`ReplyDescriptor.requestID` is an optional UUID encoded as `request`. The host will
mint it when accepting a request and bind it to the actual requesting connection,
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
downgraded to a legacy reply. Decoding compatibility is not routing compatibility: the future
origin-bound publisher must never silently broadcast an ambiguous personal
reply. No new negotiation capability is advertised in this contract-only slice.

Host ingress and publication now enforce connection-owned request identity as
described in [recipient enforcement](request-recipient-enforcement.md). Synthetic
two-client isolation is not physical proof, and a concrete programmatic bridge
is still needed before migrating the live Claude route. Do not close #161.

## Remaining implementation and proof

1. Integrate and physically validate the implemented bounded ingress ownership
   and recipient checks. Unknown/expired and uncorrelated replies are refused;
   selection changes invalidate requests and reconnect cannot inherit ownership.
2. Integrate a concrete supported programmatic bridge through the explicit
   contextual adapter. Ordinary tmux remains unchanged; no implicit metadata
   prefix, policy grant, capture grant or provider enablement is permitted.
3. Prefer a programmatic bridge retaining correlation outside generated text.
   An LLM choosing which valid token to echo can still misassociate output; a
   voluntary CLI bridge must not be described as proven semantic attribution or
   a replacement for host-owned capture. Structured provider groundwork remains
   disabled until its independent live-enablement requirements are met.
4. Test two real listener clients selecting the same target, interleaved requests
   in both orders, early/late replies, refusal/partial delivery, reconnect,
   timeout, replay and stream mismatches. Then validate on the actual iPhone and
   iPad with independently recorded installed version/build and explicit hearing
   confirmation. No transcript, recording or private identifier belongs in the
   public record.

Unsolicited announcements are a different explicit publication scope. They must
not quietly inherit a personal-response recipient or broadcast fallback.

## Explicit programmatic tmux bridge input (prerequisite)

`TmuxReplyAdapter` is a separate `tmux-reply` adapter. It implements the existing
host-local `ProviderContextDelivering` contract, not output observation. The CLI
registers it only when the operator explicitly supplies a nonempty JSON array of
adapter-local session names in `HAIL_REPLY_BRIDGE_TARGETS`. Missing configuration
or an empty array leaves it off; invalid, duplicate, oversized or control-bearing
names fail closed. This is local configuration, never mobile-supplied settings.

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
