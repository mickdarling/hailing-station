# Device heard-turn model verification (#923, PR C1)

Part of #923. C1 starts at main `a154adcbb5d904ddd3d408b492a5597ca8c3747f`, which contains PR A (#927),
without PR B. It changes only `ConversationLog.swift`, `HostConnectionStore.swift`, tests and documentation.
It adds no advertising or UI. An older host never sends a turn, so C1 does not depend on PR B.
Verification is local and synthetic on the Dev Work VM with Command Line Tools, offline, without installs,
simulator, physical device, installed-build replacement or a live captured-output round trip.

## Design and acceptance traceability

- `HostConnectionStore.receiveAmbientNotice` associates `noteSent`'s returned entry ID with the optional heard UUID.
  `ConversationEntry.heardTurn` is internal and memory only, with no separate index or logging. Correlation is bounded
  by the 200-entry history. `HeardTurnAppTests.historyEvictionAlsoEvictsCorrelation` covers eviction and the bound.
- Only `voice_route_refused` marks `notSent`, matching an exact UUID on the same endpoint's current connection and
  consuming the match. Text never participates. The separate notice and announcement remain unchanged.
  `matchingRefusalMarksTheHeardEntryAndKeepsTheNoticeAndAnnouncement` checks state, destination, one announcement
  and a ready connection; `identicalWordsInFlightMatchOnlyByUUID` distinguishes identical concurrent text.
- `differentOrMissingRefusalTurnLeavesTheEntrySent`, `deliveredRequestStaysSentIncludingOldHostShape` and
  `oldHostRefusalKeepsTheHeardEntrySentAndAddsItsNotice` cover unknown/nil IDs, delivered replies and older hosts.
- Correlation clears on disconnect, automatic reconnect, generation change, endpoint replacement and removal;
  visible history remains. Existing connection generations and callback tokens still reject obsolete callbacks.
  `HeardTurnAppLifecycleTests.connectionChangesClearCorrelationWithoutRewritingHistory` covers four lifecycle paths.
  `anotherConnectionCannotRefuseTheFirstConnectionsTurn` covers endpoint isolation.
  `selectionChangeStillMarksTheOriginalHeardEntry` retains correlation across target selection while leaving the
  refusal notice in the selected thread, matching existing behavior.
- C2 defers the actual hello capability and visible/VoiceOver state. Host generation and sending remain PR B work.

## Verification commands

Each phase runs within a 600-second wall-clock cap with signal/timeout/finally process-group termination followed
by a kill trap. Builds use at most four jobs; all tests are serial and no extra load workers run. Every Swift command
uses `taskpolicy -b` and these same Command Line Tools testing flags:

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
for iteration in {1..5}; do
  taskpolicy -b swift test --skip-build --no-parallel --filter 'HeardTurnApp' "${flags[@]}"
done
taskpolicy -b swift test --skip-build --no-parallel \
  --filter 'HostConnection|Conversation|Chat|Heard|Refus|Capabilit' "${flags[@]}"
git diff --check
```

## Results

- Production build and test build passed with warnings treated as errors (4.92 and 32.27 seconds).
- Focused selection passed 5/5 runs: nine test functions in two suites, 14 case executions per run, 70 total.
  The five-run phase took 62.658 seconds.
- Broad serial selection passed: 549 test functions reported in 205 suites (121.227 seconds), with 547 completed
  passing function verdicts and 877 passing case executions. The existing `TmuxPasteAgentTests` suite and its
  `aNonAgentPaneRefusalReachesTheDeviceAsAPasteRefusal` test were skipped because tmux is unavailable on the VM.
- `git diff --check` passed. The manual `.swiftlint.yml` audit found no code lines over 120 columns. New test files
  are 116 and 92 lines. Type bodies fit 150 code lines; function bodies fit 40. The two model files retain their
  pre-existing `file_length` exemptions (276 and 1,102 physical lines); no lint disable was added. SwiftLint is
  unavailable, so this is a manual audit rather than a strict lint execution claim.
- The PR-shape checker's exact exclusions yield exactly two production files: `ConversationLog.swift` and
  `HostConnectionStore.swift`; neither matches `SECURITY_PATHS`. No online issue, review or PR check was attempted.

## Host follow-up

The VM cannot build the iOS app. On the host run `scripts/verify.sh sim` and strict SwiftLint. C1 needs integration
compilation against the shared model; visible refusal styling, VoiceOver and hello advertising belong to C2.
A real host/device refused request remains necessary for physical-device or live round-trip proof after all slices.
No TestFlight upload or installation is in scope.
