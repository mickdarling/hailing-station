# Tap-capture mask liveness clock (#965, #977)

## Mechanism confirmed before implementation

Both failures wait on the same mechanism. In `CapturePlaybackSuppression.ledger`, creating a player's first
ledger calls `watchLiveness`. Its MainActor task sleeps with `Task.sleep(for: .seconds(1))`, checks that the
weak player and ledger still exist and that this remains the current ledger, then calls `reconcile(using:)`.
The loop is driven by this real asynchronous sleep, independently of replies and scene activation.
`CaptureSuppressionLedger.reconcile` drops owners whose registered liveness is false (or missing), updates the
tap mask, and ends playback suppression when no owner remains. `healed` removes liveness registrations and
reports the dropped owner count through that player's existing reporter. The echo guard then keeps its existing
400 ms tail, already driven by an injected clock in these tests.

In #965 the owner has no liveness registration, so the first watcher poll heals it. In #977 the synthetic
interruption ends the audio stream; awaiting the real consumer task makes its generation's `active` flag false.
The UI recording flag still awaits cleanup, but does not keep this stream live. The same watcher heals that
owner. Neither failure indicates a different poll interval or a second healing mechanism. The supplied CI
failures report successful checks arriving after the three-second deadline under scheduling contention.

This record uses offline source inspection and synthetic VM tests only; it makes no physical-device claim.

## Fix and invariants

`ReplyPlaybackController.captureLivenessSleep` is an internal, per-player dependency. Its default still calls
`Task.sleep` with the watcher's unchanged one-second duration. `watchLiveness` captures that dependency before
starting its task, preserving the weak player/ledger captures, current-ledger identity guard, thrown-sleep exit,
reconciliation order, owner checks, notifications, and playback behavior. Set the dependency before the first
hold creates a ledger. There is no global clock override or public API change. Only two production files change;
`scripts/verify.sh` and `TIMING_SUITES` are untouched.

The two regression tests install `TapCaptureLivenessClock` before beginning capture. The helper suspends with
checked continuations, waits for the watcher to register its sleep, installs the player's existing heal reporter,
and advances exactly one sleep. The test resumes only when the watcher reports the actual heal. It checks one
healed owner, the exact one-second requested interval, ended suppression, ledger removal, and the existing mask
tail/release assertions. The system-end test also verifies suppression remains held before advancing the poll.
The helper stops the watcher's next sleep by throwing after healing and removes its reporter. No test body
blocks a cooperative thread, and no timeout or existing assertion is relaxed. All explanatory comments remain.

Additional deterministic tests prove that a live owner survives a poll and heals on a later poll after it ends,
and that one player's clock cannot advance another player's watcher. Both use the production watcher and heal
reporter. The existing tests continue to cover the app's real stream consumer with synthetic audio/session IO.

## Load evidence and results

The old executable was built from unchanged main-15d5. Under exactly four `yes` workers it passed 20/20
parallel runs of `AmbientTapCapture`: 21 reported tests in four suites per run (420 reported tests total),
including both original regressions. Neither supplied CI deadline failure reproduced. This VM reports eight
logical CPUs; four load workers plus a narrow, four-wide test filter do not reproduce the three-core CI runner's
full parallel workload. The supplied CI failures remain evidence of scheduling-delayed successful heals; this
local result is explicitly a failure to reproduce them, not a claim to have disproved them.

With the seam, the same four-worker load and filter passed 20/20 parallel runs and 20/20 serial runs: 23 reported
tests in five suites each (920 reported tests total). Each original regression passed 40 times under load. The
two additional tests verify live-owner retention and per-player clock isolation. No assertions failed.

| Phase | Result | Active elapsed seconds |
| --- | --- | ---: |
| Baseline build with tests, warnings as errors | passed | 174.825 |
| Baseline parallel load, 20 runs | passed; failure not reproduced | 41.091 |
| New build, warnings as errors | passed | 7.244 |
| New build with tests, warnings as errors | passed | 51.256 |
| New parallel load, 20 runs | passed | 15.225 |
| New serial load, 20 runs | passed | 25.054 |
| Broad serial filter | passed; 304 tests in 67 suites | 90.824 |

The broad serial filter also passed all 304 reported tests in 67 suites, bringing new-source verification to
1,224 reported tests across 41 runs. There were no skips in that broad run.

All loaded phases stayed far below ten minutes and killed/reaped their four workers before the next phase.
The real-time waits for other jobs are excluded from active phase elapsed times; no load workers ran during
those initial idle waits. Simulator and physical-device verification were outside this synthetic VM task.

## Exact command harness

Paths below replace local checkout/evidence paths with `<scratch>`: put the checkout in `<scratch>/repo`,
the following runner in `<scratch>/evidence/phase.py`, and the gate in `<scratch>/evidence/gate.sh`.
The idle gate runs before **each** Swift invocation, including `--skip-build` tests. Waiting for other jobs is
outside a phase's active-time budget. Each active phase has a 590-second process timeout, signal handlers,
and `finally` cleanup that kills and reaps only its own process groups. A loaded phase starts exactly four `yes`
workers after the idle gate; cleanup kills and reaps all four. SwiftPM jobs, compiler jobs, and Swift Testing
parallel width are capped at four, one, and four respectively. No phases run concurrently.

The gate is the required loop:

```sh
#!/bin/bash
while pgrep -f "swift-build|swift-test|swift-frontend" >/dev/null; do sleep 60; done
```

Runner (Python standard library only):

```python
import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(__file__).resolve().parent
repo = root.parent / 'repo'
name, mode, repeat, load, *args = sys.argv[1:]
flags = ['-j', '4', '-Xswiftc', '-j1', '--disable-automatic-resolution',
 '-Xswiftc', '-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks',
 '-Xswiftc', '-plugin-path', '-Xswiftc', '/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing',
 '-Xlinker', '-rpath', '-Xlinker', '/Library/Developer/CommandLineTools/Library/Developer/Frameworks',
 '-Xlinker', '-rpath', '-Xlinker', '/Library/Developer/CommandLineTools/Library/Developer/usr/lib']
os.environ['SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH'] = '4'
children = []
def cleanup(*_):
    for child in children:
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
    for child in children: child.wait()
def stop(*_):
    cleanup()
    sys.exit(130)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGALRM, stop)
start = None
results = []
try:
    for index in range(int(repeat)):
        print('waiting for VM', index + 1, flush=True)
        gate = subprocess.Popen(['/bin/bash', str(root / 'gate.sh')], start_new_session=True)
        children.append(gate)
        gate.wait()
        children.remove(gate)
        if start is None:
            start = time.monotonic()
            signal.alarm(590)
        if load == 'load' and not children:
            for _ in range(4):
                children.append(subprocess.Popen(['yes'], stdout=subprocess.DEVNULL, start_new_session=True))
        remaining = 590 - (time.monotonic() - start)
        if remaining <= 0: raise TimeoutError('phase cap')
        command = ['taskpolicy', '-b', 'swift', mode, *flags, *args]
        path = root / f'{name}-{index + 1:02}.log'
        with path.open('w') as out:
            child = subprocess.Popen(command, cwd=repo, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
            children.append(child)
            try: code = child.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                raise TimeoutError('phase cap')
            children.remove(child)
        results.append(code)
        print(name, index + 1, 'exit', code, 'elapsed', round(time.monotonic() - start, 2), flush=True)
        if code and mode == 'build': break
finally:
    cleanup()
    (root / f'{name}-summary.txt').write_text(f'results={results}\nelapsed={time.monotonic() - start if start else 0:.3f}\n')
```

Commands, executed from `<scratch>`, with sources/tests at main-15d5 for the first build and the baseline
executable retained for `old-loaded` via `--skip-build`. The prepared source edits were applied while that
baseline executable waited for the VM; no intervening build changed it. Subsequent builds use the new sources.

```sh
python3 evidence/phase.py old-build build 1 idle --build-tests -Xswiftc -warnings-as-errors
python3 evidence/phase.py old-loaded test 20 load --skip-build --parallel \
  --filter AmbientTapCapture --skip DiagnosticReplyComposition
python3 evidence/phase.py new-build build 1 idle -Xswiftc -warnings-as-errors
python3 evidence/phase.py new-build-tests build 1 idle --build-tests -Xswiftc -warnings-as-errors
python3 evidence/phase.py new-loaded-parallel test 20 load --skip-build --parallel \
  --filter AmbientTapCapture --skip DiagnosticReplyComposition
python3 evidence/phase.py new-loaded-serial test 20 load --skip-build --no-parallel \
  --filter AmbientTapCapture --skip DiagnosticReplyComposition
python3 evidence/phase.py broad test 1 idle --skip-build --no-parallel \
  --filter 'AmbientTapCapture|AmbientWiring|ReplyPlayback|TapCapture|AudioCapture' \
  --skip DiagnosticReplyComposition
```

An initial baseline invocation with `--num-workers 4` was rejected before any test ran: this toolchain supports
that SwiftPM option only for XCTest. Its load phase was stopped and cleaned up. The valid runs above instead
set the toolchain's `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`; those CLI rejections are not behavioral
failures or included in test counts. No `DiagnosticReplyComposition` test was executed.

## Hand lint review

SwiftLint is unavailable on the VM. The strict warning thresholds in `.swiftlint.yml` were checked by hand:
changed Swift files have 192, 193, 166, 191, 61, and 46 physical lines (all below 200); the largest changed type
body has 149 nonblank/noncomment lines (limit 150). Changed function bodies remain below 40 lines, their
complexity stays below 10, and they have at most two required parameters. No code line exceeds 120 columns.
New identifiers meet the minimum length, type nesting stays below two, and there are no new force operations,
lint suppressions, or shortened explanatory comments. `git diff --check` passes.

All work stayed offline: no remote fetch, push, PR/issue mutation, installation, or device operation was performed.
