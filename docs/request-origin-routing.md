# Request-origin reply routing

Issue #161 requires replies to a personal request to return only to the requesting
connection, even when another iPhone or iPad selects the same target. A target,
display name, current speaker, or most recently received response is not origin
evidence.

## Additive contract, not a shipped routing fix

`ReplyDescriptor.requestID` is an optional UUID encoded as `request`. The host will
mint it when accepting a request and bind it to the actual requesting connection,
selection generation and exact target binding. The same descriptor, including
this request reference, accompanies final text and every audio segment. It is
distinct from the reply ID and audio stream ID. A string supplied by a caller is
not, by itself, proof of any device's ownership.

`haild reply <target> --request <opaque-request-UUID> --say <text>` preserves the
reference across text and streamed PCM. `--text` and `--pcm16` use the same
descriptor. Malformed UUIDs are refused before publication or speech generation.
The CLI does not choose a recipient, search for the latest speaker, infer an
origin, or establish a request by accepting this flag.

The field is optional in protocol v1. Existing peers can decode old descriptors
and ignore unknown fields, while missing/null request references remain
uncorrelated. Decoding compatibility is not routing compatibility: the future
origin-bound publisher must never silently broadcast an ambiguous personal
reply. No new negotiation capability is advertised in this contract-only slice.

**Current limitation:** the existing listener still publishes by selected target.
Adding the field and CLI flag does not prevent cross-device playback. Do not
deploy this slice as a completed #161 fix or close the issue.

## Remaining implementation and proof

1. Establish host-owned bounded request admission and immutable origin at wire
   ingress. Reject unknown/expired tokens, stale selection/binding generations,
   and uncorrelated personal replies. Disconnect never transfers a pending reply
   to a new peer. Final text and the complete audio stream keep one recipient.
2. Carry context through an explicitly supported adapter handoff. Ordinary tmux
   shell/TUI input must not gain a metadata prefix implicitly. Preserve policy,
   sanitizer, input-shape and exact-binding preflights before side effects.
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
