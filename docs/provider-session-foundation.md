# Host-local provider event foundation

Implementation slice [#137](https://github.com/mickdarling/hailing-station/issues/137), part of [#132](https://github.com/mickdarling/hailing-station/issues/132) and [#94](https://github.com/mickdarling/hailing-station/issues/94).

## Implemented scope

`HailDaemonKit` now defines immutable provider session bindings, turn contexts, observed events, a replaceable observation interface, a bounded event channel, and a deterministic turn correlator. These are **host-local library contracts**, not new protocol v1 payloads. No observer is registered with the daemon; no live target is captured, no captured output is published, and no installed mobile app changes behavior from this slice.

The event contract distinguishes provider acceptance, running, text delta/final with explicit visibility, explicit lifecycle finish, interruption, and fixed failure reasons. A successful authorized write is only **sent**; a final text chunk does not finish a turn. An explicit provider finish says the lifecycle ended, not that every requested effect succeeded. There is no LLM dependency or speech generation policy in this component.

## Correlation invariants

- Each binding names host, provider, target, session, and a fresh observation generation. Each turn also names utterance and terminal connection generation. These are correlation labels, not authenticated identities.
- Register a fresh turn only after authorized dispatch reports a successful write. Events echo the exact registered context. No arrival-order attribution, fallback to the active turn, or replacement of a timed-out turn is allowed.
- Missing/unknown contexts stay explicitly unassociated. A timed-out turn stays timed out; later output cannot complete it or a newer turn. Connection/utterance mismatches, replaced bindings, invalid transitions, and post-terminal events are rejected.
- Observation sequence starts at zero and increases without gaps. A gap rejects the event until missing predecessors arrive; it never invents lost content. Duplicate IDs and stale sequence numbers are rejected. Structurally valid ordered events consume their sequence even when their lifecycle or turn attribution is refused.
- Turn/context and event-ID retention are bounded, including completed and expired tombstones. Capacity exhaustion is explicit, with no silent eviction or sequence reset. A caller must end the old observation, provide fresh observation identity, and explicitly report any gap/failure before replacing the correlator. This slice does not implement that orchestration or persistence.
- Text and identifiers have UTF-8 byte limits. Internal text remains labeled internal; correlation is not disclosure approval. No renderer/publisher consumes these events yet, so this is not a sanitization or secret-filtering guarantee.

The owning actor/task serializes the value-type correlator. Deadline scheduling is supplied by the future coordinator using a monotonic clock; the library does not guess timing. `ProviderEventChannel` has bounded buffering; overflow terminates with an explicit error rather than silently dropping final/failure markers. Observer implementations must use consumer termination to cancel upstream work.

## Verification and next slices

Synthetic-only tests cover field bounds, lifecycle distinctions, repeated late replies, reconnect/utterance isolation, all binding fields, duplicate/reordered events, missing predecessors, capacity, internal visibility, interface replacement, overflow, and termination callbacks. These tests are not live-session or physical-device validation.

Follow-on work must implement the input coordinator and actual provider observers; negotiate turn/events on the wire with legacy-safe behavior; enforce terminal authentication, confidential transport, authorization and output disclosure; apply programmatic display/speech policy; integrate vbsay; and show correlated session progress on mobile. The existing tmux delivery, snapshots, explicit `haild reply`, and protocol fixtures are unchanged. The source marketing version advances to 0.1.4 under the project's per-change versioning policy; this slice uploads or installs no TestFlight build. #132 and #94 remain open.
