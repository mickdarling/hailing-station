# Correlated publication refusal prerequisite

Part of #166 and #161. Source-only, synthetic groundwork; not a deployed host,
concrete diagnostic bridge, Claude integration, TestFlight update or physical proof.

Before attempting a reply enqueue, the listener takes side-effect-free admission
snapshots for its current peers. A snapshot checks connection/selection generation,
protocol version, request lifetime, media identity/sequence and the original retained
policy and cooperative binding tickets. It checks media on a copy, without pinning
a descriptor or consuming a frame. Peer transport preparation is checked before
and after the session hop; terminal retirement refuses eligibility even before
its Network callback has marked the peer ended. These preparations never enqueue.
Exactly one eligible owner must be found,
including a valid owner whose handoff is still pending. Zero or ambiguous owners
are refused before any enqueue attempt. Never use display names or latest speakers.

Ownership originates in fresh host-minted request UUIDs. This scan is not a
transactional global owner directory or a proof against UUID collisions. The
admission snapshots may become stale at any subsequent actor hop. Only the selected
peer is then attempted; its final synchronous recipient/media checks and retained
policy → binding → transport gates remain the actual publication boundary. A
snapshot is never carried forward as authority. Completed revocation prevents later
enqueue, while already-enqueued bytes cannot be recalled.

The owner-only endpoint adds an optional `code` to its existing response:

- `requestPending`: exactly one valid uncommitted request and zero enqueue attempts.
- `noRecipient`: no eligible request, including legacy/unknown/expired, wrong media
  or version, changed selection, disconnected origin, failed handoff or revoked tickets.
- `notUniqueRecipient`: multiple eligible owners, with zero enqueue attempts.
- `publicationFailed`: final publication refusal or transport completion failure;
  the outcome may be ambiguous, so it is **not** retryable.

Only explicit `requestPending` with `delivered: 0` permits a bounded retry of the
identical encoded frame/descriptor. Missing codes from older hosts, human-readable
messages, rate limits, unknown requests, timeouts and send failures are not retry
permission. This slice does not yet implement CLI retries. Endpoint success requires
exactly one delivery; zero is no longer successful submission. Endpoint admission,
audit and timeout bounds remain in effect for every attempt.

`CorrelatedReplyPublicationTests` uses synthetic adapters and never-started
transports to prove pending/commit/failure behavior, zero-effect duplicate-owner
refusal, invalid/expired/rebound/revoked/changed-selection rejection, media preservation
and stale-snapshot rechecks. Existing loopback tests prove real socket isolation
and the local refusal wire codes. None establishes physical device hearing or
programmatic provider correlation. Keep #161 and #166 open through their remaining
CLI, concrete default-off diagnostic bridge and controlled physical validation.

## Verification harness repair (#174)

Fresh full verification encountered an uncaught `superseded` error in the unchanged
audio lifecycle suite. Its test constructed deactivation and activation tasks and
released the backend without acknowledging their actual controller admission.
Task construction order is not actor-entry order; the failure did not establish
a production audio regression or the historical scheduler's exact execution trace.

The test-only repair snapshots lifecycle generation, desired active state and queued
waiter count in one actor turn. Each intended admission is acknowledged before the
next request or backend release, with a monotonic watchdog instead of sleeps or a
fixed yield count. Original cleanup histories and later-activation-wins assertions
remain unchanged. A deliberately reversed admission order proves both activations
are superseded and the final state is inactive; both stale activation cleanups and
the deactivation are reflected in its history. A forced expired-watchdog case proves
held work can still be released and drained. Every retained operation is released
and drained on acknowledgement failure. No production audio source is changed.

`AudioSessionLifecycleTests` covers this separate test-harness issue. Normal full
verification, simulator build and uncached strict lint remain required on the
finished PR head; this repair is not permission to waive checks or physical proof.

## Guard language fixture contract (#176)

CI also reported an extra `disk write` hit for the synthetic `truncate log` language
fixture. The production matcher deliberately treats its 20 ms deadline as a hit,
even when a rule does not match; the CI output did not record the matching clock
or establish the historical scheduling sequence.

Exact language and multiline fixtures now use the existing explicit matcher budget
with a generous five-second **test-only** deadline, preserving every complete
ordered expectation. A separate exhausted-budget default-rule test independently
proves its input has no regex match, then expects a conservative hit with a zero
deadline. Production rules and the 20 ms default are unchanged, as are invalid-rule,
custom exhausted-budget and bounded worst-case tests. The semantic fixtures do not
measure production latency; dedicated budget tests exercise fail-closed behavior.
