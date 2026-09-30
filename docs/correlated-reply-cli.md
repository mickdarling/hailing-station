# Correlated reply CLI refusal and retry

Part of #166 and #161. This is local-client delivery behavior, not live provider
enablement, terminal authentication, installed-build or physical hearing proof.

`haild reply` requires exactly one recipient for each text or audio frame. Zero,
multiple or negative delivery counts fail; they are not successful completion.
For spoken replies the text frame is submitted first. A refused text frame stops
the command before `vbsay` is invoked. A renderer failure after accepted text
remains a visible failure; it does not fabricate successful audio delivery.

Only a response with typed `code: requestPending` and `delivered: 0` is retryable.
That code promises no enqueue occurred while a unique request's handoff was still
uncommitted. The client reuses the exact encoded bytes, frame UUID, timestamp and
reply/stream/request descriptor. It waits 100 milliseconds between attempts,
allows at most eight transactions and starts no retry outside the two-second
monotonic retry window. The existing individual transaction timeout is separate:
a timeout or lost acknowledgement is ambiguous and never retried automatically.
The deadline is rechecked after the awaited backoff and immediately before each
retry transaction; delayed task resumption cannot extend the window. Causal
injected-clock tests advance time during and after the backoff, without relying
on real sleeps or scheduler load, and cover cancellation and the attempt cap.
The real-socket perpetual-pending fixture asserts one through eight identical
attempts and a visible failure: the deadline can expire before the count cap.
A causal injected-clock fixture separately proves exactly eight permitted attempts
and seven waits while time remains, with a ninth attempt refused. An earlier
exact-eight wall-clock fixture failed at five attempts during full verification;
it was a test-contract error, not permission to extend the production retry window.

Unknown/stale/expired origin, non-unique recipients, failed dispatch/publication,
rate limiting, untyped errors, unknown codes and socket failures are not pending.
Contradictory pending responses with a positive delivery count fail without
retry. The previous unbounded string-matched rate-limit retry is removed.
Retries still consume the endpoint's existing admission budget; no limit is
expanded or bypassed. An acknowledgement is transport completion, not proof of
playback or hearing.

Synthetic CLI tests use a private fake Unix endpoint and fixture speech renderer.
They cover pending then committed, pending then failed handoff, exact-byte retries,
bounded perpetual pending, contradictory/count/unknown refusals, lost responses,
no speech generation after zero recipients, shared audio sequence/descriptor and
missing renderer failure. They do not use real providers, devices or speech.
