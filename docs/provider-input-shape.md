# Registered provider input shape

Implementation #152, part of #132 and #134, following the owned host-local observation driver #141. Source version 0.1.20. This is an adapter-fit prerequisite, not a real provider integration, output publication or device proof.

## Typed profiles and dispatch

`Adapter.inputShape` is a typed property on the actual registered adapter. Its default `AdapterInputShape.lineOriented` preserves existing adapters: each sanitized line is delivered separately, and contextual adapters receive the same proposed turn context on all lines. `singleLineContextual` is explicit opt-in for an adapter whose one delivery represents one whole provider turn. That profile requires `ProviderContextDelivering` and a contextual host request; an ordinary legacy request fails with `AdapterInputShapeError.contextRequired`, not a silent fallback. Unsupported contextual capability still fails with `RegistryError.contextualDeliveryUnsupported`.

HailHost sanitizes first and passes the resulting line count to Registry's preflight. The single-line profile requires exactly one sanitized line, otherwise `AdapterInputShapeError.singleLineRequired` is thrown before one-shot confirmation consumption, delivery admission or any adapter request. Raw newline counting is not used: normalization, control/escape stripping, whitespace-only line removal and the host's existing sanitizer limits remain authoritative. The default newline-reject policy still refuses multiline input before shape preflight; explicitly split input is where the registered shape prevents several logical provider turns under one context. No lines are concatenated, dropped or secretly dispatched through legacy delivery.

Profile resolution is a Registry actor hop for all modes. After it returns, HailHost forcibly refreshes current policy, including unconfirmed legacy and contextual input. The existing single cancellation checkpoint remains after policy I/O and before confirmation consumption. Consumption, first policy evaluation and admission are synchronous after that checkpoint; the subsequent Registry/adapter handoff is asynchronous, with no further host cancellation checkpoint before the first committed attempt. Cancellation observed before the checkpoint preserves confirmation; once the first attempt commits, a noncooperative completed write remains sent. Cancellation before later line-oriented deliveries and other partial failures retain known delivered lines.

If Registry's suspended preflight rejects the request, HailHost checks cancellation before rethrowing that preflight error. A cancelled rejected request therefore reports `CancellationError`, not an obsolete shape/capability refusal. This error-path check consumes no confirmation, admission or provider write; it does not add a checkpoint after the successful path's first-attempt commitment.

Context provider identity must match Registry's actual adapter kind, and context binding must match the fresh target listing. The allowlist, exact binding, lockdown, tiers, guards, rate admission and per-line checks remain on the shared guarded path. The registered profile is not a permission grant or client-provided identity. Adapters still must enforce exact binding immediately before their own side effects; an actual target replacement during host suspension cannot be authorized by a previously valid listing. A refused preflight neither records a sent turn nor supplies evidence of provider acceptance.

Profiles are host-owned adapter behavior. A trusted fixture changes its profile between completed requests solely to prove reuse of a genuinely issued multiline confirmation on the same target/binding/request. It is not a mobile configuration interface. A real adapter must not change what a bound input commits to mid-dispatch; retargeting requires a changed opaque binding and explicit reauthorization.

## Proof and verification

`ProviderInputShapeTests` registers synthetic adapters through the real Registry and HailHost path. It proves zero provider requests for multiline refusal, unspent rate admission and sent capacity, reuse of an actually issued matching multiline confirmation after shape refusal, valid confirmed single-line input and one-shot semantics, normalized sanitized input, unsupported/mismatched capability refusal and unchanged default legacy/contextual multiline dispatch.

`ProviderInputShapeAuthorityTests` gates the registered profile getter while the host awaits Registry, then cancels the request or changes current policy/lockdown. Both contextual and legacy requests refuse without writes, and cancelled confirmation remains actually reusable. Further cases cover provider and binding mismatch without burning a valid token, adapter-side exact-binding refusal after replacement, sanitizer precedence, successful noncooperative cancellation evidence and preserved line-oriented partial failure without sent promotion. The gated suite is serialized so its synchronous fixture does not block several Swift cooperative executor workers at once; it uses arrival/release handshakes rather than sleep-based races.

The existing policy-commit test retains its immediate assertion that HailHost adopts the transaction's returned locked policy. Its subsequent load fixture is aligned with the committed view it claims readers see. A separate `PolicyCommitTests` regression proves a differing authoritative subsequent load supersedes that adopted result: the host first adopts locked, then fresh dispatch reads open and delivers under the current open policy. The shared fixture's intentionally invalid transaction-result/recovery behavior is unchanged.

All labels/text in fixtures are invented. Verification on base `be4604f46ca344505ff4f1414fce0121766df0da`, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- Initial shape-focused tests passed 14 tests in two suites, exit 0 (`artifacts/input-shape-focused-final.log`); strict lint passed.
- The first `scripts/verify.sh all` failed, exit 1: 524 tests in 88 suites, with one deterministic failure in `PolicyCommitTests.commitCompilesAndAdoptsThePolicyReturnedByTheStore` (`artifacts/input-shape-all-first.log`). The fixture reported a committed locked policy but exposed open on its next load; the newly required fresh reload therefore delivered. This is retained as an actual fixture-contract conflict, not dismissed as a flake. The scoped fixture alignment and explicit differing-load regression above address it without weakening production authority.
- Focused shape plus policy-commit verification after that meaningful test repair passed 18 tests in three suites, exit 0 (`artifacts/input-shape-fixture-repair-focus.log`). The one complete rerun then passed, exit 0: 525 Swift tests in 88 suites, 45 checker tests, five intent tests, one reply CLI test, audit CLI, strict lint and scripts (`artifacts/input-shape-all-rerun.log`). No unchanged retry or unrelated race fix is included.
- First simulator build-for-testing passed, exit 0 (`artifacts/input-shape-sim-first.log`). No production code changed after that build; the later repair affects only tests/documentation. This is not UI execution, physical-device or TestFlight proof.
- Offline #152 trace passed, exit 0, four expectations and zero problems (`artifacts/input-shape-trace.log`); presence is not execution proof. `git diff --check` passed.

Exactly four production paths change: Adapter, Registry, HailHost and the project version. No new lint suppression or global gate change is introduced.

The preceding verification is the initial 0.1.19 record. Subsequent completed exact-head evidence belongs to the issue/PR; local test success is not an approval record.

## Exact-head cancellation repair

GitHub Codex's completed review of `542a2ec9fc066e5de3393c2979f5dd7a04020d33` found a valid [P2 cancellation-precedence defect](https://github.com/mickdarling/hailing-station/pull/154#discussion_r4140828076): cancellation during the Registry shape hop could be hidden by a rejected preflight, bypassing the later checkpoint. The refusal still spent no confirmation, admission or write. Source 0.1.20 adds only the rejected-hop cancellation check; prior-head approvals do not cover this repair.

`ProviderInputShapeAuthorityTests.cancelledRejectedShapeHopPreservesConfirmationAdmissionAndSentCapacity` deterministically holds the real registered profile getter, cancels, then releases a rejected contextual multiline or contextless single-line request. Both cases require `CancellationError` and zero adapter writes. Each then actually reuses its matching issued confirmation through the coordinator after trusted fixture reconfiguration, with exactly the required delivery-rate budget and one sent-turn slot; the successful retry proves that the refusal spent neither token nor admission/capacity.

Repair verification on the previously reviewed head above, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- Focused shape/policy-commit tests passed, exit 0: 19 tests in three suites (`artifacts/input-shape-review-repair-focus.log`).
- First `scripts/verify.sh all` passed, exit 0: 526 Swift tests in 88 suites, 45 checker tests, five intent tests, one reply CLI test, audit CLI, strict lint and scripts (`artifacts/input-shape-review-repair-all-first.log`). No retry was needed.
- First `scripts/verify.sh sim` passed simulator build-for-testing, exit 0 (`artifacts/input-shape-review-repair-sim-first.log`). This is not UI execution, physical-device or TestFlight proof.
- Offline #152 trace passed, exit 0: four expectations, zero problems (`artifacts/input-shape-review-repair-trace.log`); presence is not execution proof. `git diff --check` passed. The PR still has four production paths, with no new lint suppression.

At this repair's pre-publication verification point, fresh exact-head correctness/security/service review remains pending. Subsequent completed evidence is recorded on the issue/PR.

## Deliberate limit and follow-on

The single-line profile is deliberately limited. A future whole-prompt contract must authorize one complete sanitized logical request and hand it to a provider exactly once, with truthful provider turn identity, interruption and lifecycle handling. It cannot reuse today's per-line loop while claiming a multiline logical request is one provider turn. This slice does not implement that contract or silently retrofit it into an adapter.

There are no listener, wire, observation-owner, speech or mobile changes. No Codex App Server calls, live output capture, desktop attachment, real-provider interruption, physical-device or TestFlight result is claimed. #134 remains open for supported-interface decisions. Capture authorization remains separate from input shape; captured content must not be published through the current unauthenticated non-TLS listener.
