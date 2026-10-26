# Tmux submit clock (#917, #901)

This is synthetic VM evidence from 2026-10-26, using the supplied offline issue brief and Part 12 repro.
It is not a physical-device test, a live captured-output round trip, or a real tmux validation.

## Seam and coverage

`TmuxSubmitClock` is internal and supplies a synchronous continuous instant plus an asynchronous sleep.
The unchanged public adapter initializer selects the real continuous clock; an internal initializer accepts
an injected clock. Acceptance, confirmation, retry steadiness, and pre-paste clearance use the same source.
Production timing values, observation order, deadline comparisons, and cancellation handling are unchanged.

`ManualSubmitClock` advances only on probe sleeps, by the requested duration (at least 1 ms for nonpositive
intervals), and yields without parking a continuation. Scripted runner delays never consume virtual time.
Finite settle/confirm/clear deadlines bound polling; the converted suites also have one-minute real time limits.
All VM verification phases had a 600-second process watchdog with signal/finally cleanup. Builds used four jobs;
the single loaded phase had exactly four `yes` workers, all killed and reaped in its cleanup handler.

`SubmitHarness` and `EvidenceHarness` use virtual time by default. This converts the #910 retry cases in
`TmuxSubmitConfirmationTests` and `TmuxSubmitEvidenceTests`, and the #901 families `TmuxPrePasteTests`,
`TmuxStaleInputTests`, and `TmuxCursorInputTests`. The 5-second `retryConfirmLimit` is removed; retries use the
ordinary 500 ms test limit. Existing outcome, key-order, retry-identity, and taint assertions remain intact.
Clear-limit assertions measure the injected clock; the no-late-retry check advances a virtual second.

Three external-cancellation boundary tests explicitly keep real time: abandonment during settle, cancellation
while clearing pending text, and refusal evidence after an abandoned paste. Their caller cancels from outside
the probe; letting virtual polling finish before that caller runs would test a different boundary.
The evidence ledger's real elapsed age is independent of the probe clock and remains unchanged.

`TmuxSubmitClockTests.aStalledRunnerKeepsTheScriptedOutcome` adds a real 600 ms delay to every scripted command,
following Part 12. It checks confirmed/retried/failed outcomes, exact submit evidence and Enter counts, and failed
submit taint. Its 200 ms poll interval bounds the intentionally slow repro to three polls per 500 ms confirmation
window. Before the seam, all three cases returned unverifiable (10 assertion failures, including the missing
retry and wrong taint). With virtual time the same script and delay pass all three cases. The original Part 12
old-limit repro also confirmed both retry scripts returned unverifiable on the baseline; it was not committed.

## Commands

Every Swift command ran under `taskpolicy -b`, with `-j 4` and these supplied toolchain flags:

```sh
FLAGS=(
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
taskpolicy -b swift build -j 4 "${FLAGS[@]}" -Xswiftc -warnings-as-errors
taskpolicy -b swift build -j 4 "${FLAGS[@]}" --build-tests
taskpolicy -b swift test -j 4 "${FLAGS[@]}" --skip-build --no-parallel --filter TmuxSubmitClockTests
# Repeated 50 times serially, then 20 times with the four capped/cleaned-up yes workers:
taskpolicy -b swift test -j 4 "${FLAGS[@]}" --skip-build --no-parallel \
  --filter 'TmuxPrePasteTests|TmuxStaleInputTests|TmuxCursorInputTests'
taskpolicy -b swift test -j 4 "${FLAGS[@]}" --skip-build --no-parallel --filter 'Tmux'
taskpolicy -b swift test -j 4 "${FLAGS[@]}" --skip-build --no-parallel --filter 'Tmux|LocalDispatch|InputPending'
```

## Results

- Both builds passed, including warnings-as-errors; final test compilation passed.
- Standalone forced-delay regression: 3/3 cases passed (37.374 s), after all three failed on the baseline.
- #901 trio: 50/50 serial runs passed (81.28 s phase), 13 tests each; 20/20 runs under four `yes` workers
  passed (29.66 s phase), 13 tests each. No leftover load workers remained.
- Final `Tmux` filter: passed, 128 tests in 27 suites (63.863 s), including ten real-tmux test skips.
- `Tmux|LocalDispatch|InputPending` filter: passed, 163 tests in 33 suites (66.540 s), with the same ten skips.
- The initial broad run exposed an external-cancellation evidence test outrunning its caller under virtual time.
  Its explicit real-time opt-in fixed all three assertions; its targeted rerun and both final broad filters passed.
- `git diff --check` passed. No simulator or physical-device verification was performed.

## Scope and preflight

The real `TmuxDeliveryCommitFakeTUITests` uses tmux plus SIGSTOP and a 60-second real time limit. Virtualizing
its observations would remove the process-stall behavior it tests. tmux is absent on this VM, and installation
was out of scope, so FakeTUI and the other tmux-dependent integration suites are skipped. Their host failure
remains outside this fix; no assertion or time limit in those suites changed.

The PR-shape exclusions count two production files, both under `Adapters/Tmux`, with no security-critical path.
No rename is involved. SwiftLint was unavailable; limits were checked by hand: submit file 199 lines, adapter
body 150 nonblank/noncomment lines, no changed code line over 120 columns, and changed function bodies below
40 lines. Defaulted parameters do not add to the required parameter count (at most five). The adapter retains its
existing file-length exception; its listing/command helpers moved into the existing same-file extension to keep
the actor within the type-length limit. No new lint exceptions were introduced.

No network access, remote Git fetch, push, PR/issue mutation, installation, or installed-build change occurred.
