# Device heard-turn app verification (#923, PR C1/C2)

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

## C1 results

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

## C2 design and verification

C2 is stacked directly on C1, without PR B. It changes exactly four production files:
`Apps/Hail-iOS/ConversationChatView.swift`, `Apps/Hail-iOS/ConversationChatView+Metadata.swift`,
`Apps/Hail-iOS/PastedBlockView.swift`, and `Sources/HailCore/Transport/HostConnection+Protocol.swift`.

- The heading includes `notSent` alongside `overheard`, retaining its secondary colour. Both states use a
  `.quinary` bubble and secondary message/link colour. The visibility filter still checks only `overheard`, and
  pasted-block display and paste labels retain their existing overheard-only conditions.
- `ConversationChatView.accessibilityLabel` returns "You said, not sent" before the text for a refused heard turn;
  "You said, heard but not sent" remains the overheard label. No state is appended after the message text.
- Every original explanatory comment in `ConversationChatView.swift` is retained verbatim, including the full
  #717 scroll rationale, #766 header, overheard filter, player destination, streaming sheet, #636 placement,
  #412 context menu and "Titles where they fit". Only the uncommented playback buttons move to the existing
  metadata extension to keep the view's file and type body within limits.
- The device hello advertises `HeardTurns.capability`. The new
  `HeardTurnAppAdvertisingTests.deviceHelloAdvertisesHeardTurnsAlongsideHeardTextAndRefusals` checks the actual
  hello alongside both existing capabilities. `HostConnectionAmbientHeardTests` requires it with both legacy and
  correlated heard frames. The protocol file's extension is split in place to keep its bodies within 150 lines.
- C2 uses the same bounded, background-priority commands above, including five focused runs and the exact broad
  serial filter. Package tests cover the model and hello, not app rendering or VoiceOver; those require the host.

C2 production and test builds passed with warnings treated as errors (1.70 and 2.95 seconds).
The focused selection passed 5/5 runs: ten test functions in three suites and 15 case executions per run,
75 total, in a 68.496-second phase. The broad serial selection passed: 550 test functions reported in 206 suites
(121.800 seconds), with 548 completed passing function verdicts and 878 passing case executions. The same existing
tmux suite/test skip as C1 remains; no other skips or failures were reported.

The manual `.swiftlint.yml` audit covers every changed Swift file: `ConversationChatView.swift` is 175 lines,
the metadata extension file 176, `PastedBlockView.swift` 91, the advertising test 20, and the amended existing test
49. The protocol file is 209 lines with its pre-existing file-length exemption; no lint disable was added.
Type/extension bodies are at most 150 code lines, functions at most 40, and code lines at most 120 columns.
The view's type body is 128 code lines and its bubble function body is 40. All 25 original view comments match
main verbatim, and `git diff main-a154 codex/923-app-view -- Apps/Hail-iOS/ConversationChatView.swift` is checked
for removed comment lines before delivery. `git diff --check` passes. SwiftLint is unavailable on the VM.
The PR-shape checker's exclusions yield four production files for C2 against C1; none matches `SECURITY_PATHS`.
No online issue, review or PR check was attempted.

## Host follow-up

The VM cannot build the iOS app. On the host run `scripts/verify.sh sim` and strict SwiftLint for each branch.
C1 needs integration compilation against the shared model. For C2, check that the moved playback buttons and new
labels compile; inspect refused turns in light/dark appearance and large Dynamic Type for a greyed bubble,
secondary text and "You · not sent" heading. Hide overheard remarks and confirm refused heard turns remain visible.
Use VoiceOver to confirm "You said, not sent" comes before the words, while the separate refusal notice is announced
once. Confirm heard-but-not-sent labels, pasted blocks, context menus and Pause/Replay/Mute still work.
A real host/device refused request remains necessary for physical-device or live round-trip proof after all slices.
No TestFlight upload or installation is in scope.
