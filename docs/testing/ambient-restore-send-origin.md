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
including the unchanged `HostConnectionStore`, receives a new event. R1 opts in
around initial connects and foreground nudges; receive-loop tasks and their
reconnects inherit the opt-in. Opted-in refusals also carry the refused stream ID.

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
