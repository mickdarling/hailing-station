# Ambient send provenance infrastructure (#904, R0)

This slice is inert for existing callers. The default `sendAudio` overload retains
all wire fields, sequence checks, refusal behavior, and target confirmation.
The optional binding generation rejects mismatches before sending. A queue's
optional immutable admission predicate carries its sampled capture epoch through
queued sends and executor hops; nil admits exactly as before. The next slice
connects that predicate to capture's discard gate.

Notice payloads and observer order are unchanged. A task-local origin labels the
receiving connection generation without changing `HostReplyEvent`. Terminal
ambient-refusal publication is disabled by default, so **no existing observer**,
including the unchanged R0 `HostConnectionStore`, receives a new event. The R8
fix uses a stored per-connection flag, explicitly enabled by R1, rather than an
inherited task-local opt-in. It survives timer callbacks and every loop replacement.
Opted-in refusals also carry the refused stream ID.

## Synthetic proof

`HostConnectionSendOriginTests`:

- `defaultSendAudioPreservesEveryWireFieldAndSequence` compares encoded frames
  with the pre-R0 field values (fresh frame IDs are preserved).
- `defaultObserverPreservesNoticeEventsAndOrderWithOrigin` checks the same
  ordered payloads and that origin reaches the observer without escaping its scope.
- `defaultAmbientRefusalPublishesNothingAndPreservesStreamFailure` checks no
  observer event, the same error on the refused stream, a ready connection, and
  that a fresh stream still sends.
- `optedInRefusalCarriesReceivingOriginAndRefusedStream` covers opt-in over the
  actual scripted receive loop.
- `mismatchedGenerationThrowsWithoutSendingAndMatchingGenerationSends` covers
  explicit generation binding.

`AmbientSendOriginTests`:

- `defaultQueueSendsExactlyItsOriginalPayloadsInOrder` pins the default queue.
- `staleCaptureEpochRejectsQueuedAndAlreadyInFlightSends` holds a send before its
  executor hop, queues another payload, retires the epoch, and proves neither
  reaches the socket; the in-flight send throws `notReady`.

## Verification

All commands run offline under `taskpolicy -b`, `-j 4 -Xswiftc -j1`, with
`--disable-automatic-resolution`, isolated scratch products under the authorized
`hs-904-R-tmp` tree, process-group kill traps, and a 590-second limit per phase.
The required testing framework/plugin/rpath flags are supplied to every command.

- `swift build -Xswiftc -warnings-as-errors`
- `swift build --build-tests -Xswiftc -warnings-as-errors`
- Five serial `swift test --skip-build --disable-xctest --no-parallel --filter SendOrigin --skip DiagnosticReplyComposition`
- One serial `swift test --skip-build --disable-xctest --no-parallel --filter 'HostConnection|AmbientAudio|Ambient' --skip DiagnosticReplyComposition`

The first focused attempt found an invalid synthetic media-mode reason; changing
it to the existing `voice` vocabulary fixed the fixture without a production change.
Fresh linking emits CLT debug-module-path warnings for scratch PCM references;
these are linker/debug-info messages, not Swift source warnings. No source warning
is suppressed. This is synthetic macOS SwiftPM evidence; iOS app compilation and
physical-device behavior remain unverified.

Results on main-24be: both builds passed; the seven focused tests passed on each
of five runs; the broad selection passed **786 tests in 179 suites** in 472.500 s.
Manual strict-warning lint review found no new violation; `git diff --check` passed.
R0 changes exactly three production files relative to main-24be.

## R8 review fix (F3 and F6)

The optional `transportLossObserver` installs a transport wrapper only when a
caller supplies it. The wrapper is bound once to the socket generation before
negotiation sends or receives. It awaits the loss callback at raw send/receive
failure, before rethrowing the same error to the existing close/publication path
for transport-caused drops. Explicit disconnect or loop replacement can instead
report an interrupted receive after `.disconnected`; callers must veto explicit
disconnects before calling `disconnect()`, as R1's store does. Only
`CancellationError` and `HostConnectionFailure` bypass the hook. The wrapper
also preserves the serialized connector's predecessor when retiring a connection.
No existing production code moved between files. Without the hook, the original
connector and socket are used directly; wire bytes, sequencing, notice payloads,
state publication order and failure behavior remain unchanged.

The F6 fail-before log `r1-deadline-origin-probe.log` on the supplied R1 head says:

```text
Expectation failed: await recorder.events.count == 1
Expectation failed: await recorder.streams == [stream]
```

`HostConnectionSendOriginDeadlineTests.refusalOptInMustSurviveNegotiationDeadlineLoopReplacement`
keeps both assertions and uses the stored flag. The detached deadline callback
has no task-local opt-in. `HostConnectionSendOriginCloseTests` pins both default
close-before-reconnect publication and opted-in loss-before-close delivery with
the lost generation. The reviewer default-failure probe is also committed as
`rejectedDefaultSendsDoNotAdvanceSequenceOrPublishRefusal`, retaining its assertions.
The pre-existing seven SendOrigin tests remain default-path and explicit-opt-in
proof. These are synthetic transport tests, not a physical captured-output proof.

R8 exact command prefix (all phases sequential; 590 s process-group kill trap,
at most four workers; automatic resolution disabled):

```text
taskpolicy -b swift <action> -j 4 -Xswiftc -j1
-Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
--disable-automatic-resolution --skip-update
--scratch-path <scratch>/reapply-build
```

Actions/arguments: `build -Xswiftc -warnings-as-errors`;
`build --build-tests -Xswiftc -warnings-as-errors`;
three `test --skip-build --disable-xctest --no-parallel --filter SendOrigin
--skip DiagnosticReplyComposition` runs.

R8 results: both required builds passed with warnings-as-errors; **11 tests in
5 suites passed on each of three runs** (6.960 s, 6.864 s, 6.672 s). The original
seven tests and four added tests all ran. Strict manual lint found no new warning:
HostConnection.swift is 206 lines and its actor body is 149 nonblank code lines;
new functions/types are below the configured thresholds. The existing protocol
file-length exemption is unchanged. `git diff --check` passed. R0 now changes
three production files against main-24be. Initial development exposed Swift's
trailing-closure inference when adding an optional callback; placing options before
the existing explicit sleep/jitter arguments corrected it. A preliminary build
was invalidated by a fixture edit; the finalized builds above ran on stable sources.
CLT debug-module-path linker warnings remain the previously documented toolchain
artifact; no Swift source warning was suppressed.

## R10 documentation cleanup

The scratch-path example uses `<scratch>/reapply-build`. All documents under
`docs/testing/` were searched on each supplied R9 branch (12 documents on R0,
13 each on R1 and R2) for absolute home paths, account names, host addresses and
device identifiers. Public GitHub URLs (this repository and upstream projects) are
not identifiers and stay as links. No other literal home path, account name, host
address or device identifier was found; maintainer first-name qualifiers are unchanged.
This docs-only change is merged down from R0 with normal merge commits.

## R0 follow-up fix round (five second-key findings)

1. The loss observer, connector and socket comments now distinguish transport-caused
   drops from interrupted receives caused by explicit disconnect or loop replacement.
   Only `CancellationError` and `HostConnectionFailure` are ignored. An interrupted
   receive can report the bound generation after `.disconnected`; callers must veto
   explicit disconnects before calling `disconnect()`, as R1's store does. The hook's
   behavior is unchanged.
2. When admission retires during a successful in-flight send, the queue drops every
   pending segment before becoming idle. Retirement alone does not call `onFailure`:
   the caller already owns retirement. Thrown send errors still notify as before.
   `pendingCount` exposes only the count for synthetic retention assertions. With nil
   admission the original drain and failure paths remain unchanged.
3. A new sequence-0 test enters `sendAudio` with admission true, waits for the restored
   target's re-select/ping round trip, retires admission, then answers the pong. It
   asserts that the failure handler ran exactly once and that no audio was sent. The
   existing executor-hop rejection test now also asserts its handler ran exactly once.
4. Negotiation captures the socket generation before any await, then binds the loss
   wrapper to that value. The default connector and socket are still used directly
   when no loss observer is supplied.
5. The production-file count is corrected to three, and `HostConnection.swift` is
   recorded at its actual 206 lines (149 nonblank actor-body code lines). This round
   edits only the existing audio and protocol production files; no R1/R2 code changes.

New tests in `Tests/HailCoreTests/AmbientSendOriginAdmissionTests.swift`:

- `retirementDuringSuccessfulSendDropsAllPendingAudio`: the first send is held after
  reaching the scripted socket while two segments queue. Admission retires, the send
  succeeds, and lines 25 and 29 assert `pendingCount == 0`, including after another
  enqueue attempt. Line 30 pins the sole audio frame; line 31 pins no failure callback.
- `retirementDuringRouteRoundTripRejectsAudioAndNotifiesFailure`: lines 47–53 prove
  the entry check admitted the sequence-0 send into re-selection. Line 57 asserts
  one failure callback and line 59 asserts no audio frame after the pong.

The verification runner gates **every** Swift invocation on no running
`swift-build|swift-test|swift-frontend` process, waiting 60 seconds between checks.
Each invocation then uses the R8 command prefix above, with scratch products at
`<scratch>/build`, a 590-second limit, and process-group kill traps. No network
resolution is allowed. All test selections skip `DiagnosticReplyComposition`.

Mutation proof (both mutated builds succeeded; each targeted test exited 1 on its
assertions, with no fixture changes or timeout):

- Removing only the admission-retirement `pending.removeAll()` failed
  `retirementDuringSuccessfulSendDropsAllPendingAudio` at lines **25 and 29**:
  `Expectation failed: await queue.pendingCount == 0`. The test completed in
  0.571 s with two issues. The clearing was restored.
- Removing only the final `AmbientSendAdmission.isCurrent` condition in `sendAudio`
  failed `retirementDuringRouteRoundTripRejectsAudioAndNotifiesFailure` at line
  **57**: `Expectation failed: (failures.withLock { $0 } → 0) == 1`, and line **59**:
  `Expectation failed: try await audioFrames(socket).isEmpty`. The test completed
  in 1.257 s with two issues. The check was restored.

Both production files were checked byte-for-byte against their saved fixed versions
after restoration. Before mutation, both new tests passed (2 tests in 1 suite,
1.899 s). Mutation commands use the same prefix and testing flags, with action
`test -Xswiftc -warnings-as-errors --disable-xctest --no-parallel --filter <test-name>
--skip DiagnosticReplyComposition`; each builds its mutated source before testing.

Final verification after restoring both mutations:

- `build -Xswiftc -warnings-as-errors`: passed (2.20 s).
- `build --build-tests -Xswiftc -warnings-as-errors`: passed (2.85 s).
- Three serial `test --skip-build --disable-xctest --no-parallel --filter SendOrigin
  --skip DiagnosticReplyComposition` runs: **13 tests in 6 suites passed each time**
  (8.922 s, 9.865 s, 9.121 s), including both new tests and the strengthened existing
  executor-hop test.
- One serial `test --skip-build --disable-xctest --no-parallel
  --filter 'HostConnection|AmbientAudio|SendOrigin|AmbientWiring'
  --skip DiagnosticReplyComposition`: **276 tests in 71 suites passed**, 160.445 s.

Both builds also passed before the mutation runs. The previously documented CLT
debug-module-path linker warnings remain; no Swift source warning was suppressed.
Manual strict SwiftLint threshold review found no new violation: the new test file
is 74 lines, its test bodies are below 40 code lines, and the unchanged connection
actor remains at 149 code lines. No blank lines or explanatory comments were removed
to meet thresholds, and no new lint exemption was added. `git diff --check` passed.
This remains synthetic macOS transport evidence, with no physical-device claim.


## Actor-method default hygiene

The zero-nonce round-trip overload generates its nonce in the actor method and
forwards it explicitly. The public one-argument audio overload forwards a nil
binding generation. Notice call sites explicitly supply nil when no stream is
associated. The explicit overloads live in the protocol extension, preserving
the actor body's strict length budget. These are #206 hygiene changes only;
they did not cause the host's async-sleep abort. That separate runtime issue is
tracked in #991. The default observer and store remain inert, with no opt-in
caller added and no wire or selection behavior changed.
