# Final delivery authority

Part of #1120. Tighten final delivery authority checks at the adapter handoff.

Final delivery authority includes a live-peer token and, for a fresh reply owner, its original reply
permit, cooperative binding lease when present, and ordinary request lifetime. The clock must remain
at or beyond creation and strictly inside that lifetime. The existing `DeliveryAuthority` carries these
synchronous checks through the registry to the adapter. Checks hold only short authority gates and
never span adapter I/O or an asynchronous wait.

The peer token uses the existing terminal reply-transport lifecycle. WebSocket receive and local
dispatch entry points retain that token. Ambient dispatch, local socket dispatch and the
`rightyo --reply-to` dispatch path share the peer entry point; phone text uses the receive entry point.
Listener shutdown retires every peer token before its first suspension. Transport close and terminal
connection callbacks retire the same lifecycle.

Session delivery composes the fresh owner's original tickets and clock with the retained peer token.
It preserves any existing task-progress handoff closure, using the existing `beforeHandoff` composition
hook already captured by HailHost's `DeliveryAuthority`. This keeps the change within four production
files without introducing another adapter contract. Post-handoff ownership commit remains required.
Refusal uses the existing outcome vocabulary and removes uncommitted ownership state.

Legacy ambient references retain their existing unleased binding contract: final authority checks the
reply permit and lifetime, while existing listing and adapter binding checks apply. Generic legacy
input has no fresh reply owner; its peer token and existing policy authority still apply. Direct
HailHost callers without a peer or fresh reply owner retain their existing authority contract.

`FinalDeliveryAuthorityTests` uses synthetic adapters, never-started transports, injected clocks,
continuation barriers and a loopback phone-text connection. It covers final transport authority at
registry and adapter boundaries, final reply authority (lease, permit, lifetime and clock), current
ambient and local dispatch authority, and the legacy ambient-reference lifetime boundary.
The permit case uses the existing internal reply-authority retirement boundary and independently
confirms that the input policy generation remains current. Existing tests are unchanged.

## Rebase and held Send

Rebased onto `9aa07edd319913264d86f863465c2e0501799ba3`, retaining the host held-request store.
Ambient read-backs are held only when the originating session negotiated `held_requests`; other sessions
retain cancellation and refusal. Reservation follows evaluation that requires a hold. Held Send and
Discard retain their existing scopes and paths.

Held Send carries the same final delivery authority as ordinary dispatch: a retained live-peer token
and the fresh reply owner's permit, lease and lifetime through the session's `beforeHandoff` hook.
The held confirmation hash remains part of `sendAuthorized`. The fixed nested gate order is reply
permit, binding lease, peer token, then clock. Those gates release before the prior task-progress
hook runs; HailHost subsequently checks held policy, selection, permission and notice lifetime through
the same `DeliveryAuthority`. No gate is acquired twice within a nested critical section. Peer close,
transport close and listener shutdown continue to retire the peer token synchronously.

`FinalDeliveryHeldAuthorityTests` exercises current held Send and independent final peer/reply authority,
plus held notice expiry and selection at a suspended adapter handoff. All fixtures are synthetic.

## Verification

The earlier branch snapshot `38a4096ac5a060f5e837af6145f5ca2ed3dddc13` passed 919 tests in 168 suites
with 10 expected known issues, plus 124 reply CLI tests. Rebased-source verification is recorded below
when complete. These earlier counts do not establish the rebased source's results.
