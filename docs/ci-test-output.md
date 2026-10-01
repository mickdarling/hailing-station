# Decouple test execution from console backpressure

Part of #185; investigated while PR #186's verify lane was blocked.

## Controlled evidence

At composition head `5ec33cde3aa901536ac56e22285fe7f21baf4688`, redirecting the
unchanged full parallel Swift suite through a consumer that sleeps 10 ms per
output line produced eight deadline/watchdog issues in 770 tests/125 suites.
Redirecting the same command to a regular file first passed all 770 tests/125
suites in 4.935 seconds; subsequently replaying it through the same slow consumer
preserved success. This is a local controlled output-backpressure reproduction,
not a proven explanation for every historical CI failure or for the exact four
issues in CI run36923943145. The local Swift6.2.4 and CI Swift6.3.3 toolchains differ.

Verbose synchronous test-event reporting shares the process with tested deadlines.
A slow pipe consumer can block reporting while real clocks keep advancing.
The verification script now captures merged stdout/stderr to a private regular
temporary file, then prints every byte after tests finish. Parallelism, test
selection, assertions, production deadlines and guard budgets are unchanged.

## Failure contract

- Test failure returns the original nonzero status, even if printing also fails.
- Printing failure after test success also fails verification.
- Capture creation failure prevents test execution.
- Failed captures remain for inspection; successful captures alone are removed.
- There is no console progress during Swift execution; the existing job timeout
  still bounds the CI lane. Interrupted captures may remain for diagnosis.

`scripts/tests/test_verify_test_output.py` asserts a regular owner-only output
descriptor, unchanged parallel/warnings-as-errors arguments, complete stdout and
stderr replay including output larger than a pipe buffer, exact failure status,
printing failure and capture creation failure. These regressions failed on the
old direct-console implementation; they are run by the required verifier.

This does not solve arbitrary disk exhaustion, hostile temporary directories,
production guard-budget determinism (#50/#56), unrelated network errors (#144),
or every cooperative-fixture scheduling risk. #185 remains open for its other
acceptance criteria. No live host or device behavior is changed.
