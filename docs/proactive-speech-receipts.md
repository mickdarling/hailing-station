# Proactive speech receipt bound (#609)

This candidate keeps speech authorization separate from visible update cards. It is device-side groundwork,
not a service activation or physical audio proof. Explicitly marked unsolicited audio needs its original
endpoint/update receipt, connection generation, source, target and current playback policy. An ordinary reply
uses its existing separate path.

The store retains at most `ConversationLog.limit` (currently 200) endpoint/update identities, including receipts
that were denied before their first visible card and permits later retired by privacy or another policy edge.
Those identities are never evicted to admit new speech: forgetting a denial could make a delayed duplicate look
newly authorized after privacy clears. A duplicate can only preserve or reduce its retained permission, never
renew it. Privacy off, listening stop/start, disconnect/reconnect and host removal do not clear this history.

At the bound, a new identity gets no speech receipt and its marked audio fails closed. Cards still follow the
normal current privacy/target rules and remain subject to bounded conversation history; an eligible fresh card
can therefore appear without speech. Valid known receipts still work until their existing policy retires them,
and ordinary reply audio keeps working. This is one global bound per `HostConnectionStore`, not per host.

There is no slot reclamation or recovery reset in this slice. Once all 200 identities are retained, new-ID
proactive speech remains unavailable for that store's lifetime. A newly constructed store starts with empty
memory and does not preserve old retirement history; that existing memory-only boundary is not a safe receipt
renewal mechanism. No automatic reset, persistence scheme or new reauthorization policy is introduced here.

Authored synthetic coverage is in `ProactiveReceiptCapacityTests`, with the existing socket, transition and
target-availability suites. It holds privacy/card pressure/replay on one executor and checks the real store,
conversation receipts and playback authorization using a measured injected clock and a silent fake player.
Runtime execution and physical-device validation must be reported separately.
