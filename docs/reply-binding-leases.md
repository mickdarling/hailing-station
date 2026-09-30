# Cooperative binding leases and prepared replies

Issue #167 adds optional prerequisites for the #161 publication boundary. These
APIs do not themselves connect a live bridge, route a device reply, authenticate
a client, enable capture, or claim that physical testing has succeeded.

## Exact cooperative binding authority

`ProviderReplyBindingLeasing` is an explicit optional adapter capability. Its
`acquireReplyBindingLease` operation returns a `ProviderReplyBindingLease` naming
the exact requested `ProviderSessionBinding`: host, provider, target, session and
observation identities must all match. Registry acquisition resolves only the
registered adapter for that target, rejects unsupported capabilities or wrong
identities, and checks cancellation before and after the asynchronous handoff.
A lease already revoked during acquisition is rejected.

The lease wraps the existing `ReplyPublicationPermit`; it does not implement a
second lock or revision system. A cooperating provider must invalidate its old
authority **before** replacing or retiring the managed binding. New authority
can issue a new lease, but restoring a session name cannot revive an old permit.
Different provider instances own independent gates.

A lease-acquisition check is not a promise that the binding will remain valid
after another actor hop. The final synchronous operation must execute inside
`performIfCurrent`, together with the host policy permit and transport gate.
Keep a consistent policy → binding → transport gate order, never reenter a gate,
and never wait for an asynchronous operation or network completion inside it.

Neither `TmuxAdapter` nor `TmuxReplyAdapter` implements this capability. External
tmux processes can rebind without participating in a host lock; polling and
cached listings cannot provide an instantaneous lease. Unsupported adapters fail
closed for lease acquisition. Their ordinary input, Escape and capture paths are
unchanged. A supervised cooperative bridge remains separate work under #166.

## Prepared transport ticket

`WebSocketPeer.prepareReplyPublication` encodes a frame without sending it and
captures a permit from that peer's independent transport authority. Peer closure
invalidates that authority before cancelling the connection. A prepared ticket
therefore cannot enqueue after a completed closure.

`PreparedWebSocketReply.enqueue()` synchronously submits at most once, inside
the current transport gate. A false return makes no transport submission. A true
return means enqueued, not delivered or heard. `result()` receives the later
transport outcome, buffering a completion that arrives before the waiter.
Completion and cancellation settle the result once; cancellation before an
outcome invalidates transport authority and cancels the connection. No gate is
held while waiting. Only one pending result waiter is supported; additional
concurrent waiters fail closed rather than replace the original continuation.

Recipient integration must perform its final local selection/request/expiry
checks and media-state commit with the actual synchronous enqueue, using these
permits. It must not carry a previously validated Boolean across another actor
hop and treat it as current authority. Already-enqueued bytes cannot be recalled
by later revocation.

## Synthetic evidence only

`ProviderReplyBindingLeaseTests` covers exact identity, independent provider
gates, cooperative rebind/restoration, unsupported tmux capabilities, and
revocation/cancellation during gated acquisition. `PreparedWebSocketReplyTests`
covers one-shot enqueue, early completion buffering, refusal, cancellation and
peer closure. Synthetic senders are injected; the peer-closure case never starts
its network connection. These are not live tmux, device-hearing or TestFlight
delivery evidence, and do not close #167 or #161 on their own.
