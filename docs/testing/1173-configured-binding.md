# Configured ambient binding admission

Part of #1173. This change resolves the configured ambient target only when admitting a fresh stream.
The session snapshots the current target-policy generation, obtains one alive listing with a nonempty
binding, and accepts that binding only when it equals the original generation's owner-allowed binding.
Missing, stale, denied or unreadable authority refuses admission. The startup binding is an initial
validation hint only and supplies no dispatch authority.

The session revalidates its selection after the listing suspension. The gate commits admission under
that original generation's `performIfCurrent`, stages its events, and releases the lock before sink
callbacks or child launch. The scope, router destination, dispatcher and reload state retain immutable
binding and generation values. `RetainedDeliveryStages.generation` keeps dispatch tied to the admitted
grant through the host's final delivery composition. Routed destinations keep their existing binding
resolution and destination policy checks.

## Anti-takeover property

An owner grant for binding X cannot admit a session holding the target name at binding Y. If replacement
happens after admission, the immutable X continues through the consumer, dispatcher and reloads; the
existing LocalDispatch, host and adapter binding checks refuse it. Re-allowing Y cannot redirect that
stream. Deny/reallow ABA cannot revive its original policy generation, including a queued dispatch.
A mid-stream `bindingMismatch` remains terminal. Recovery requires a fresh stream, and buffered requests
from the old stream are never replayed. This does not claim an atomic lease against external tmux mutation.

The refusal wording and ErrorCodes, routed and selected target binding resolution, and doctor behavior
are unchanged. Distinct session-change notices and doctor diagnostics remain deferred.

## Synthetic coverage

- `ConfiguredAmbientReallowTests`: a fresh stream delivers at the owner-approved replacement binding,
  including after child reload.
- `ConfiguredAmbientHijackTests`: zero deliveries to an unapproved name holder before admission,
  after admission and across repeated reloads; unavailable authority never uses a startup fallback.
- `AmbientBindingAdmissionRaceTests`: policy denial, deny/reallow ABA and selection changes during
  the listing suspension admit no stale stream or PCM.
- `AmbientMidstreamRebindTests`: terminal binding mismatch, no redirection or buffered replay after
  re-allow, fresh-stream recovery, and queued-dispatch retirement across deny/reallow ABA and reload.

The existing startup-pin assertion in `AmbientRouterStreamTargetTests` now checks the admission binding.
`AmbientStreamSelectionTests.aStreamOpensOnTheSessionsSelectionGeneration` retains its exact event-array
comparison and selection assertions; the expected scopes additionally include binding and policy generation.
Direct router starts in the binding-refusal, target-guard-budget, forced-takeover and meeting-teardown
fixtures explicitly supply their existing synthetic binding. The gap-fill rig also explicitly supplies
its binding through the shared test sink because it calls the gate directly, bypassing session admission.
The shared wiring fixture defaults this injection off, so session admission and unbound-start refusals
still exercise production behavior. These fixtures' assertions remain unchanged. All other existing
ambient router, wiring, privacy and restore tests retain their assertions.

## Verification

Synthetic verification on 2026-11-10 used the Dev Work VM with Apple Swift 6.3.3 and a fresh checkout
synchronized by git bundle. Each phase waited for the shared lane, ran under background task policy
with at most four workers, and had a 600-second cap with process-group cleanup. SSH stdin was closed,
and each phase completed before the next began. No phase exceeded ten minutes.

| Phase | Result |
| --- | --- |
| Four new suites, three consecutive runs | 9 tests in 4 suites per run, including 22 invocations; all passed in 12.412, 12.023 and 12.478 seconds |
| Ambient A–O families | 131 tests in 24 suites passed, 105.397 seconds |
| Ambient P–Q families | 251 tests in 52 suites passed, 234.082 seconds |
| Ambient R–Z families | 262 tests in 56 suites passed, 213.087 seconds |
| Rightyo families | 186 tests in 17 suites passed, 34.903 seconds |
| Requested listener, dispatch, session, routing, host, policy and connection-probe families | 260 tests in 50 suites passed, 5.052 seconds |
| Additional delivery-admission and final-delivery authority checks | 33 tests in 6 suites passed, 0.038 seconds |
| Full Reply CLI suite | 126 tests passed, 232.335 seconds; exit 0 |
| Policy CLI after building haild | Build exit 0; test exit 0 |
| Warnings-as-errors package and test build | Build exit 0; wrapper exit 0; 232.23 seconds |

The 260-test group includes five expected known issues in `LocalDispatchPreflightWaitTests`, which
deliberately exercise the deadline harness. There were no unexpected issues in the final runs.
The warnings-as-errors build emitted linker module-cache debug-info warnings; Swift compilation and
the wrapper both succeeded. Initial verification exposed the direct-gate fixture omissions and exact
STARTED expectation described above; their corrected groups passed without weakening assertions.

Strict host SwiftLint and the requested 120-column check both printed nothing on all 18 changed Swift
files. Diff whitespace checks passed. No host build or Swift test ran. The production-file count is four.
Both VM build directories were deleted, and no verification processes remained. The final record update
changes documentation only.

No simulator, physical device, microphone capture, live provider or captured-output round trip is claimed.
