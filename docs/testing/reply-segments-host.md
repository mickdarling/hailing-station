# Reply segments host rendering verification (#932 P2)

Scope: host segmentation and per-segment owned vbsay rendering only, on the Dev Work VM.
Fix round 1 starts at merged P2 base `142ddbc4c134f24724558839bf8b7bb4031c17b7` (#953), which includes
P1 squash `b86b2fbf`. Initial implementation evidence below used P1 head
`e1be1fbb683516040c6159719a9f27862ebecb7a`; the final section records the new fix-round checks. All audio is synthetic zero/pattern PCM;
no provider, network, other clone, install, upload, installed-build replacement or physical device was used.
**P3 must merge before any haild deploy of P2.** The producer now emits `segmentEnd` locally; per-peer
`reply_segments` capability stripping, `reply_yield` handling and the backstop belong to the listener in P3.
P2 does not change `Sources/HailDaemonKit/Listener`, coaching speech, acknowledgement clips or Announcer.
This is not live captured-output round-trip or physical playback proof. P4/P5 remain deferred.

## Implementation and traceability

`ReplySegmenterTests` (10 functions) covers default and overridden configuration, invalid/boundary values,
common abbreviations/initialisms, decimals, versions, URL/path internal punctuation, ellipses, closing quotes
and brackets, question/exclamation marks, newlines/list markers, last-clause preference and word fallback,
no empty segments, exact one-segment input identity and the join property. Its deterministic generated
property test checks 324 combinations per run, including sentence/word bounds and repeatability.

`ReplySegmentation` injects both limits through the existing reply environment-tuning mechanism:
`HAILD_REPLY_SEGMENT_MAX_SENTENCES` (1–20, default 2) and `HAILD_REPLY_SEGMENT_MAX_WORDS` (1–300, default 30).
Defaults are v1, pending Mick. Malformed, out-of-range or overflowing overrides retain that limit’s default
and write one content-free stderr warning naming the variable, never its value. The reply proceeds.
Words are whitespace-delimited; newlines separate sentences/items. CJK `。！？．` and ASCII `!?` terminate
without whitespace, retaining following closing quotes/brackets. ASCII periods retain their lexical protection.
Unspaced joins preserve every character, and trailing-closer trimming uses a linear index walk. Abbreviations use a documented lexical
rule rather than language inference. `...`/`…` end before an uppercase next token. Only whitespace at joins
can change; one-piece input is returned unchanged. No segmentation code logs text.

`ReplySegmentCLITests` (13 methods) uses the real executable, existing private local socket harness and
extended synthetic vbsay fixture. It proves:

- Full text retained; one descriptor/stream, unique envelope IDs, continuous sequence and ordered segment PCM.
- Remainder flush marking and exact-size/no-remainder marking, with a held complete frame at non-final EOF.
- Final marker last, with no segment marker on the final segment; shared foreground frame budget and pacing
  admission across segments.
- One-segment legacy frame sizes/bytes/key shapes and actual parent-executable wire-byte comparison for
  remainder, exact-size and files-only modes. Only independently minted UUIDs and envelope timestamps are
  normalized in the captured wire bytes; PCM, JSON formatting/keys, sequence and all other fields must match.
  P1 retained main's renderer/framing path and false marker omission; this comparison uses its exact head.
- Supersession mid-reply and cooperative cancellation mid-segment: no later renderer, reaped children and
  existing cleanup behavior. Cancellation cancels terminal submission too, as before; supersession sends
  the terminal marker. Renderer failure in segment two retains only its abnormal nonempty output leaf for
  deferred recovery, terminates the reply and never starts segment three.
- Unified-log timing outcomes: exactly one whole-reply `played`, `played_unmeasured` (files-only), `failed`,
  `cancelled` or `superseded` outcome, as appropriate. No per-segment content enters test records or logs.
- Files-only fallback is segmented too: one renderer per segment, last frame of last stable raw file marked.
  File publication shares incremental progress so failure recovery retains the accepted sequence.

Renderers run sequentially: retire and join each owned child before spawning the next. This keeps one active
renderer and preserves its cancellation handler, cancellation signals, cleanupDeferred and waitForCleanup
boundary. There is one reply timing recorder/context/pacer/budget. No speculative later renderer can survive
cancellation or a segment failure. The fake-renderer overhead test uses five tiny segments and measures four
gaps including retirement/cleanup, spawn/interpreter startup, EOF and socket acknowledgement; this is not a
vbsay synthesis or device latency benchmark.

## Offline commands and load controls

Working directory: `~/codex-workspaces/hs-932`. Logs/wrappers and the baseline executable stay outside the repo.
Each phase runs through the following local deadline/kill-trap wrapper (590 seconds, below ten minutes).
It stops descendants, including separate sessions, on timeout or SIGINT/SIGTERM.

```python
# /tmp/hs932-tools/phase.py
import os, signal, subprocess, sys, time
child = subprocess.Popen(sys.argv[1:], start_new_session=True)
def stop(signum=None, frame=None):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True)
    pairs = [tuple(map(int, row.split())) for row in rows.splitlines()]
    descendants = {child.pid}
    while True:
        added = {pid for pid, parent in pairs if parent in descendants} - descendants
        if not added:
            break
        descendants |= added
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in descendants:
            try: os.kill(pid, sig)
            except ProcessLookupError: pass
        if sig == signal.SIGTERM: time.sleep(0.5)
    child.wait()
    sys.exit(124 if signum is None else 128 + signum)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    sys.exit(child.wait(timeout=590))
except subprocess.TimeoutExpired:
    stop()
```

`/tmp/hs932-tools/swift` wraps every build/test in `taskpolicy -b`, four SwiftPM jobs and one compiler worker
per target, disables automatic resolution, and supplies the required local Testing framework/plugin paths:

```bash
#!/bin/bash
set -euo pipefail
command="$1"
shift
case "$command" in
 build|test)
 exec /usr/sbin/taskpolicy -b /usr/bin/swift "$command" --jobs 4 -Xswiftc -j1 --disable-automatic-resolution "$@" \
 -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
 -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
 -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
 -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib ;;
 *) exec /usr/bin/swift "$command" "$@" ;;
esac
```

Initial implementation verification commands (PATH points at that wrapper):

```bash
export PATH=/tmp/hs932-tools:$PATH
python3 /tmp/hs932-tools/phase.py swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-tools/phase.py swift build --build-tests -Xswiftc -warnings-as-errors
# Baseline was built at the P1 head before edits, then copied outside the repository:
# cp .build/debug/haild /tmp/hs932-results/haild-p1
for round in 1 2 3 4 5; do
  python3 /tmp/hs932-tools/phase.py swift test --skip-build --no-parallel --filter ReplySegmenterTests
  REPLY_SEGMENTS_BASELINE_HAILD=/tmp/hs932-results/haild-p1 \
    python3 /tmp/hs932-tools/phase.py python3 -m unittest discover -s Tests/ReplyCLITests -p test_reply_segments.py
done
REPLY_SEGMENTS_BASELINE_HAILD=/tmp/hs932-results/haild-p1 \
  python3 /tmp/hs932-tools/phase.py python3 -m unittest discover -s Tests/ReplyCLITests
python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh core
python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh other
python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh timing
python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh audit
python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh offline-scripts
# Shell checks were rerun with verify.sh's optional-bin handling after an initial harmless missing-bin diagnostic:
python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh shellchecks
# Diagnose the earlier unchanged-core failure against an export of the exact P1 tree:
mkdir -p /tmp/hs932-p1-baseline
git archive e1be1fbb683516040c6159719a9f27862ebecb7a | tar -x -C /tmp/hs932-p1-baseline
python3 /tmp/hs932-tools/phase.py swift build --package-path /tmp/hs932-p1-baseline --build-tests -Xswiftc -warnings-as-errors
python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh baseline-core
git diff --check
```

`verify-lane.sh` loads the function definitions from the local `scripts/verify.sh` (everything before its
final `case "$cmd" in`, with only its working-directory line pointed at this checkout), then dispatches:

```bash
case "$1" in
 core) run_captured swift test --skip-build --no-parallel --filter "$CORE_PATTERN" --skip "$TIMING_PATTERN" ;;
 other) run_captured swift test --skip-build --no-parallel --skip "$CORE_PATTERN" --skip "$TIMING_PATTERN" ;;
 timing) run_captured swift test --skip-build --no-parallel --filter "$TIMING_PATTERN" ;;
 baseline-core) run_captured swift test --package-path /tmp/hs932-p1-baseline --skip-build --no-parallel --filter "$CORE_PATTERN" --skip "$TIMING_PATTERN" ;;
 audit) audit_cli ;;
 shellchecks)
   dirs=(scripts)
   [[ ! -d bin ]] || dirs+=(bin)
   while IFS= read -r file; do bash -n "$file"; shellcheck "$file"; done < <(find "${dirs[@]}" -type f \( -name '*.sh' -o -name 'hail-*' \) | sort)
   ;;
 offline-scripts)
   dirs=(scripts)
   [[ ! -d bin ]] || dirs+=(bin)
   while IFS= read -r file; do bash -n "$file"; shellcheck "$file"; done < <(find "${dirs[@]}" -type f \( -name '*.sh' -o -name 'hail-*' \) | sort)
   scripts/tests/test-testflight.sh
   scripts/tests/test-host.sh
   python3 -m unittest discover -s Tests/LocalIntentEvalTests
   python3 -m unittest scripts/tests/test_verify_test_output.py
   ;;
esac
```

These are all three complete package selections from `verify.sh test`, including haild and HailDaemonKit;
parallel lanes run serially to respect the VM worker cap. Its capture/event/stall checks remain in force.
Splitting lanes into separate phases enforces the ten-minute cap per phase. ReplyCLITests runs in full,
serially, as in `verify.sh scripts`; network-dependent trace dependency installation is excluded.

## Results (initial implementation)

- Both final builds passed with warnings treated as errors (2.58 s build; 3.97 s build-tests).
- New tests: five final runs each passed, 8 Swift functions/run (40 executions) and 11 CLI methods/run
  (55 executions). The property loop checks 324 generated cases/run (1,620 across those five runs).
  CLI runs took
  10.334, 10.049, 9.998, 10.065 and 10.017 seconds.
- Sequential fake-renderer overhead: four gaps/run, 20 measured gaps total. Run medians 30.9, 28.8, 29.0,
  29.3 and 29.0 ms; maximum gap across these runs 31.4 ms. This includes ownership/cleanup and fake startup.
- Full ReplyCLITests: 107 methods passed serially in 211.289 seconds, including the baseline wire comparisons.

- Final core lane: 915 tests in 195 suites passed in 120.210 seconds. An earlier complete core run failed two assertions in
  `AudioInputFailureStateTests.explicitMismatchPublishesFailedAttemptAndConfirmedActualInput`
  (`resolution` became automatic and `attempted` became USB rather than the expected failed/built-in state).
  No HailCore source or test was changed. The final complete rerun passed; a P1-only comparison is recorded below.
- An initial cancellation fixture incorrectly sent SIGINT to the foreground CLI, which terminates directly.
  It was corrected to SIGTERM the detached job through its cooperative task cancellation handler. The test
  now verifies child reaping, cleanup, no later renderer and one cancelled timing outcome; all five final runs pass.

- Final other-target lane: 1,502 tests in 275 suites passed in 417.273 seconds; six issues were already marked known by the suite.

- Final timing/process lane: 524 tests in 82 suites passed in 222.768 seconds, including owned renderer
  lifecycle, cancellation, retirement, deferred cleanup and process ownership suites. All three final package
  lanes passed: 2,941 test functions total, plus the other-target lane's six explicitly known issues.
- Audit/policy CLI lane passed.

- Offline script components passed: shell syntax/ShellCheck, TestFlight version fixtures and 35 API-key/toolchain
  fixture tests (22.909 s), host lifecycle fixtures, 5 local-intent tests and 25 verification-output/stall-driver
  tests (96.846 s). Optional `bin/` is absent; the initial temporary enumerator printed a harmless missing-bin
  diagnostic while still checking all script files. The corrected enumerator matches verify.sh's optional-bin
  handling; its bounded shell-check rerun passed. Optional actionlint is not installed.
- The isolated export of exact P1 head built all tests with warnings as errors in 164.62 seconds. Its full
  core lane also passed all 915 tests in 195 suites (120.218 s). The earlier unchanged-core failure did not
  reproduce in either the final P2 sweep or this parent comparison; no assertions were relaxed.
- `git diff --check` passed. No simulator or physical-device results are claimed.

- `.swiftlint.yml` checked by hand: new segmenter/config file and type bodies fit 200/150 warning limits;
  new Swift test file/type also fits. New/changed helpers fit 40 code lines, five parameters, complexity/nesting
  limits and 120 non-comment columns. No force casts/unwraps or new lint exemptions were added.
  `ReplyCommand.swift` retains its existing file-length exemption. SwiftLint is not installed.
- PR-shape's exact exclusions count two production files: `Sources/haild/ReplyCommand.swift` and
  `Sources/haild/ReplySegmenter.swift` (configuration shares the latter). No renames; no changed path matches
  `SECURITY_PATHS`. The three test files plus the test fixture and two docs are excluded. Online issue/PR
  state, PR-shape and independent review were not attempted under the offline constraint.
- Full Xcode/XcodeGen and SwiftLint are unavailable; simulator/macOS Xcode lanes and strict automated lint
  could not run. Pinned PyYAML 6.0.3 is absent, so spec-trace dependency installation/tests were skipped
  under the no-installs/no-network constraint. The P2 expectations are mapped to actual executing tests above.


## Fix round 1 (#953)

Against P1 squash `b86b2fbf` (and against the supplied P2 base), exactly two production files change: `Sources/haild/ReplySegmenter.swift` and
`Sources/haild/ReplyCommand.swift`. No other clone, network, deployment, GitHub mutation, simulator or
physical device is used. All PCM is synthetic. The same 590-second descendant-kill wrapper and
`taskpolicy -b` Swift wrapper above enforce four build jobs / one compiler worker per target; all test lanes
run serially in separate phases. Baseline compilation uses an archive of the local `origin/main`
`893acc01337ac21b9bba03542cb19ceeab4d8d84`. This offline tracking ref predates P1; its
`ReplyCommand.swift` is identical to the P1 squash’s renderer. The squash’s protocol files are inherited,
not P2 production changes.

The new checks cover unspaced CJK (three sentences, limit two), mixed CJK/Latin, full-width periods,
quotes/brackets, unspaced ASCII !/?, exact join preservation and whitespace word counting. Both malformed
configuration settings now warn and retain their own default, while valid companion overrides survive.
Two structural cases exercise 16,000 trailing closers without a wall-clock assertion.

`ReplyFileStabilityTests.growingFileNeedsAnEarlierEqualSizeAndSentFilesAreSkipped` checks a real directory:
pass one publishes nothing; a file grows before pass two and is excluded, while stable nonempty files
retain modification-date order. Empty/non-raw files and already-sent files are excluded. A later equal-size
observation admits the previously growing file. `ReplySegmentCLITests` checks multiple raw files, an empty
last file, exactly-once publication and the marker on the last stable file sent on pass two. The fallback
again enumerates the directory in `for _ in 0..<2`, retains observed sizes and a sent set, and requires a
positive current size equal to an earlier pass, as on main.

Exact fix-round commands (PATH points at the wrapper):

```bash
export PATH=/tmp/hs932-tools:$PATH
python3 /tmp/hs932-tools/phase.py swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-tools/phase.py swift build --build-tests -Xswiftc -warnings-as-errors
for round in 1 2 3; do
  python3 /tmp/hs932-tools/phase.py swift test --skip-build --no-parallel \
    --filter 'ReplySegmenterTests|ReplyFileStabilityTests'
  python3 /tmp/hs932-tools/phase.py python3 -m unittest discover -s Tests/ReplyCLITests -p test_reply_segments.py
done
mkdir -p /tmp/hs932-r2-main
git archive origin/main | tar -x -C /tmp/hs932-r2-main
python3 /tmp/hs932-tools/phase.py swift build --package-path /tmp/hs932-r2-main \
  --product haild -Xswiftc -warnings-as-errors
cp /tmp/hs932-r2-main/.build/debug/haild /tmp/hs932-r2-results/haild-main
REPLY_SEGMENTS_BASELINE_HAILD=/tmp/hs932-r2-results/haild-main \
  python3 /tmp/hs932-tools/phase.py python3 -m unittest discover -s Tests/ReplyCLITests
for lane in core other timing audit offline-scripts shellchecks; do
  python3 /tmp/hs932-tools/phase.py bash /tmp/hs932-tools/verify-lane.sh "$lane"
done
# Also compare the supplied P1 squash, since the offline origin/main ref predates it.
git archive b86b2fbf | tar -x -C /tmp/hs932-r2-main
python3 /tmp/hs932-tools/phase.py swift build --package-path /tmp/hs932-r2-main \
  --product haild -Xswiftc -warnings-as-errors
cp /tmp/hs932-r2-main/.build/debug/haild /tmp/hs932-r2-results/haild-main-p1
PYTHONPATH=Tests/ReplyCLITests REPLY_SEGMENTS_BASELINE_HAILD=/tmp/hs932-r2-results/haild-main-p1 \
  python3 /tmp/hs932-tools/phase.py python3 -m unittest \
  test_reply_segments.ReplySegmentCLITests.test_single_segment_matches_legacy_frames_byte_for_byte
git diff --check
git diff origin/main HEAD -- Sources/haild/ReplyCommand.swift | grep '^-.*//'
```

The lane wrapper is regenerated from this checkout’s `scripts/verify.sh` definitions before execution;
its dispatch is the same as above. Results and the final comment/SwiftLint audit follow. Logs are outside the repository at
`/tmp/hs932-r2-results/`.

- Both final warnings-as-errors builds passed: 2.06 seconds (build), 2.93 seconds (build-tests).
- Final focused Swift: 3/3 runs passed, 10 segmenter functions plus one file-stability function per run
  (33 executions). The generated property loop checks 324 combinations/run, 972 over those three runs.
  Final Swift runs took 0.126, 0.124 and 0.155 seconds, including the two 16,000-closer cases each time.
- Final focused CLI: 3/3 runs passed, 13 methods/run (39 executions), in 11.613, 11.424 and 11.564 seconds.
- Initial test-build diagnostics caught two missing `try` annotations in new assertions. The new directory
  test initially compared `/var` and `/private/var` URL spellings; it now compares fixture filenames and uses
  the enumerated URLs in the sent set. No production behavior or test expectation was relaxed.
- Manual `.swiftlint.yml` check: added/changed non-comment code fits 120 columns; new Swift files fit
  200 lines, type bodies fit 150 code lines, helpers fit 40 code lines / five parameters and the configured
  complexity/nesting limits. No force unwrap/cast or lint suppression was added. The existing
  `ReplyCommand.swift` file-length exemption remains; SwiftLint is unavailable.
- Removed-comment audit against local `origin/main`: no explanatory text is lost. The exact grep above
  reports only `Relay stdout PCM as it arrives (#268): no files, no polling.` and
  `A vbsay without VBSAY_STDOUT writes only files; two passes establish their stability.` as removed lines.
  Both are restored verbatim with four fewer leading spaces because P2 moved the outer recovery block
  to the renderer boundary. These are indentation-only relocations, not deleted explanations. The cleanup
  ownership/deadline comment is verbatim at the failure-path suspension. All other main comments are retained.

- Full serial ReplyCLITests: 109 methods passed in 213.527 seconds, including all three actual wire comparisons
  against local `origin/main` (remainder, exact-size and files-only). Only independently generated UUIDs and
  timestamps are normalized; PCM, JSON keys/encoding, ordering and sequence remain byte-identical.
- Complete serial core lane: 915 tests in 195 suites passed in 122.667 seconds.
- Complete serial other-target lane: 1,505 tests in 276 suites passed in 406.611 seconds, with six issues already
  marked known by the suite. No expected failure was added or assertion relaxed.
- Complete serial timing/process lane: 524 tests in 82 suites passed in 220.691 seconds. All three package
  lanes passed: 2,944 test functions total, with the other-target lane’s six existing known issues.
- Audit/policy CLI lane passed.
- Offline script lane passed: shell syntax/ShellCheck; TestFlight version fixtures plus 35 API-key/toolchain
  fixtures (23.249 seconds); host lifecycle fixtures; 5 local-intent tests; and 25 verification-output/stall-driver
  tests (97.097 seconds). The separate shell-check lane also passed. No installs or network dependency steps ran.
- Online issue/PR checks, independent review, SwiftLint, simulator and physical-device checks remain outside this
  offline host run. No deployment, upload or installed-build change is claimed.
- The supplied P1 squash was also archived into the same private baseline tree and built with warnings as
  errors (26.54 seconds). The dedicated legacy-wire method passed all three modes against that binary too:
  remainder, exact-size and files-only; the same UUID/timestamp-only normalization applies.
- `git diff --check` passed. The final commit contains only these fixes, their tests and this host evidence record.
