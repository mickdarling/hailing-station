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

PR A preserved refusal wording and ErrorCodes, routed and selected target binding resolution, and doctor
behavior. The host-only session-change extension is described below; doctor diagnostics remain deferred.

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

## Host-only session-change notice (PR B)

A live, nonempty configured-target binding that differs from the opening grant is refused with
`not_allowed: ambient stopped: target session changed`. An own-target mid-stream `bindingMismatch`
from a live, nonempty replacement receives the same ending. Missing, dead, nil or empty bindings retain
`ambient stopped: dispatch bindingMismatch` without a session-change notice. Unreadable or retired
authority keeps its existing refusal. No new ErrorCode or app behavior is introduced.

The host attempts to send a capable device the fixed daemon request-refusal line before that ending:
"The voice target's session changed. Reconnecting." At fresh admission, the session returns the
notice and ending in one ordered frame batch, and the peer awaits each send. At mid-stream dispatch,
the configured target's dispatcher claims terminal ownership of the exact child before suspending.
Further microphone segments are not forwarded, reload cannot replace that child, and input closure
cannot publish a competing ending. The child retires while the notice waits behind earlier refusals
and the captured acknowledgement on its existing request-refusal chain.

`AmbientRightyoRouter.sessionChangeNoticeDeadline` bounds that wait to two seconds. Completion, expiry,
teardown or cancellation releases the dispatcher, which unconditionally throws the terminal refusal.
The run is removed before the ending is sent; a stalled acknowledgement cannot retain a run slot or
prevent the gate from ending. The deadline uses a separate serial dispatch queue and does not join an
acknowledgement task. Expiry also cancels the acknowledgement, activating the prepared-send watchdog.
A transport submission permit is revoked under the same lock used to enqueue the notice: a task held
by an external acknowledgement can later resume, but cannot enqueue a late notice. Successful notices
still reach `peer.post` before the ending. Expiry or notice failure does not suppress the ending.

Fresh-admission refusals are built under the opening attempt's policy generation, then restore any
older child's retained generation. A previous stream's retired grant cannot rewrite a current opening
attempt's session-change ending into `ambient target_policy_changed`. No authority is transferred.

The fixed safety line requires the live connection, negotiated session, current selection, request-refusal
capability and transport permit. It requires no target binding authority and produces no target voice
or delivery; the binding-mismatch branch suppresses the not-sent clip. Older devices receive the ending
without an unsupported request-refusal frame. Routed mismatches retain their per-request route refusal;
non-configured selected targets retain their existing terminal error. Dialog notices retain their
per-request wording, effect accounting, correlation, ordering and clip decisions.

The host starts no retry task. The existing device controller recognizes `ambient stopped:`, waits
1, 3 and 10 seconds, and opens fresh stream identities at sequence zero with the resume marker. Each
new stream goes through PR A's original-grant admission. An unapproved session holding the target name
receives no input, even over repeated restart attempts. Only owner approval of the live binding allows
a later fresh stream to deliver. Approval alone starts nothing; old-stream input cannot redirect or replay.

### Additional synthetic coverage

- `AmbientSessionChangeNoticeTests`: exact notice-before-ending wire order at refused admission and
  mid-stream failure, including a reloaded child; a held acknowledgement holds both frames until the
  deadline; repeated
  unapproved restart attempts deliver nothing and launch no child; approval permits only a fresh stream;
  binding-mismatch wording uses the refusal chain even after target authority is denied, with no target voice;
  the selected-target seam retains its prior terminal error.
- `AmbientSessionChangeBoundaryTests`: routed mismatch bypasses the own-target notice, and an older
  device receives only the existing-code ending.
- `AmbientSessionChangeDeadlineTests`: a prepared send with no completion cannot retain a run; four
  stalled runs release capacity for a fresh admission; expired notices stay silent when acknowledgements
  resume; child exit, continued microphone input, teardown and cancellation cannot add a second ending.
- `AmbientSessionChangeAdmissionTests`: a same-connection A → approved B → unapproved C opening gets
  the session-change ending while retaining the older child's grant; missing, dead, nil and empty
  mid-stream bindings retain their prior ending and produce no session-change notice.
- `AmbientSessionChangeRecoveryTests`: the exact ending triggers a new sequence-zero resume stream;
  persistent refusal exhausts the existing three device retries at 1, 3 and 10 seconds.

These are authored child events, injected capture and loopback transport tests. They do not establish
ordinary spoken playback of the notice: the existing app displays a request refusal and can make an
accessibility announcement. No physical device, microphone, live provider, installed build or captured-output
round trip is claimed. No app source or TestFlight identifier changes are included.

### PR B verification

Initial verification:

Synthetic verification on 2026-11-10 used the Dev Work VM, Apple Swift 6.3.3 and a fresh checkout.
Each phase waited for the shared lane and ran at background priority, with at most four workers,
serial Swift test scheduling and a ten-minute execution bound with process cleanup.

The focused selection was
`AmbientSessionChange|ConfiguredAmbientHijackTests|ConfiguredAmbientReallowTests|AmbientMidstreamRebindTests|AmbientRouterBindingRefusalTests`.
It includes the new daemon and device-controller tests and all users of the changed configured-target rig.
An initial focused run exposed a reload fixture releasing output before the replaced child had finished;
the final fixture waits for one live run before releasing the request. Existing assertions and expectations
were not weakened or changed.

The broader selection was
`HailDaemonKitTests\.(Ambient|Rightyo|WebSocketListener|WebSocketPeer|Listener|LocalDispatch|HostSession|Routing|VoiceRoute|ConfiguredAmbient|HailHost|Host)`.
It ran once in disjoint ambient A–O, P–Q, R–Z, Rightyo and remaining-prefix groups.

| Phase | Result |
| --- | --- |
| New and changed suites, three consecutive runs | 22 tests in 7 suites per run; all passed in 68.266, 66.050 and 66.966 seconds |
| Ambient A–O families | 134 tests in 25 suites passed, 103.378 seconds |
| Ambient P–Q families | 251 tests in 52 suites passed, 235.220 seconds |
| Ambient R–Z families | 269 tests in 58 suites passed, 223.047 seconds |
| Rightyo families | 186 tests in 17 suites passed, 33.966 seconds |
| Remaining requested daemon families | 203 tests in 43 suites passed, 13.758 seconds |
| Full Reply CLI suite | 126 tests passed, 231.749 seconds; exit 0 |
| Policy CLI after building haild | Build exit 0; test exit 0; phase completed in 37 seconds |
| Warnings-as-errors package and test build | Build and wrapper exit 0; 252.75 seconds |

The remaining daemon group reported five expected known issues in `LocalDispatchPreflightWaitTests`,
which deliberately exercise the deadline harness. The final Swift test runs had no unexpected issues.

The warnings-as-errors build emitted linker module-cache debug-info warnings; Swift compilation and
the wrapper both succeeded. Every phase completed within ten minutes. Strict host SwiftLint and the
120-column check printed nothing on all six changed Swift files; no host build or Swift test ran.
No chained `+` operators occur in the changed `#expect` or `#require` expressions. Whitespace checks
passed. All six Swift file checksums matched the tested VM sources. The production-file count is two,
using the PR checker's exclusions.
Both VM build directories were deleted after verification, and no verification processes from this task
remained. No push, installed-build replacement, upload, simulator or physical-device validation was performed.

Round-2 verification used another fresh checkout on the Dev Work VM with Apple Swift 6.3.3.
Phases waited for the shared lane and ran one at a time at background priority, with at most four
workers, serial test scheduling and the same ten-minute phase bound and process cleanup.
The focused and broader selections above were unchanged; the focused selection additionally matched
the two new session-change suites.

| Phase | Result |
| --- | --- |
| Focused selection, three consecutive runs | 29 tests in 9 suites per run; all passed in 78.901, 79.041 and 78.296 seconds |
| Ambient A–O families | 134 tests in 25 suites passed, 105.590 seconds |
| Ambient P–Q families | 251 tests in 52 suites passed, 238.945 seconds |
| Ambient R–Z families | 276 tests in 60 suites passed, 236.178 seconds |
| Rightyo families | 186 tests in 17 suites passed, 34.699 seconds |
| Remaining requested daemon families | 203 tests in 43 suites passed, 13.617 seconds; five expected known issues |
| Full Reply CLI suite | 126 tests passed, 233.125 seconds; exit 0 |
| Policy CLI after building haild | Build exit 0; test exit 0; phase completed in 52 seconds |
| Warnings-as-errors package and test build | Build and wrapper exit 0; 243.10 seconds |

The final runs had no unexpected issues. The remaining daemon group retained the same five deliberate
`LocalDispatchPreflightWaitTests` deadline-harness known issues. The warnings-as-errors build emitted
linker module-cache debug-info warnings; Swift compilation and the wrapper succeeded. All phases
completed within ten minutes.

Swift test phases used `swift test --skip-build --no-parallel -j 4` with the filters above. Builds used
`swift build --build-tests -j 4 -Xswiftc -j1`; the separate warnings build added
`-Xswiftc -warnings-as-errors`. These commands also supplied the VM toolchain's framework, Testing
plugin and runtime-linker arguments. CLI verification used
`python3 -m unittest discover -s Tests/ReplyCLITests` and `bash scripts/tests/test-policy-cli.sh`,
the latter after `swift build --product haild -j 4 -Xswiftc -j1` with the same toolchain arguments.

Strict host SwiftLint and the literal 120-column check printed nothing on all ten changed Swift files.
No chained `+` occurs in the changed `#expect` or `#require` expressions. Whitespace checks passed,
and all ten Swift file checksums matched the tested VM sources. Both VM build directories were deleted,
and no verification processes from this task remained. The production-file count is four using the
PR checker's exclusions. No host build, host Swift test, simulator, physical-device validation,
installed-build replacement, upload or captured-output round trip was performed. No push or GitHub
call was made for this round.
