# Queue-stop follow-ups: PR 1c-1 and PR 1c-2

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

## PR 1c-2: selection hook and unresolved-stop cutoff

Part of #1212. This slice implements **H and F only**, stacked on PR 1c-1 head
`827ed00d2dfaa851707bf277d540b9e4fa112c57`; main is `d02c7d3113a6e4669bf3537061378fadd1eadee2` (#1215).
Item C remains assigned to a later PR. The source/test commit is
`e1fd51f0f09ffcabddc34727ee5e7484dbaf0d1f`. This is local implementation and synthetic VM evidence,
not shipped behavior, a simulator run, physical-device proof, a captured-output round trip or delivery.

### H: synchronous retirement hook and authoritative mirror

- `HostSession.swift:233` stores the optional synchronous callback, supplied at listener session creation in
  `WebSocketListener.swift:264`. `HostSession+Routing.swift:571` invokes it after selection authorization succeeds,
  **before** changing the generation, clearing request owners or changing the selected target.
- `HostReplyDelivery.swift:797` collects the previous selected target, covered voice routes, request owners, and
  pinned/in-flight associations. `ReplyAudioQueue.selectionWillChange` at line 186 visits the connection's pending
  records under the queue lock, unions that first retiring snapshot into each record, and marks each record's
  own accepted cutoff. `captureTargets` at line 172 also retains an earlier first-session-hop snapshot before
  retirement or a privacy drop. Once a record has captured associations, later selections cannot widen its scope:
  accepting a stop on T, selecting U and returning to T must leave unrelated U playable.
- The same hook updates the current-selection mirror even when no stream has ever registered. Router `register`
  (`WebSocketListener.swift:1596`) keeps stream routing state but no longer writes the mirror. Neither a long-lived
  stream's opening generation nor a delayed child registration can replace the session's current selection.
- `resolve` (`HostReplyDelivery.swift:203`) removes and consumes the **updated pending record**, rather than the
  original `Stop` value copy. The generation-comparison floor fallback is removed entirely. The remaining general
  `floor` is the existing bounded-storage eviction mechanism; selection changes do not advance it.

Tests in `ReplyQueuedAudioSelectionTests`:

- `selectionBetweenAcceptanceAndSessionHopKeepsExactTargets`: continuation-held T→U and T→U→T, actual loopback
  selections, old T silent, queued U and an unrelated target playable, post-stop T playable.
- `pendingStopsKeepRetiringCoveredAndRequestTargets`: two separately held pending stops at different cutoffs;
  captures selected/covered routes and the retiring request owner, uses original Stop copies for resolution,
  checks unrelated U and post-cutoff tickets exactly. Each stop has its own single-waiter timeout hold.
- `longLivedStreamOpeningGenerationDoesNotRaiseFloor` and
  `lateRouterRegistrationCannotReplaceSessionSelectionMirror`: stale opening generation and actual stale router
  registration, respectively, with exact stopped/playable outcomes and a fresh ticket.
- `selectionAfterCaptureKeepsOriginalTargetOnly` preserves playback/device/privacy variants and retained text.
  `ReplyQueuedAudioSelectionAcceptanceTests` retains acceptance-time destination scope checks.
- `ReplyQueuedAudioProbeTests.slowPrivacyNoticeKeepsOtherDeviceStreamingAndOldQueueSilent`, row
  `restore-selection`, invokes the actual privacy restore under the router lock while media notices are held,
  before the connection's first router registration. A selection round trip occurs while the stop is pending;
  after privacy exit, old T is silent, queued U and streaming U play, and a fresh T ticket plays.

### F: unresolved stops preserve another device's streaming exemption

`ReplyAudioQueue.resolve` (`HostReplyDelivery.swift:203`) always marks the stopping connection and its retained
known targets at the accepted cutoff. A timeout, failed lookup or vanished connection advances the separate
`unpublishedFloor`, bounded by that same cutoff. Final admission at line 149 checks this floor only for jobs
whose first audio has not successfully enqueued. Connection stops still cut that connection's streams;
other connections keep the existing streaming exemption from target marks and from the unpublished floor.
The stop-wait predicate also recognizes this cutoff, preserving the existing rule that an already-silenced
unpublished job need not wait for another pending stop (`ReplyQueuedAudioPendingTests`). This does not change
the deferred repeated-stop policy. The immediate playback retirement/send order and the production **250 ms**
deadline are unchanged.

- `ReplyQueuedAudioBarrierTests.failedResolutionPreservesOtherDevicesStreamingAudio`: controlled timeout,
  closed-session lookup failure, and peer teardown. Actual sockets prove retained T text, silent covered queued T,
  a pre-cutoff U stream continuing on another device, and fresh T audio playing. The timeout callback and snapshot
  hold are captured at acceptance, and a registered continuation proves the first-frame wait before expiry.
- `unresolvableSnapshotCutsOnlyUnpublishedJobs` retains the privacy/playback and closed/missing-session matrix.
- `ReplyQueuedAudioProbeTests.slowPrivacyNoticeKeepsOtherDeviceStreamingAndOldQueueSilent`, rows `entry-timeout`
  and `restore-timeout`, hold media notices while the **real 250 ms timer** expires. The entry row uses the actual
  privacy pre-arm path; the restore row uses the actual restore function before registration. A continuation
  barrier establishes expiry and an exact monotonic-duration assertion establishes at least 250 ms. Both prove
  old covered audio remains silent after privacy exit, another device's U stream continues, and fresh T plays.

All new waits use async continuations; no cooperative thread is blocked. Negative socket assertions follow
completed operations and ping/pong barriers, with no settle-then-negative assertion.

### PR 1c-2 verification

The fresh Dev Work VM workspace is `vw1212c2`, seeded from local bundles only. All ten changed Swift files match
host SHA-256 checksums, and the VM checkout is at the source/test commit above. Every phase starts only when the
shared build/test lane is idle, runs at background priority, and has a 590-second watchdog and owned-process-tree
TERM/KILL cleanup. SwiftPM uses four jobs, each compiler one worker, with automatic resolution disabled and tests
not parallelized. No synthetic load workers or network dependency fetch run.

The final CLI/daemon/wrapper phases export `TMPDIR=/private/tmp` and use `umask 022`; the fresh clone's
inherited group/world write bits were removed in this owned workspace. The original full CLI attempt completed
145 tests in 244.413 s with five flush setup failures: `policy: unwritable("/tmp: Not a directory")`. macOS's
`/tmp` symlink is intentionally refused by the policy path check. After selecting the canonical temporary path,
the unchanged five-test flush suite passed in 7.260 s; the full CLI suite was then rerun. No production security
check or test expectation was relaxed.

The exact Swift flags and command forms are the PR 1c-1 commands above, with `vw1212c2` as the workspace/wrapper
argument. The focused filter is:

```bash
HailDaemonKitTests\.(ReplyQueuedAudioSelectionTests|ReplyQueuedAudioSelectionAcceptanceTests|ReplyQueuedAudioBarrierTests|ReplyQueuedAudioProbeTests|ReplyQueuedAudioPendingTests)
```

Every final phase exited 0 at the source/test commit above. Swift counts are function/suite summaries;
the focused selection executes 40 cases including parameterized rows, on each repeat.

| Phase / daemon selector | Runs | Tests / suites per run | Result / seconds |
| --- | ---: | --- | --- |
| Package/test build, warnings as errors | 1 | build | pass; 158.92 |
| Final focused selection | 3 | 20 / 5 | pass; 14.407, 15.063, 14.407 |
| Full Reply CLI | 1 | 145 Python tests | pass; 243.037 |
| `\w*(SessionUpdate\|LocalReply\|PushEndpoint)` | 1 | 100 / 19 | pass; 10.848 |
| `\w*(DeviceVoiceStop\|WebSocket\|Listener)` | 1 | 81 / 13 | pass; 38.386 |
| `Ambient[A-M]` | 1 | 134 / 25 | pass; 104.423 |
| `Ambient[N-S]` | 1 | 317 / 65 | pass; 340.495 |
| `Ambient[T-Z]` | 1 | 214 / 49 | pass; 136.448 |
| `(?!Ambient)\w*Ambient` | 1 | 30 / 9 | pass; 12.773 |
| `(?!Ambient\|Reply\|LocalReply)[A-Ma-m]\w*Reply` | 1 | 57 / 10 | pass; 1.831 |
| `(?!Ambient\|Reply\|LocalReply)[N-Zn-z]\w*Reply` | 1 | 96 / 20 | pass; 27.111 |
| `Reply` | 1 | 118 / 29 | pass; five expected known issues; 74.468 |
| `\w*(HostSession\|Routing\|Selection)` | 1 | 59 / 16 | pass; 6.339 |

Each daemon selector is prefixed with `HailDaemonKitTests\.`. Both leading-name and infix family names are covered;
the selector audit omitted no requested-family test file. The five known issues are the existing deliberately
declared timeout/cancellation harness-health observations in `ReplyRecipientHandoffWaitTests`. There are no
unexpected test failures or continuation-misuse warnings in the final run logs. Superseded verification logs remain
separately archived outside version control; the table reports only the final source.

The separate fresh warnings-as-errors wrapper exited 0, reported **`werr build=0`**, and completed its build in
**250.16 s** (251.601 s including the wrapper). Its full build log contains **zero errors** and **120 warnings**,
all CLT missing-`ModuleCache` debug-symbol warnings, with zero other warning categories. This passes Swift
warnings-as-errors without claiming warning-free linker output.

Strict SwiftLint and the independent awk check both exit 0 and print nothing for all ten changed Swift files;
both host logs are zero bytes. Whitespace validation also passes.

Preliminary builds caught test-fixture access, Swift Testing macro/Sendable inference and actor-isolation errors.
A preliminary focused run caught a fixed-target input helper used for U and a shared single-waiter hold. A later
fixture installed its snapshot hold after acceptance; that stalled run was terminated, its owned processes were
removed, and the callback was moved to acceptance. All these fixture issues were corrected before the final
verification reported above. The existing pending-stop tests also identified the wait-boundary check for the new unpublished cutoff;
that production correction was completed before restarting final verification.

Host lint covers **all ten changed Swift files** against the stacking base:

```bash
swift_files=( $(git diff --name-only 827ed00d2dfaa851707bf277d540b9e4fa112c57 HEAD -- '*.swift') )
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict --quiet "${swift_files[@]}"
awk 'length($0)>120 {print FILENAME ":" FNR ":" length($0)}' "${swift_files[@]}"
git diff --check 827ed00d2dfaa851707bf277d540b9e4fa112c57 HEAD
```

The checker's exact exclusions and rename handling count **four production files**, with no renames:
`Sources/HailDaemonKit/Listener/HostReplyDelivery.swift`, `Sources/HailDaemonKit/Listener/HostSession.swift`,
`Sources/HailDaemonKit/Listener/HostSession+Routing.swift`, and `Sources/HailDaemonKit/Listener/WebSocketListener.swift`.
This is security-critical work; independent review is pending and no approval is claimed. Only
`gh issue view 1212 --comments` and `gh pr view 1215 --comments` were used. There is no push, PR, online PR-shape,
CI or installed-build change. Each local commit ends with `Part of #1212`.


After verification, all ten changed Swift files again matched host SHA-256 checksums, and the VM checkout was
clean at the recorded source/test commit. Scoped cleanup removed the workspace `.build`, the separate wrapper
build directory, the optional local `-werr` path and both external compiler shim paths. No owned build/test process
remained. Logs, summaries and checksums remain outside version control under `vw1212c2` names. No generated build
product is committed. This verification record is the only change after the tested source/test commit.
