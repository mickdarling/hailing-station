# Request recipient enforcement

Issue #161. This slice replaces selected-target broadcast with host-minted,
connection-owned correlation. It is not terminal authentication, TLS, a concrete
provider bridge, or physical-device proof.

## Ingress and handoff

For adapters implementing `ProviderContextDelivering` and cooperative
`ProviderReplyBindingLeasing`, each final input gets a
fresh host UUID and `ProviderTurnContext` bound to this HostSession's fresh
connection ID, selection generation and exact listed target/provider/session
binding. The request retains its original policy permit and binding lease, not
freshly reissued tickets on each reply. Neither the Hello name nor a client frame ID supplies recipient
authority. Existing sanitizer, shape, policy and binding checks still run in
`HailHost.send`. Only a successful complete dispatch commits the request.
Failed, partial and confirmation-required dispatches remove its record. Authority
revocation during handoff prevents commitment. Contextual adapters without a
cooperative lease refuse before dispatch; ordinary `tmux-reply` does not yet own
such a lease. A concrete supervised bridge remains required in #166.

Ordinary legacy tmux input still sends literal original text. It cannot create a
private reply owner. Missing, unknown or expired request references deliver to
nobody; there is no legacy broadcast or last-speaker fallback. The only exception
is the default-off, single-phone [single-terminal reply fallback](single-terminal-reply-fallback.md)
(#188), which delivers a reply carrying no request reference at all to exactly
one connection selecting the target; explicit unknown or expired references and
every other case keep these refusals. A locally dispatched prompt
([local dispatch](local-dispatch.md), #188) mints its request through the same
HostSession path on behalf of a named connection id, so its reply is owned like a
spoken one. This is an
intentional publication compatibility change: existing voluntary Claude reply
commands without programmatically retained context no longer produce personal
replies. Do not change the running host until a reviewed programmatic bridge is
configured and the migration is tested.

## Lifetime and media

Each connection retains at most 64 requests for 120 seconds from admission and
at most 1,024 frame IDs per request. Capacity is refused before target dispatch;
expired or permanently revoked admission tickets are reclaimed before a new
handoff, even when no reply was attempted during revocation. Restored authority
can serve a fresh request without stale records exhausting the capacity, but can
never revive the old tickets. Admission and expiry use `ContinuousClock`,
separate from wall-clock wire timestamps. Clock adjustments cannot extend or
prematurely expire ownership. A destination change clears all records, including
partially accepted audio; selecting the same destination again is idempotent.
A new connection never inherits an old connection's records.

Publication composes the retained policy, cooperative binding and peer-transport
permits with final recipient, selection, expiry and media checks in one
non-suspending HostSession turn. Network send enqueue is the publication boundary;
completion is awaited only after releasing the gates. Completed revocation
prevents any subsequent enqueue; already-enqueued bytes cannot be recalled and
may still arrive. Restoring a target/grant cannot revive its old admission tickets,
even if no reply was attempted while it was revoked. The first
valid frame pins the complete reply descriptor; subsequent text/audio cannot
change its reply, stream or request identity. Text is accepted once, audio starts
at zero and advances contiguously to one final segment, and repeated frame IDs
are rejected. Text may precede or follow audio. The same origin owns replayed
local content; a server duplicate never creates a new completion.

The host does not accept output before successful handoff commits. A bridge that
can return output earlier must retry the same frame within a bounded window;
zero recipients is refusal, not success. No early-output buffering or output
capture is introduced here. Authority checks are not disk-policy refresh or
authenticated continuity, and no inference about semantic output attribution is
made. External tmux changes cannot participate in a cooperative gate merely by
being listed repeatedly. No invented lease is granted to them. A programmatic
bridge must retain context outside generated text and own binding invalidation.

## Validation status

At 64 retained live requests, another valid request is refused with the existing
`rate_limited` control code before provider dispatch, not mislabeled `malformed`.
The connection stays open; capacity and expiry limits are unchanged. This code
does not authorize automatic retry. A changed selection is a separate `not_allowed`
refusal and is not confused with capacity exhaustion.

Synthetic direct-session and real two-WebSocket tests cover both request orders,
interleaving, identical display names/frame IDs, unknown/legacy origin, failed and
early handoffs, changed selections, reconnect, lifetime/capacity, pinned media,
duplicate frames and fresh binding/policy refusal. Local Unix endpoint tests
exercise correlated ingress, zero-recipient refusals and audit preservation.
These are not iPhone/iPad hearing or installed-build evidence. #161 remains open
through reviewed integration, migration and controlled physical validation.

PR #173's verify run `36775962913` failed at `e452fee9` with the race harness's
15-second synchronous publication precondition, not PR-shape. Its blocking
HostSession publication job had used the cooperative executor needed by the
test continuation and policy mutation. This scheduling dependency can starve on
a small concurrent runner; the log proves the watchdog failure, not a production
authority defect or physical routing failure.

The harness now assigns only its blocking publication job a test-only private
DispatchQueue TaskExecutor. It asserts from the actual HostSession clock hook
that the job runs on that queue, while policy/binding mutation progresses normally.
The causal order remains: pause before authority acquisition, complete revocation,
release publication, require zero enqueue. The 15-second watchdog is unchanged;
timeout is a recoverable test failure, and error paths release and drain the job.
A direct built-runner check with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` passed
all six race tests, including nonfatal zero-budget barrier timeout coverage. The
restricted setting was applied to the test runner, not SwiftPM/build processes.
No production executor, guard, permit, lifetime or publication behavior changed.
Fresh full verification and exact-head review are still required for the new head.
