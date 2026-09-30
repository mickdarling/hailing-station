# Host-local owned provider observation

Implementation #141, following contextual dispatch #145. Current source version 0.1.18. This is an executable synthetic host-local driver, not a shipped real-provider observer, speech renderer, mobile output feature or authenticated transport.

## Entry and authority

Trusted host composition calls `HailHost.withObservedSession(target:configuration:operation:)`. Registry resolves the actual registered adapter, which must opt into both `ProviderContextDelivering` and `ProviderSessionObserving`; unsupported mode fails before input writes, without a legacy fallback. The owner accepts only contextual input configuration. Existing legacy adapters and dispatch remain unchanged. There is no listener or reply endpoint calling this factory.

The factory derives the exact opaque adapter binding from a fresh authorized listing, rather than accepting a caller's session identity. `hostID` is a trusted local label, not authenticated identity or a policy grant. Each scope has fresh immutable observation and connection identities. Adapter observation and contextual delivery must enforce the passed exact binding immediately before their own side effects, including later commit actions. A host listing cannot replace that adapter obligation.

Capture authority is separate from input tiers. Observation requires the current exact-binding capture grant and no lockdown; `.locked` input may still have a separate capture grant, but input remains denied. Every capture check performs a fresh listing followed by a forced policy-store refresh. Checks run before observation starts, after suspended startup, before each observed event, before and after coordinator ingestion, and before consumer delivery of retained output. A denied/replaced binding, lockdown or unavailable policy closes authority and purges content. Startup failure cancels the acquired lease before entering the consumer.

Idle monitoring uses an injected monotonic clock and suspension function. The default poll interval is 250 ms; accepted intervals are strictly positive and at most one second. Revalidation is attempted each interval while active; this is not a wall-clock deadline when an adapter's listing or policy I/O itself is noncooperative. Parent, submit and consumer cancellation synchronously cancel the lease without waiting for that I/O, then close actor state.

## Dispatch, retention and evidence

`submit` uses the unchanged focused `ProviderInputCoordinator` and the real guarded contextual HailHost path: sanitization, fresh binding, input policy, confirmation, lockdown, rate limit and cancellation. Input and event reconciliation serialize across actor suspension; concurrent input is refused. A proposal is not `sent` until all input lines complete. Buffered events keep their original identities, exact context and provider sequence; association is never inferred from arrival order. Failed/partial input preserves original errors or known delivered-line evidence and leaves its proposed output explicitly unknown/unassociated.

The owner bounds the combined early, ready and in-flight queue by event count and literal UTF-8 text bytes: defaults 64 events and 262,144 bytes, accepted maxima 256 events and 4,194,304 bytes. Internal text counts too. Provider upstream stream buffering is separately the adapter's responsibility; observing implementations must use bounded production channels and truthful loss. Queue overflow ends observation explicitly, never silently evicting its retained valid prefix. Coordinator event/turn tombstone limits remain independent, and exhausted capacity refuses new input before writes.

There is one `next()` consumer. Returning from the operation, including an early loop break or thrown error, ends capture. EOF or a stream error does not cancel that consumer before it can drain the valid received prefix, including events retained while input is held. Prefix delivery still requires fresh capture permission on each call. Explicit stop, cancellation and authority loss purge the queue and permanently disable draining, even if a prior stream-loss status is retained. A fatal sequence gap or correlation-capacity failure preserves already-ready valid records but discards its invalid pending suffix so the consumer then receives terminal loss instead of hanging.

`status` records active/stopped or a fixed public-safe observation-loss reason. Loss does not manufacture a provider event, lifecycle transition or sequence number. `state(for:)` remains queryable, including after stop/loss, with existing monotonic timeout behavior; final text alone never finishes a turn. Captured text and arbitrary adapter error descriptions are not included in owner loss reasons. Internal-only and ambient/unassociated events remain explicitly marked in host-local records; a future disclosure/rendering layer must filter them, not treat this API as permission to speak or publish them.

## Cleanup

A lock-protected cancellation capsule takes its immutable lease once. Cleanup cancels upstream before joining work, on startup failure, stop, cancellation, overflow, stream loss, capacity failure, consumer return and throw. Explicit stopping is distinguished from non-authority stream loss so cleanup cannot accidentally purge an otherwise valid received prefix.

Reader and monitor tasks are structured within the scope. Any admitted input task is also cancelled and joined before the scope returns; a noncooperative first-line attempt may delay completion, but it cannot keep capture alive while cleanup waits. Successful completed writes remain sent after cancellation/stop. Later-line cancellation remains a truthful partial error with delivered lines, not an unsent rename. If the consumer returned successfully while its owned input failed, that input failure is surfaced by scope cleanup; an existing consumer error remains the original error after joining.

## Synthetic execution and verification

The registered test adapter schedules its own producer task from the context received through Registry. It emits invented accepted, user-visible text and explicit finish before its guarded input returns. Tests do not construct caller-created post-send events or invoke coordinator ingestion. A fresh observation resets the adapter's sequence to zero, and reconnect verifies real emitted events as well as new identities.

`ProviderObservedSessionTests` proves the guarded full path, unsupported/capture denial, exact startup revalidation, locked input/capture separation, confirmation and reconnect. `ProviderObservationLifecycleTests` covers failed/partial early output, count/UTF-8/consumer queue limits, EOF/error prefix preservation, post-EOF revocation, duplicates/gaps and invalid suffixes, internal/ambient/late events, monotonic timeout, capacity, idle revocation/rebinding/lockdown, noncooperative stop and scoped early return/throw. Additional authority and cancellation suites gate actual listing suspension to prove post-ingestion revalidation, in-flight queue accounting, no new input after observation ends, immediate lease cancellation before joins, and cancelled next waiter cleanup without sleep-based races.

Initial 0.1.17 verification on base `0e8b6d9f687bc6340a7fdbecd3297052ea90a124`, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (historical, not approval of the later repair):

- Draft-focused verification passed 30 tests in four suites with warnings as errors (`artifacts/observed-focused-final.log`); strict repository lint passed. Earlier draft failures exposed cancelled-next return/status and prefix-purge interactions and were fixed, not dismissed as flakes. The actual failing logs remain in the artifacts directory.
- The first complete `scripts/verify.sh all` passed, exit 0: 509 Swift tests in 86 suites, audit CLI, strict lint, shell/script checks, 45 trace-checker tests, five intent tests and one reply CLI test (`artifacts/observed-all-first.log`). There was no unchanged retry or unrelated test-race fix.
- The separate first `scripts/verify.sh sim` passed, exit 0, simulator build-for-testing (`artifacts/observed-sim-first.log`). This is build evidence, not simulator UI execution, physical-device, VoiceOver or TestFlight proof.
- Offline #141 named-path trace passed, exit 0: three expectations, zero problems, with pinned PyYAML provisioned in an isolated venv (`artifacts/observed-trace.log`). Presence is not execution evidence; the Swift test results above supply execution proof. `git diff --check` passed.
- Exactly four production paths change: HailHost, Registry, the new owner and project.yml. The owner file has one narrowly justified file-length exemption: its private lifecycle state, cleanup and retention transitions remain cohesive; all function/type/complexity/line-length rules and repository gates remain strict.

Exact-head correctness review of `568c7730d03992c1ea0f0c0b3537996cb61bb53c` requested changes: consumer EOF/error could precede a valid record still suspended in post-ingestion capture authorization. A gated regression failed on that rejected source for both ordinary EOF and stream error (`artifacts/observed-inflight-terminal-rejected-head.log`). The 0.1.18 repair waits for both pending and in-flight records before reporting terminal loss, matching the existing terminal-waiter gate. The consumer receives the authorized record first, then the truthful original loss; no new event or sequence is invented.

Repair verification at 0.1.18 (same merged base, no unrelated changes), with Xcode selected as above:

- Focused 31 tests in four suites passed, including both formerly failing in-flight terminal-loss cases (`artifacts/observed-018-focused.log`), exit 0.
- The first repair `scripts/verify.sh all` passed, exit 0: 510 Swift tests in 86 suites, 45 checker tests, five intent tests, one reply CLI test, audit CLI, strict lint and scripts (`artifacts/observed-018-all-first.log`). No unchanged retry was needed.
- The first repair `scripts/verify.sh sim` passed simulator build-for-testing, exit 0 (`artifacts/observed-018-sim-first.log`); this remains build-only evidence.
- Offline #141 trace passed, exit 0, three expectations and zero problems (`artifacts/observed-018-trace.log`); `git diff --check` passed. Prior logs/results are preserved, not relabelled as repair evidence.

At this pre-publication verification point, renewed independent exact-head correctness and security review are pending; successful local tests are not an approval record. Subsequent completed exact-head evidence is recorded on the issue/PR.

## Deferred delivery

No production tmux or Codex observer is registered; the existing observation-protocol comment refers to that shipped-adapter boundary, while these tests register the synthetic adapter. There is no live private output, LLM, speech, mobile correlation, output disclosure policy, confidential authenticated network delivery, physical-device or TestFlight proof. #132, #94 and #133 remain open. The next concrete integration is one supported real observer with demonstrable attribution (#134 governs the Codex interface pilot), followed by explicit output disclosure/sanitization and replaceable host speech rendering. Captured content must not enter the current unauthenticated non-TLS listener.
