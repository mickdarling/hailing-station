# Host heard-turn correlation verification (#923, PR B)

Part of #923. This slice adds host generation and correlation using the protocol from PR A, based on
`4a771fd8ffd8a87651f9753d0fa94b33889ee96c`. It does not change HailCore or the app. The device still does not advertise
`heard_turns`; device advertising and correlation remain PR C work. All verification here is host-local and synthetic
on the Dev Work VM, using the Command Line Tools toolchain. No simulator, physical-device, installed-build, or live
captured-output proof is claimed. Only the supplied local bundle was imported; no network or installs were used.

## Design and binding guarantees

1. `HostSession.heardFrame` retains the existing `ambient_heard`, ready-session, selected-target, and text-size gates.
   `WebSocketPeer.postAmbientHeard` adds a turn only with `heard_turns`. The refusal path retains `request_refusals`,
   readiness, and selection gates; its turn additionally requires `heard_turns` and `ambient_heard`. The eight
   combinations in `HeardTurnCapabilityTests.bothFramesKeepTheirOwnCapabilityGates` exercise the independent gates.
   `HeardTurnHostTests.legacyFramesStayByteIdenticalAndNeverAcquireRecords` compares encoded bytes with the same
   envelope and the original control payload and explicitly checks omission of the key for both frames.
2. Only the `ambientHeard` constructor at enqueue and the existing `voiceRouteRefused` constructor receive a turn.
   The protocol encoder is unchanged; PR A's rejection tests remain in the broad `HeardTurn` sweep. Existing voice
   route code tests continue to cover other refusal codes.
3. `UUID()` runs on the peer actor immediately before `post`, with no suspension between minting, queueing, and
   recording. It never uses content, producer ids, or the connection id. A different host-local UUID identifies the
   dispatch and travels through the heard relay and any delayed input-pending notice. Refusals look up that key
   only on their own connection. Overlapping identical text, reverse-order refusals, another connection, reconnect,
   unrelated requests, and one-shot consumption are covered by `HeardTurnHostTests`. The real pipeline is covered
   by `AmbientWiringHeardTurnTests`, including a delayed first refusal while the second request completes.
4. No new log site is added. The touched routing and pending-input logs still contain fixed reason/outcome tokens.
   The host and wiring tests capture log details and reject both the synthetic heard marker and the emitted UUIDs.
5. `HeardTurnRecords` contains only request/turn UUID pairs, in memory, in a FIFO capped at 64 entries per connection.
   Recording follows a successful `post`; refused queues and invalid heard frames leave no entry. Refusal consumes
   a matching entry before attempting delivery, successful dispatch or dispatch failure clears its entry, and peer
   teardown or listener shutdown closes and empties the ledger. Closing prevents late recording from reviving it.
   Records stay in the FIFO while an acknowledgement delays a refusal, so eviction still applies then. The tests
   cover 68 queued turns, a 64-entry maximum, oldest-entry eviction, completion, dispatch failure, closed transport,
   closed-ledger insertion, peer teardown, and listener shutdown. A request without heard text still receives its
   ordinary refusal callback, with no turn record.

## Verification

Each phase was capped at 600 seconds with signal/timeout cleanup of its process group. Swift commands ran under
`taskpolicy -b` with four build jobs and automatic package resolution disabled. The load phase ran the serial tests
alongside exactly four background `taskpolicy -b yes` workers; its signal/finally cleanup terminated and reaped all
four. Their absence was checked after the phase. No build overlapped the load workers.

The exact Swift command expansion used these flags:

```bash
flags=(
  -j 4 --disable-automatic-resolution
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
taskpolicy -b swift build -Xswiftc -warnings-as-errors "${flags[@]}"
taskpolicy -b swift build --build-tests -Xswiftc -warnings-as-errors "${flags[@]}"
for iteration in {1..10}; do
  taskpolicy -b swift test --skip-build --no-parallel \
    --filter 'HeardTurnHostTests|HeardTurnCapabilityTests|AmbientWiringHeardTurnTests' "${flags[@]}"
done
# The same ten-run loop was repeated in one capped phase with the four yes workers.
taskpolicy -b swift test --skip-build --no-parallel \
  --filter 'AmbientHeard|VoiceRoute|RouteRefusal|InputPending|Acknowledg|AmbientWiring|Privacy|HeardTurn' "${flags[@]}"
git diff --check
```

Results:

- Production build and test build passed with warnings treated as errors.
- Final focused suite: 11 test functions in three suites, 18 case executions per run. Normal: 10/10 passed;
  four-worker load: 10/10 passed, for 360 case executions across the required repetitions.
- Broad serial sweep passed once: 443 test functions in 100 suites (246.088 seconds).
- `.swiftlint.yml` was checked by hand: added Swift lines fit 120 columns; new files, types, functions, parameter
  counts, nesting, and complexity fit the configured limits. Existing file-length exemptions are unchanged.
  SwiftLint is not installed on the VM.
- The PR-shape checker's exact exclusions yield four production files and three `SECURITY_PATHS` matches, all under
  `Sources/HailDaemonKit/Listener/`. The fourth production file is `Input/RightyoAmbientPipeline.swift`.
  `security:critical` and independent exact-head review remain required for a future PR. No online issue-state,
  PR-shape, review, or GitHub check was attempted under the offline constraint.

## Revision 2: delivery-refusal notices and lint limits

The current delivery path cannot set `lastDeliveryRefusal` before the heard callback. In
`RightyoInputConsumer.deliver`, only an un-routed `inputPending` refusal sets that property; a routed refusal sets
`lastRouteRefusal` instead. `RightyoAmbientDispatchStep.dispatch` awaits `announce()` (which awaits `heard`) before
calling the dispatcher for an un-routed request. Neither missing `ambient_heard` support nor absent heard text skips
`AmbientHeardRelay.deliver()`: capability checks happen inside `HostSession.heardFrame`, and text only gates showing.
The producer validator also requires a request turn and nonempty text, so a no-text request is not admitted today.
The pipeline awaits consume and `observeRefusals` in the same event loop before reading the next event; its refusal
closure captures the current request key before queuing a delayed notice. These are source-path findings, not
physical-device evidence.

Regardless of those current preconditions, `AmbientHeardRequests.finish` and the router now accept an optional
request key. `AmbientHeardRelay.finish(refusal:)` forwards every refusal even without delivery or text; only a
successfully recorded heard turn can add a turn to its notice. Completion always clears text and key, and observing
a new request resets the key. No-text delivery leaves the key nil. The existing acknowledgement ordering, privacy,
selection, and capability gates on the line and clip remain in force.

`AmbientWiringDeliveryRefusalTests` verifies the actual router's refusal line and "Nothing was sent." clip, with no
turn, for a device lacking `ambient_heard` (even with `heard_turns`) and at the no-text relay boundary both with and
without delivery. The no-text boundary is synthetic because producer validation rejects such a request today.
It also verifies that completion and a new request observation independently prevent key reuse.
`AmbientWiringHeardTurnTests.aSuccessfulRequestThenARefusalUseOnlyTheSecondTurn` covers the real two-request pipeline:
the first succeeds and clears its record; the second is refused with only its own turn. Existing tests retain the
reverse sequence and delayed-first-refusal coverage.

The lint repairs use `HeardTurnRecords.isEmpty` and `String(bytes:encoding:)`, move the pipeline's event loop into an
extension, and move listener lifecycle methods into an extension while retaining all stored properties in the actor.
The class and actor bodies now contain 115 and 79 nonblank, noncomment lines respectively (previously 152 and 153).
Every Swift file changed by PR B was checked against `.swiftlint.yml`: code lines at most 120 columns, type bodies
at most 150 lines where enabled, function-body and file-length limits, `empty_count`, and
`optional_data_string_conversion`. The two pre-existing production file-length exemptions and the router
configuration/state type-body exemption are retained; no lint disable was added. SwiftLint is absent
on this VM, so this is a manual configuration audit, not a claim of running host `swiftlint lint --strict`.

Revision 2 verification uses the same flags listed above, a 600-second process-group kill trap per phase, four build
jobs, no parallel tests, no extra load workers, no network, and no installs. The exact test selections are:

```bash
taskpolicy -b swift build -Xswiftc -warnings-as-errors "${flags[@]}"
taskpolicy -b swift build --build-tests -Xswiftc -warnings-as-errors "${flags[@]}"
for iteration in {1..10}; do
  taskpolicy -b swift test --skip-build --no-parallel \
    --filter 'HeardTurn|AmbientWiringDeliveryRefusal' "${flags[@]}"
done
taskpolicy -b swift test --skip-build --no-parallel \
  --filter 'AmbientHeard|VoiceRoute|RouteRefusal|InputPending|Acknowledg|AmbientWiring|Privacy|HeardTurn|DeliveryRefus' \
  "${flags[@]}"
git diff --check
```


Revision 2 results:

- Production build and test build passed with warnings treated as errors (5.32 and 28.28 seconds).
- Focused heard-turn and delivery-refusal selection passed 10/10 runs: 23 test functions in six suites,
  42 case executions per run, 420 total case executions. This includes the pre-existing protocol and heard tests.
- Broad serial sweep passed once: 448 test functions in 102 suites, 729 case executions (247.348 seconds).
- Manual lint audit and `git diff --check` passed. PR B still changes exactly four production files under the
  PR-shape checker's exclusions and rename handling; this revision touches three of those four.
- All results are host-local synthetic proof. No simulator, physical device, installed build, remote metadata,
  review, or GitHub checks were used or claimed. No online PR or issue mutation was made.
