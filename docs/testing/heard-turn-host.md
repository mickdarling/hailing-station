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
