# Test output and console backpressure

Part of #185, alongside the serial timing lane of #208.

## The problem

Swift Testing reports test events synchronously, in the same process as the tests. When the console reading that output is slow (a busy CI log pipe, a slow terminal), reporting blocks while real clocks keep running, so tests with deadlines or watchdogs can fail for no fault of their own.

**Evidence (local, controlled):** the full parallel suite was piped through a reader that slept 10 ms per line. That produced eight deadline or watchdog failures in 770 tests. Redirecting the same run to a regular file passed all 770 tests in about 5 seconds, and replaying that file through the same slow reader afterwards changed nothing. This shows the mechanism; it does not prove the cause of every historical CI failure (the local and CI toolchains also differed).

## The fix

`scripts/verify.sh` runs both test lanes (parallel, and the serial timing lane from #208) through `run_captured`:

- Output (stdout and stderr together) goes to a private regular file, created with `mktemp` (owner-only), and is printed in full once the lane finishes.
- Parallelism, test selection, assertions and deadlines are unchanged. There is no live progress while a lane runs.
- A lane killed by a CI timeout or cancel prints no test output. That loses nothing: when its output is not a terminal, `swift test` writes test results only as it finishes, so a hanging lane showed only build lines in CI before this change too (checked with a hanging test through a pipe).

**Failure contract:**

- A test failure returns the original non-zero status, even if printing also fails.
- A printing failure after the tests pass also fails verification.
- If the capture file cannot be created, the tests do not run.
- A failed lane keeps its capture and names its path on stderr. That notice is best-effort, so an unwritable stderr cannot mask the status. A successful capture is removed.

## Tests

`scripts/tests/test_verify_test_output.py` runs `verify.sh test` against a fake `swift`. It checks:

- the capture is an owner-only regular file, and both lanes keep their arguments;
- both lanes are captured and replayed in full, including output larger than a pipe buffer;
- a failure stops at the parallel lane;
- the exact failure status;
- a printing failure;
- a capture-creation failure;
- an unwritable stderr.

These tests fail against the direct-console version. Fixture scratch directories are removed only when a test passes, so a failure keeps them for diagnosis.

## Not covered

Disk exhaustion, hostile temporary directories, guard-budget determinism (#50, #56), network errors (#144), and other scheduling risks. #185 stays open for its remaining criteria.
