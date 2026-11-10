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
grant through the host's final delivery composition. Dispatch also compares that retained generation with
the input authority before creating reply ownership, issuing a read-back or retaining a held request.
Confirmation-tier, guard-hit and rate-limit holds cannot revive an old ambient admission. Routed
destinations keep their existing binding resolution and destination policy checks.

## Anti-takeover property

An owner grant for binding X cannot admit a session holding the target name at binding Y. If replacement
happens after admission, the immutable X continues through the consumer, dispatcher and reloads; the
existing LocalDispatch, host and adapter binding checks refuse it. Re-allowing Y cannot redirect that
stream. Deny/reallow ABA cannot revive its original policy generation, including a queued dispatch.
A mid-stream `bindingMismatch` remains terminal. Recovery requires a fresh stream, and buffered requests
from the old stream are never replayed. This does not claim an atomic lease against external tmux mutation.

The refusal wording and ErrorCodes, routed and selected target binding resolution, and doctor behavior
are unchanged. Distinct session-change notices and doctor diagnostics remain deferred.

The session checks the opening frame's target, selection, audio shape and original grant before listing.
It retains the post-listing selection check and the gate's atomic generation commit. The router requires
both binding and policy generation for its configured target; alternate routed targets keep their
existing binding resolution.

## Synthetic coverage

- `ConfiguredAmbientReallowTests`: a fresh stream delivers at the owner-approved replacement binding,
  including after child reload.
- `ConfiguredAmbientHijackTests`: zero deliveries to an unapproved name holder before admission,
  after admission and across repeated reloads; unavailable authority never uses a startup fallback.
- `AmbientBindingAdmissionRaceTests`: policy denial, deny/reallow ABA and selection changes during
  the listing suspension admit no stale stream or PCM; repeated invalid opening frames and denied
  grants cause no listing.
- `AmbientHeldAdmissionTests`: retired admissions create no hold, read-back token or delivery across
  confirmation, guard and rate-limit branches; valid current holds still refuse retired grants at Send.
- `AmbientRouterStreamTargetTests`: configured binding without policy generation refuses inline and queued.
- `AmbientMidstreamRebindTests`: confirmation-tier ABA creates no hold or delivery; terminal binding
  mismatch, no redirection or buffered replay after re-allow, fresh-stream recovery, and queued-dispatch
  retirement across deny/reallow ABA and reload.

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

Synthetic verification on 2026-11-10 used the Dev Work VM with Apple Swift 6.3.3 and a fresh checkout.
Phases ran one at a time after the shared lane became available, at background task priority with at
most four workers. Each phase was bounded to ten minutes and completed before the next began.

Initial verification:

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
| Warnings-as-errors package and test build | Passed; 232.23 seconds |

The 260-test group includes five expected known issues in `LocalDispatchPreflightWaitTests`, which
deliberately exercise the deadline harness. There were no unexpected issues in the final runs.
The warnings-as-errors build emitted linker module-cache debug-info warnings; Swift compilation and
verification both succeeded. Initial verification exposed the direct-gate fixture omissions and exact
STARTED expectation described above; their corrected groups passed without weakening assertions.

Strict host SwiftLint and the requested 120-column check both printed nothing on all 18 changed Swift
files. Diff whitespace checks passed. No host build or Swift test ran. The production-file count is four.
Both VM build directories were deleted, and no verification processes remained.

Round-2 verification used another fresh checkout under the same toolchain, lane, priority, worker
limit and ten-minute phase bound. The new and changed suites included held-request, gap-fill and
task-progress coverage.

| Phase | Result |
| --- | --- |
| New and changed suites, three consecutive runs | 146 tests in 26 suites per run; all passed in 127.513, 124.787 and 126.766 seconds |
| Ambient A–O families | 134 tests in 25 suites passed, 100.586 seconds |
| Ambient P–Q families | 251 tests in 52 suites passed, 230.277 seconds |
| Ambient R–Z families | 263 tests in 56 suites passed, 218.524 seconds |
| Rightyo families | 186 tests in 17 suites passed, 35.117 seconds |
| Requested listener, dispatch, session, routing, host, policy and connection-probe families | 260 tests in 50 suites passed, 5.425 seconds; the same five expected known issues |
| Delivery-admission and final-delivery authority checks | 33 tests in 6 suites passed, 0.040 seconds |
| Full Reply CLI suite | 126 tests passed, 233.419 seconds; exit 0 |
| Policy CLI after building haild | Build exit 0; test exit 0 |
| Warnings-as-errors package and test build | Passed; 219.44 seconds |

The final runs had no unexpected issues. The host group retained its five expected deadline-harness
known issues. The warnings-as-errors build emitted linker module-cache debug-info warnings; Swift
compilation and verification succeeded. All phases completed within ten minutes.

Strict host SwiftLint and the literal 120-column check printed nothing on all 24 changed Swift files.
No chained `+` operators occur in `#expect`. Whitespace checks passed. All 24 Swift file checksums
matched the tested VM sources. Both build directories were deleted and no verification processes
remained. The production-file count is the same four, using the PR checker's exclusions. No host build
or Swift test ran.

Round-2 fixture updates supply policy generations alongside their synthetic admission bindings.
An initial wider selection exposed four task-progress setup failures in direct router fixtures without
admission authority. The final-owner, liveness and owner-control fixtures now explicitly supply their
binding and generation. Existing test assertions and expectations are unchanged.

No simulator, physical device, microphone capture, live provider or captured-output round trip is claimed.
