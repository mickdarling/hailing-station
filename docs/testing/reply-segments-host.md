# Reply segments host rendering verification (#932 P2)

Scope: host segmentation and per-segment owned vbsay rendering only, based on P1 head
`e1be1fbb683516040c6159719a9f27862ebecb7a`, on the Dev Work VM. All audio is synthetic zero/pattern PCM;
no provider, network, other clone, install, upload, installed-build replacement or physical device was used.
**P3 must merge before any haild deploy of P2.** The producer now emits `segmentEnd` locally; per-peer
`reply_segments` capability stripping, `reply_yield` handling and the backstop belong to the listener in P3.
P2 does not change `Sources/HailDaemonKit/Listener`, coaching speech, acknowledgement clips or Announcer.
This is not live captured-output round-trip or physical playback proof. P4/P5 remain deferred.

## Implementation and traceability

`ReplySegmenterTests` (8 functions) covers default and overridden configuration, invalid/boundary values,
common abbreviations/initialisms, decimals, versions, URL/path internal punctuation, ellipses, closing quotes
and brackets, question/exclamation marks, newlines/list markers, last-clause preference and word fallback,
no empty segments, exact one-segment input identity and the join property. Its deterministic generated
property test checks 324 combinations per run, including sentence/word bounds and repeatability.

`ReplySegmentation` injects both limits through the existing reply environment-tuning mechanism:
`HAILD_REPLY_SEGMENT_MAX_SENTENCES` (1–20, default 2) and `HAILD_REPLY_SEGMENT_MAX_WORDS` (1–300, default 30).
Defaults are v1, pending Mick. Malformed/out-of-range overrides fail before any text/audio publication.
Words are whitespace-delimited; newlines separate sentences/items. Abbreviations use a documented lexical
rule rather than language inference. `...`/`…` end before an uppercase next token. Only whitespace at joins
can change; one-piece input is returned unchanged. No segmentation code logs text.

`ReplySegmentCLITests` (11 methods) uses the real executable, existing private local socket harness and
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

Exact final verification commands (PATH points at that wrapper):

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

## Results

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
