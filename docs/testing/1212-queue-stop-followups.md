# Queue-stop follow-ups: PR 1c-1

Part of #1212. Base: `d02c7d3113a6e4669bf3537061378fadd1eadee2`.
This is synthetic host-package and CLI evidence on the Dev Work VM. No simulator, physical-device proof,
live captured-output round trip, installed build replacement, TestFlight delivery, push or PR is involved.
The Listener/ and PushEndpoint/ changes are security-critical; no independent approval is claimed.

## Implementation and traceability

- **D:** `Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift:174` accepts an explicit `admittingAudio` signal and increments
  `replyFlightRevision` after a successful final enqueue, synchronously in the session actor turn, before any
  transport-result await. Only `enqueueSessionUpdateAudio` in `Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdateAudio.swift:94`
  supplies that signal. Card delivery and renderer preflight keep the default false. No `HostSession.swift`
  change is needed.
- `SessionUpdateStopCoalescingTests.admittedSessionUpdateAudioRequiresAnotherDeviceStop` uses actual loopback
  WebSockets, a synthetic renderer and an injected stop clock. Stops at 0 and 500 ms surround audio admitted
  at 200 ms. It asserts two exact `stop_playback` payloads, exactly one revision increment, and exact audio
  shape for streaming, final-only PCM and an empty final marker.
- `SessionUpdateAudioAdmissionTests.admissionInvalidatesCoalescingBeforeTransportCompletion` holds the audio
  completion callback, then asserts the revision increment and renewed stop eligibility while completion
  is still held. The hold uses a callback and mutex, without blocking a cooperative thread.
- `SessionUpdateSpeechTests` asserts card-only delivery, renderer preflight without audio, and privacy-rejected
  audio preserve the revision and coalesce the second stop inside the one-second window. Speech joins and
  socket barriers establish completion; no negative assertion follows a settling delay.
- **E:** `Sources/HailDaemonKit/PushEndpoint/LocalReplyEndpoint+Submission.swift:154` explicitly compares every `LocalReplyResponse` field except
  `isReplyAudio`. `LocalReplyResponseEqualityTests` separately asserts absent/null/present audio-key detection,
  decoded/constructed equality in both directions, and inequality for each of the other ten fields, including
  `isDispatch`. Legacy fallback can still distinguish an absent key from explicit null.
- **T1 / #1216:** `Tests/HailDaemonKitTests/AmbientModeRestoreTests.swift:148` waits on the third child's
  exact control-file contents with a reload-specific 60-second monotonic deadline. It preserves exact equality
  with `RestoreRig.gate`; a missing re-send cannot satisfy the wait or the final assertion.
- **T2 / #1217:** `Tests/ReplyCLITests/test_rightyo_cli.py:29` (`RightyoCLITests.invoke`) accepts a keyword-only timeout, defaulting to 15 s. Only
  `test_oversized_record_is_refused` requests 60 s. Its 1,200,001-byte input and exact exit-code-8 assertion remain.

## VM commands and controls

The fresh `vw1212c1` clone is seeded solely by a local git bundle, with no GitHub fetch or dependency resolution.
Source/test commit: `b098e00906001232932faa0b2762294a3ede5229`.
Apple Swift 6.3.3 and Command Line Tools run each phase sequentially after the shared build/test lane is idle.
Every phase uses background priority and a 590-second process-group watchdog with signal/finally TERM/KILL
cleanup. SwiftPM uses four jobs, each compiler one worker, and tests run without parallelism. No synthetic load
workers, installation or upload run. Host/VM SHA-256 comparisons cover every changed Swift/Python file before
and after verification. The separate warnings-as-errors wrapper uses a fresh build directory and an external
Swift shim preserving the worker and dependency-resolution controls.

```bash
flags=(
  -j 4 --disable-automatic-resolution -Xswiftc -j1
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
taskpolicy -b swift build --build-tests "${flags[@]}" -Xswiftc -warnings-as-errors
# Three times each, under separate outer caps:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter \
  'HailDaemonKitTests\.(SessionUpdateSpeechTests|SessionUpdateStopCoalescingTests|SessionUpdateAudioAdmissionTests|LocalReplyResponseEqualityTests|AmbientModeRestoreTests)'
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests -p test_rightyo_cli.py
# Five additional invocations:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" \
  --filter 'HailDaemonKitTests\.AmbientModeRestoreTests'
# Once, then one invocation per daemon selection in the results table:
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter "$selection"
# Separate fresh wrapper, with the external worker-cap shim:
/bin/zsh ~/codex-workspaces/vw-werr.sh vw1212c1
```

## VM results

Every requested phase exited 0. Swift counts below are the Swift Testing function/suite summaries; parameterized
rows are exercised within those functions.

| Phase | Runs | Tests / suites per run | Result / seconds |
| --- | ---: | --- | --- |
| Fresh package/test build, warnings as errors | 1 | build | pass; 229.39 |
| New/changed Swift selection | 3 | 20 / 5 | pass; 15.489, 16.099, 15.554 |
| RightyO test file | 3 | 15 Python tests | pass; 6.680, 5.892, 6.042 |
| Additional AmbientModeRestoreTests | 5 | 9 / 1 | pass; 13.593, 14.242, 14.868, 14.009, 13.699 |
| Full Reply CLI | 1 | 145 Python tests | pass; 242.925 |
| `\w*(SessionUpdate\|LocalReply\|PushEndpoint)` | 1 | 100 / 19 | pass; 10.523 |
| `\w*(DeviceVoiceStop\|WebSocket\|Listener)` | 1 | 81 / 13 | pass; 40.230 |
| `Ambient[A-M]` | 1 | 134 / 25 | pass; 107.033 |
| `Ambient[N-S]` | 1 | 317 / 65 | pass; 339.273 |
| `Ambient[T-Z]` | 1 | 214 / 49 | pass; 137.795 |
| `(?!Ambient)\w*Ambient` | 1 | 30 / 9 | pass; 12.933 |
| `(?!Ambient\|Reply\|LocalReply)[A-Ma-m]\w*Reply` | 1 | 57 / 10 | pass; 1.812 |
| `(?!Ambient\|Reply\|LocalReply)[N-Zn-z]\w*Reply` | 1 | 96 / 20 | pass; 28.694 |
| `Reply` | 1 | 113 / 29 | pass; 5 expected known issues; 71.934 |

Each daemon selector in the table is prefixed with `HailDaemonKitTests\.`. The non-prefix selections include
family names occurring after another prefix (for example, `LocalSessionUpdateTests`, `HostReply...` and
`OwnedReply...`), so the requested families are covered beyond their leading-name groups. No test is skipped.
The five known-issue observations are deliberate timeout/cancellation harness-health expectations already declared
with `withKnownIssue` in `ReplyRecipientHandoffWaitTests`. No unexpected failure occurred.

The separate fresh warnings-as-errors wrapper exited 0, reported **`werr build=0`**, and completed its build in
**229.10 seconds** (230 seconds including the wrapper). Full-log inspection finds **zero errors** and **120
warnings**, all in the existing CLT missing-`ModuleCache` debug-symbol category, with no other warning category.
This passes Swift warnings-as-errors; it does not claim warning-free linker output.

## Host lint, scope and cleanup

Strict SwiftLint with the full Xcode developer directory and the independent 120-column awk check both exit 0
and print nothing for **all eight changed Swift files**. Both logs are zero bytes. Commands:

```bash
swift_files=( $(git diff --name-only d02c7d3113a6e4669bf3537061378fadd1eadee2 HEAD -- '*.swift') )
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict --quiet "${swift_files[@]}"
awk 'length($0)>120 {print FILENAME ":" FNR ":" length($0)}' "${swift_files[@]}"
git diff --check d02c7d3113a6e4669bf3537061378fadd1eadee2 HEAD
```

The production count is **three** under `scripts/pr-shape.py`'s exact exclusions and rename handling. There are
no renames. The only production files are:

- `Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdateAudio.swift`
- `Sources/HailDaemonKit/PushEndpoint/LocalReplyEndpoint+Submission.swift`

`HostSession.swift` is not needed. No additional production file or lint suppression is introduced.
Only the three authorized GitHub issue reads run. No push, PR, online PR-shape or CI result, or independent
review verdict is claimed. Every local commit ends with `Part of #1212`; the two completed test-only follow-ups
also carry their respective `Closes #1216` and `Closes #1217` lines.

All nine changed Swift/Python files match host SHA-256 checksums before and after verification. The VM worktree
is clean. Scoped cleanup removes the workspace `.build`, the separate `vw1212c1-werr` directory, and both external
compiler shim paths, then verifies no owned build/test processes remain. Logs and checksum/lint/cleanup evidence
remain outside version control under `vw1212c1` names. No generated build product or private deployment data is
committed. This verification note is the only change after the tested source/test commit.
