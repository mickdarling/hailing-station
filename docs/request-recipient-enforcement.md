# Request recipient enforcement

Issue #161. This slice replaces selected-target broadcast with host-minted,
connection-owned correlation. It is not terminal authentication, TLS, a concrete
provider bridge, or physical-device proof.

## Ingress and handoff

For adapters implementing `ProviderContextDelivering`, each final input gets a
fresh host UUID and `ProviderTurnContext` bound to this HostSession's fresh
connection ID, selection generation and exact listed target/provider/session
binding. Neither the Hello name nor a client frame ID supplies recipient
authority. Existing sanitizer, shape, policy and binding checks still run in
`HailHost.send`. Only a successful complete dispatch commits the request.
Failed, partial and confirmation-required dispatches remove its record.

Ordinary legacy tmux input still sends literal original text. It cannot create a
private reply owner. Missing, unknown or expired request references deliver to
nobody; there is no legacy broadcast or last-speaker fallback. This is an
intentional publication compatibility change: existing voluntary Claude reply
commands without programmatically retained context no longer produce personal
replies. Do not change the running host until a reviewed programmatic bridge is
configured and the migration is tested.

## Lifetime and media

Each connection retains at most 64 requests for 120 seconds from admission and
at most 1,024 frame IDs per request. Capacity is refused before target dispatch;
expired records are reclaimed. Admission and expiry use `ContinuousClock`,
separate from wall-clock wire timestamps. Clock adjustments cannot extend or
prematurely expire ownership. A destination change clears all records, including
partially accepted audio; selecting the same destination again is idempotent.
A new connection never inherits an old connection's records.

Publication rechecks the current listed exact binding and the host's in-memory
policy/failure/lockdown atomically. An observed binding or permission refusal
retires the record, so restoring the target/grant does not revive it. The first
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
made. A programmatic bridge must retain context outside generated text.

## Validation status

Synthetic direct-session and real two-WebSocket tests cover both request orders,
interleaving, identical display names/frame IDs, unknown/legacy origin, failed and
early handoffs, changed selections, reconnect, lifetime/capacity, pinned media,
duplicate frames and fresh binding/policy refusal. Local Unix endpoint tests
exercise correlated ingress, zero-recipient refusals and audit preservation.
These are not iPhone/iPad hearing or installed-build evidence. #161 remains open
through reviewed integration, migration and controlled physical validation.
