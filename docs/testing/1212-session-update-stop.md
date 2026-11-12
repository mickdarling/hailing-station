# Session-update speech cancellation at playback stop

Part of #1212. PR 1c-C is local work stacked on `9c46ad964b104d4cb038fdbebb3b00c961e7124d` (PR 1c-2).
This is synthetic host-package and CLI verification, not simulator, physical-device, captured-output round-trip,
installation, upload, deployment or independent security-review evidence. Nothing is pushed and no PR is created.

## Cancellation boundary

`SessionUpdateFence.startSpeech` records the owning connection and original privacy revision with the running
job, before its asynchronous operation can begin. The existing single-renderer policy and joined retirement remain.
`cancelProactive(connection:)` removes only that connection's buffered-audio receipts and revokes only its running
job. The job's task-local identity reaches the existing final synchronous `enqueue` fence. Revocation and admission
use the same mutex, closing the check/enqueue race even when a renderer attempts publication after cancellation.
Task cancellation happens outside the mutex, so renderer cancellation handlers cannot re-enter a held fence lock.
A fresh job gets a fresh identity and permission after retirement; stopping does not close the fence.

`WebSocketListener.stopReplyPlayback` (`WebSocketListener.swift:606`) takes the scoped cancellation snapshot before
its first asynchronous hop.
This is the shared accepted-device-stop and RightyO playback-dismissal boundary. It cuts playback first (line 616),
posts each
exact `session_update_cancel` using the same peer method as quiet (line 622), and only then awaits queued-target
resolution (line 625).
Neither renderer cancellation nor the device retraction waits for that resolution or its 250 ms deadline.
The diagnostic is content-free: `session_update_speech_cancelled reason=stopped update=<id> connection_scoped=true`.
No card or text is withdrawn. Mute passes `markQueuedAudio: false`, preserving its prior behavior.

Quiet still closes the whole fence and retracts every connection's receipts. Privacy still calls the global
revision-filtered cancellation path: an old delayed privacy entry cannot cancel a newer public update. These
contracts are unchanged; a device stop does not borrow their global scope.

## Deterministic coverage

- `SessionUpdateStopTests.acceptedStopCancelsOnlyAudioBeforeFirstFrameOrMidstream`: actual loopback sockets,
  device and RightyO stop paths, before-first-frame and between-frame holds. Exact retained card payload, outbound
  stop, update-specific retraction, content-free id log and joined publication refusal. Device rows also prove
  a later update receives both full frames and a new identity.
- `SessionUpdateStopTests.deviceAStopPreservesDeviceBRendererAndBufferedIdentity`: B starts speech, A starts
  listening and sends an accepted stop, and B completes. Quiet subsequently retracts B's preserved buffered identity.
- `SessionUpdateStopOrderingTests`: both target resolution and its timeout are held while the cut, retraction
  and renderer refusal complete. The stop's dismissal record remains pending until resolution is released.
- `SessionUpdateStopRegressionTests`: actual spoken mute permits the remaining session-update frame; quiet and
  the real privacy-entry reply-hold observer still cancel running speech and send the exact update retraction.
- `SessionUpdateCancelTests`: owner registration before any receipt, refusal at final fence enqueue even when
  the operation ignores cancellation, later-job permission, per-connection receipt retention and existing bounds.
- `SessionUpdateStopCoalescingTests` now consumes the newly required retraction after its follow-up stop.
  `TaskProgressEnvironmentIdentityTests` supplies an explicit owner to its retained synthetic speech task.

All holds use continuations. Negative socket assertions follow joined work and ordered ping/pong barriers;
none use settle-then-negative assertions or block cooperative Swift threads.

## Verification procedure

Source/test commit: `1118cf1c33bcb4755539bc6aeff0e115ce70174e`. The fresh Dev Work VM workspace is `vw1212cc`,
cloned from a host-local bundle without a network fetch. SHA-256 checks match all ten changed Swift files.
Phases run sequentially, only after the shared build/test lane is idle, at background priority. Each has a
590-second watchdog with signal/finally TERM/KILL cleanup for its process group and owned descendants. The runner
unblocks inherited termination signals before installing its handlers. SwiftPM uses four jobs and each compiler
one worker; tests run without parallelization. No synthetic load workers or dependency fetch run.

The VM uses `TMPDIR=/private/tmp` and `umask 022`; inherited group/world write permissions were removed from this
owned workspace before CLI checks. The exact Swift flags and command forms are:

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
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter '<selection>'
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests
```

Each command runs inside the watchdog above. The focused selection runs three times:

```text
HailDaemonKitTests\.(SessionUpdateStopTests|SessionUpdateStopRegressionTests|SessionUpdateStopOrderingTests|SessionUpdateCancelTests|SessionUpdateStopCoalescingTests|TaskProgressEnvironmentIdentityTests)
```

The family selections are `(SessionUpdate|LocalSessionUpdate|DeviceVoiceStop|ReplyQueuedAudio)`,
`HailDaemonKitTests\.Ambient[A-M]`, `HailDaemonKitTests\.Ambient[N-S]`, `HailDaemonKitTests\.Ambient[T-Z]`,
`HailDaemonKitTests\.(?!Ambient)\w*Ambient|^(?!HailDaemonKitTests\.)\w+\.Ambient`, and `Privacy`.
The extra Ambient selection includes matching non-daemon suites. Privacy includes every matching module.

The existing warnings-as-errors wrapper runs from a task-local copy whose only change is a separate build-log
basename, avoiding collision with the phase's stdout log. An external `swift` shim appends `-Xswiftc -j1
--disable-automatic-resolution`, preserving the worker cap. Its effective build is:

```bash
# Same flags as above, fresh separate build path; the wrapper reports the actual build exit code.
taskpolicy -b swift build --build-tests "${flags[@]}" --build-path ../vw1212cc-werr \
  -Xswiftc -warnings-as-errors
# Require the wrapper's `werr build=0` marker and inspect its complete build log.
```

The first transfer/build overlap produced a modified-input build error. Subsequent source-synchronized builds
passed. An initial focused run caught a mute fixture missing its addressing declaration; changing that synthetic
turn to the direct `mute` phrase corrected the fixture. All final focused repeats use the corrected source.

## Final results

All times below are phase wall time, including harness startup; Swift counts are test-function/suite summaries.
The focused selection executes 22 cases, including parameterized rows, on each repeat.

| Phase | Runs | Tests / suites per run | Result / seconds |
| --- | ---: | --- | --- |
| Final pretest build, warnings as errors | 1 | build | pass; Swift build 14.06 |
| New/changed focused suites | 3 | 16 / 6 | pass; 7.361, 6.957, 6.614 |
| SessionUpdate, LocalSessionUpdate, DeviceVoiceStop, ReplyQueuedAudio | 1 | 166 / 44 | pass; 55.388 |
| Daemon Ambient A–M | 1 | 134 / 25 | pass; 106.058 |
| Daemon Ambient N–S | 1 | 317 / 65 | pass; 344.919 |
| Daemon Ambient T–Z | 1 | 214 / 49 | pass; 135.644 |
| Remaining Ambient selection | 1 | 334 / 103 | pass; 389.437 |
| Cross-module Privacy | 1 | 313 / 89 | pass; 332.510 |
| Full Reply CLI | 1 | 145 Python tests | pass; 245.784 (unittest: 245.389) |
| Separate warnings-as-errors wrapper | 1 | fresh package/test build | pass; 230.336 (`werr build=0`) |

The wrapper's full build log has zero errors and 120 warnings, all in the existing CLT missing-module-cache
(debug-symbol) category; no other warning category is present. Its Swift build completed in 229.21 seconds.
This is a passing Swift warnings-as-errors build, not a claim of warning-free linker/debug-symbol output.

Host strict SwiftLint and the awk 120-column check exit 0 and print nothing for all ten changed Swift files:

```bash
swift_files=( $(git diff --name-only 9c46ad964b104d4cb038fdbebb3b00c961e7124d HEAD -- '*.swift') )
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict --quiet "${swift_files[@]}"
awk 'length($0)>120 {print FILENAME ":" FNR ":" length($0)}' "${swift_files[@]}"
git diff --check 9c46ad964b104d4cb038fdbebb3b00c961e7124d HEAD
```

Final SHA-256 checks again match all ten changed Swift files between host and VM. Scoped cleanup removed the
workspace `.build`, separate wrapper build, and compiler shim paths; no owned build/test processes remained.
No generated build product is committed.

The PR-shape checker's exact exclusions yield **three production files** against the requested base, with no renames:

- `Sources/HailDaemonKit/Notify/SessionUpdateSpeech.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift`

The third file is needed to supply the exact connection and captured privacy epoch when registering the task,
before the asynchronous speech operation starts. Tests and this document are excluded by the checker.
This remains `security:critical` work. No online PR-shape, CI, independent review, simulator or physical-device
proof is claimed. Only the two authorized GitHub reads were made; no push, PR or external review record was created.
