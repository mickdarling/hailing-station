# Command runner scheduling

Part of #1156. This change concerns synthetic macOS subprocess scheduling. It does not establish
simulator, physical-device, installed-build or live captured-output behavior.

## Cause and implementation

`ProcessCommandRunner` previously used a detached Swift task for the blocking stdout read and
`Process.waitUntilExit()`. This occupied a cooperative-pool thread for the child's lifetime. Its
stderr drain and asynchronous drain join used the constrained global utility queue. Saturating that
queue could delay command completion after the child had already exited, as in the #979 diagnosis.
The overcommit safety-path changes in #980 had not covered this runner.

Each run now creates a labelled serial dispatch queue for preparation, synchronous launch, stdout
reading, process-exit waiting and the stderr join. A separate labelled serial queue drains stderr
concurrently. These serial queues target the overcommit root queue, so neither path waits for a
constrained global worker. A checked throwing continuation suspends the caller until the work ends;
no cooperative-pool thread blocks on the child. The stderr `DataBox` locks only to transfer bytes,
with the blocking read evaluated before acquiring its lock.

Executable resolution, null stdin, `beforeLaunch` placement and the `launch.perform { try process.run() }`
admission boundary are unchanged. Refused admission and definite launch failures still throw directly.
An admission error after possible execution still waits for both drains and process exit before throwing.
The exit code and separate UTF-8 stdout/stderr decoding are unchanged. Completion still precedes the
caller's next operation; the adapter continues to own paste-then-Enter ordering.

Caller cancellation is neither propagated nor observed. The command runs to completion and returns
its result or launch/admission error, matching the previous `Task.detached { … }.value` behavior.
The continuation never resumes early. This change adds no command timeout or kill; those are #1167.

## Regression coverage

- `GlobalQueueStarvationTests.OwnedStdioChildCommandRunner.aCompletedCommandReturnsOnTime` uses the
  existing `whileGlobalQueueStarved` helper and its eight-second hold. A shell writes one line to each
  pipe, exits successfully, and must return both exact lines within the family's four-second bound.
  The nested suite uses the `OwnedStdioChild` family name so the existing verification timing pattern
  selects it for the serial lane.
- `CommandLaunchAdmissionTests.aVerboseChildDrainsBothPipesConcurrently` interleaves 8,192 twelve-byte
  lines on each pipe: 98,304 bytes per pipe, exceeding 64 KiB on both. Both strings and exit status
  must match exactly. Sequential draining would wedge while the other pipe fills.
- Existing launch evidence and adapter admission tests remain unchanged.

## Dev Work VM evidence

Verification uses the Dev Work VM, Swift 6.3.3, a fresh main clone synchronized with the local commit
bundle. Each phase waits for the shared lane to become idle, runs at background task policy with at
most four build workers, and has a ten-minute watchdog that terminates the process group on exit.
The baseline run stashes only the runner fix, retaining the new regression test; the fix is restored
for subsequent runs. All evidence is synthetic.

The baseline and fixed-source builds completed successfully in 85.22 s and 5.06 s respectively.
The single-test baseline failed exactly on the elapsed-time assertion:

```text
Expectation failed: (elapsed → 8.025711666 seconds) < (GlobalQueueStarvationTests.bound → 4.0 seconds)
command completion took 8.025711666 seconds
Test run with 1 test in 2 suites failed after 9.060 seconds with 1 issue.
```

The same regression passed with the fix: one test in 1.291 s, including saturation setup. The fixed
four-second command-completion assertion passed; successful assertions do not print their operands.

The first full-family attempt lacked the build-directory symlink used by the publisher CLI fixture;
that case reached its 60-second test limit (eight tests, one issue, 73.286 s overall). Correcting only
that verification setup made the complete serial family pass: eight tests in 13.520 s. The regression
and focused tests use the same fixed production source throughout subsequent verification.

The focused serial selection was `HailDaemonKitTests\.(CommandLaunch|Tmux|ProcessCommand)`:

| Run | Tests / suites | Swift Testing duration | Phase wall time | Exit |
| --- | --- | --- | --- | --- |
| Focused 1 | 162 / 32 | 105.709 s | 106.884 s | 0 |
| Focused 2 | 162 / 32 | 104.248 s | 105.262 s | 0 |
| Focused 3 | 162 / 32 | 104.148 s | 105.218 s | 0 |

The two CI-shaped target runs enable parallel execution, cap Swift Testing's maximum parallelization
width at four, and exclude exactly the 26 timing families in `scripts/verify.sh`. An initial invocation
with the XCTest-only worker-count option was rejected before any tests started (exit 1, 0.153 s).
The supported Swift Testing parallelization-width option is used for the actual target runs.

Temporary fixture instrumentation records launch and exit timestamps only for the first parameterized
submission case (peer retirement, plain paste). Timings include timestamp-logging overhead. The
list-to-paste interval starts at the first list launch; exit-to-next-launch starts at its exit timestamp.
The diagnosis baseline was 1.1–2.0 s for exit-to-next-launch and up to 4.7 s for list-to-paste.

The instrumented test build completed in 12.38 s. Both parallel target runs passed:

| Run | Tests / suites | Swift Testing duration | Phase wall time | Expected known issues | Exit |
| --- | --- | --- | --- | --- | --- |
| Parallel 1 | 1,650 / 298 | 155.697 s | 157.774 s | 13 | 0 |
| Parallel 2 | 1,650 / 298 | 159.801 s | 161.224 s | 13 | 0 |

The 13 known issues come from existing tests that deliberately exercise missing-arrival, handoff,
cancellation and gate-timeout diagnostics inside `withKnownIssue`; neither run had an unexpected issue.

| First-case interval | Diagnosis baseline | Parallel 1 | Parallel 2 |
| --- | --- | --- | --- |
| List-sessions exit → next launch | 1.1–2.0 s | 0.134338 s | 0.035807 s |
| First list launch → paste launch | Up to 4.7 s | 0.409416 s | 0.213799 s |
| First list exit → paste launch | Not recorded here | 0.404849 s | 0.208943 s |

The instrumentation was uncommitted and reverted after the two runs. During verification, main
advanced from `19a3617442c10144978df00382c39dfda2efa5ab` to
`fe177cd516afbce69c707e42bff1128d2fc7ee85` with documentation-only changes. Sources, tests, scripts and
package inputs were identical across those main revisions. The fix was rebased onto the latter and
synchronized by bundle before the remaining checks; the tested source and test contents are unchanged.

`python3 -m unittest discover -s Tests/ReplyCLITests` passed all 124 tests in 232.856 s
(233.044 s phase wall time, exit 0).

Host lint used strict SwiftLint with the full Xcode developer directory and the requested non-comment
120-column `awk` check on every changed Swift file. Both exited 0 and printed nothing. The change has
one production file under the PR-shape checker's exact exclusions, two test files and this document.

The warnings-as-errors wrapper built the package and tests with four workers: `werr build=0`,
exit 0, 85.23 s build duration and 86.085 s phase wall time. The toolchain emitted missing `.pcm`
module-cache-reference warnings; this is a successful build, not a claim of warning-free tool output.

Both VM build directories and the fixture build-directory symlink were removed after verification.
No verification processes remain running. No build was installed or uploaded, and no branch was pushed.
The command timeout/kill expectation remains deferred to #1167.
