# Host-local input coordination

Implementation slice [#140](https://github.com/mickdarling/hailing-station/issues/140), building on [#137](https://github.com/mickdarling/hailing-station/issues/137), part of [#132](https://github.com/mickdarling/hailing-station/issues/132) and [#94](https://github.com/mickdarling/hailing-station/issues/94).

## Boundary

`ProviderInputCoordinator` connects the existing guarded `HailHost.send` path to the host-local turn correlator. It owns one immutable provider observation binding and terminal connection generation, bounds retained turns/events, and records a successful complete dispatch as **sent**. Provider acceptance and lifecycle completion still require explicit observed events; text-final is not completion.

This is not registered with the listener or daemon composition root. No current adapter receives a generated turn context, no observer lease is consumed, no target output is captured, and no provider events are published on the mobile wire. Tests use real host policy and synthetic adapters/events. The source version advances to 0.1.9 after its review fixes; this slice does not upload or install TestFlight.

## Identity and dispatch

For this narrow adapter-backed slice, the binding's `sessionID` is the exact opaque adapter binding from the authorization listing, not its display name. Its `providerID` must match the adapter prefix of `targetID`. The coordinator passes that expected binding to `HailHost.send`. The host compares it against the same listing used for policy evaluation, before consuming confirmation or delivering content. A second listing after delivery would not prove which target received the text. This comparison is correlation protection, not terminal authentication.

Admission is checked before dispatch. One submission may await the host at a time; overlapping submission is explicitly refused rather than interleaved through actor reentrancy. Event ingestion during that await is refused without consuming ordering, so a future stream owner can retry the same event. This slice does not provide that owner's buffering/retry orchestration and cannot claim real provider event handoff.

Confirmation-required, denied, sanitization-refused, failed, or partial delivery does not create a successfully sent turn. Zero-write failures preserve the original error. Once a line has completed, all subsequent errors preserve the known delivered lines as partial evidence; unexpected adapter errors use a generic reason instead of reflecting arbitrary private error content. Failure is not proof that no side effect happened. Cancellation before dispatch refuses delivery. Cancellation during a noncooperative successful write cannot retroactively undo it or erase its sent record.

## Deadlines and lifetime

The coordinator uses an injected monotonic clock and an explicit expiration call. Configured timeout must be positive and no more than 24 hours. A deadline begins only after complete successful dispatch; no background timer is inferred. Explicit terminal events stop that turn's deadline. Timeout remains terminal, so late output cannot complete a newer request. Turn tombstones and event identities are retained within configured bounds; exhaustion of either refuses another dispatch before adapter side effects. Reconnect or target replacement requires a fresh coordinator and observation generation, not a silent reset of ordering or identity.

## Next work

Provider context handoff, observation ownership and cancellation/rebinding orchestration, output disclosure/speech policy, host rendering, negotiated wire identities, authenticated confidential publication, and mobile session presentation remain separate slices. Existing personal-terminal routing and manual `haild reply` are unchanged. #132 and #94 remain open.

## Verification

With `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, the initial `scripts/verify.sh all` passed 455 Swift tests in 79 suites plus lint, scripts and audit checks; `scripts/verify.sh sim` passed build-for-testing. After review fixes, the focused coordinator, correlator, binding and host-send run passed 50 tests in five suites. Issue #140's four named test/document expectations pass `scripts/spec_trace.py`.

An independent draft audit found cancellation during awaited target listing could still permit the first write. The repair checks cancellation after listing before confirmation consumption and before subsequent line handoffs. Deterministic regressions cover zero writes during cancelled listing, confirmation reuse, partial multiline evidence, and truthful sent evidence after a completed noncooperative write. These are synthetic policy/adapter tests, not physical-device or live-provider validation.

Round-one exact-head correctness review then found unknown adapter errors could lose partial-write evidence, and colon-containing provider IDs could misidentify Registry's first-colon adapter resolution. Both were repaired with regressions. Colon-containing target names remain valid, while this adapter-backed coordinator rejects colon-containing provider IDs. Changed source requires fresh exact-head correctness and security review.

Final review-fix verification initially failed two existing tests: audit history's intermediate-day test threw `inUse` (#79), and the newer-audio-activation test threw `superseded` (#118). Neither implementation/test is changed by this slice. The failure is recorded on both issues; the cause is not assumed. A focused rerun passed all 12 tests in those two suites, and one complete verifier rerun passed all 457 Swift tests in 79 suites plus lint/scripts/audit. The final simulator build-for-testing also passed. A successful rerun does not resolve either intermittent-failure issue.

The subsequent GitHub Codex review identified cancellation during synchronous confirmation-policy reload could consume a one-shot confirmation before any write. A post-reload check now preserves that token, with a deterministic gated-store regression proving zero writes and successful exact-token retry. Final verification of this repair passed 458 Swift tests in 79 suites plus lint/scripts/audit, simulator build-for-testing, and 51 focused tests in five suites. Earlier failed-run evidence remains recorded above.
