# Ambient send provenance infrastructure (#904, R0)

This slice is inert for existing callers. Default `sendAudio` arguments retain
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
R0 changes exactly two production files relative to main-24be.

## R8 review fix (F3 and F6)

The optional `transportLossObserver` installs a transport wrapper only when a
caller supplies it. The wrapper is bound once to the socket generation before
negotiation sends or receives. It awaits the loss callback at raw send/receive
failure, before rethrowing the same error to the existing close/publication path.
Cancellation and protocol failures keep their existing classification. The wrapper
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
--scratch-path /Users/mick/codex-workspaces/hs-904-R-tmp/reapply-build
```

Actions/arguments: `build -Xswiftc -warnings-as-errors`;
`build --build-tests -Xswiftc -warnings-as-errors`;
three `test --skip-build --disable-xctest --no-parallel --filter SendOrigin
--skip DiagnosticReplyComposition` runs.

R8 results: both required builds passed with warnings-as-errors; **11 tests in
5 suites passed on each of three runs** (6.960 s, 6.864 s, 6.672 s). The original
seven tests and four added tests all ran. Strict manual lint found no new warning:
HostConnection.swift is 198 lines and its actor body is 150 nonblank code lines;
new functions/types are below the configured thresholds. The existing protocol
file-length exemption is unchanged. `git diff --check` passed. R0 now changes
three production files against main-24be. Initial development exposed Swift's
trailing-closure inference when adding an optional callback; placing options before
the existing explicit sleep/jitter arguments corrected it. A preliminary build
was invalidated by a fixture edit; the finalized builds above ran on stable sources.
CLT debug-module-path linker warnings remain the previously documented toolchain
artifact; no Swift source warning was suppressed.
