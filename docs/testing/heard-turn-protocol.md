# Optional heard-turn protocol verification (#923, PR A)

This slice adds protocol support only. It does not mint or send turn IDs, advertise `heard_turns`, correlate device
state, or change chat/refusal behavior. The host constructors use the default `turn: nil`, preserving their wire
shape without changing HailDaemonKit. Host generation and capability gating (PR B) and device advertising and
correlation (PR C) remain deferred.

Verification was host-local and synthetic on the Dev Work VM, using the Command Line Tools toolchain. No simulator,
physical-device, installed-build, or live captured-output proof is claimed. No network access or installs were used.
Each build/test phase ran with at most four jobs, a 600-second limit, and signal/timeout cleanup that terminates the
phase's process group (then kills it if needed). Swift commands ran under `taskpolicy -b`.

Commands (the supplied testing flags are included for every Swift build/test):

```bash
flags=(
  -j 4 --disable-automatic-resolution
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
taskpolicy -b swift build -Xswiftc -warnings-as-errors "${flags[@]}"
taskpolicy -b swift build --build-tests -Xswiftc -warnings-as-errors "${flags[@]}"
for iteration in {1..10}; do
  taskpolicy -b swift test --skip-build --no-parallel \
    --filter 'HeardTurnProtocolTests|HostConnectionAmbientHeardTests|RequestRefusalNoticeTests' "${flags[@]}"
done
taskpolicy -b swift test --skip-build --no-parallel \
  --filter 'Control|Schema|Protocol|Frame|AmbientHeard|VoiceRoute|HostConnection' "${flags[@]}"
taskpolicy -b .build/debug/hail-protocol-gen
for iteration in {1..10}; do
  taskpolicy -b python3 -m unittest discover -s Tests/ProtocolSchemaTests
done
python3 -m unittest scripts/tests/test_check_schema.py
python3 scripts/check_schema.py
git diff --check
```

Results:

- Both builds passed with warnings treated as errors.
- Focused Swift verification passed 10/10 runs: 10 test functions in three suites per run, 22 case executions per run.
- Broad serial verification passed once: 438 test functions in 133 suites (91.576 seconds).
- Schema verification passed 10/10 runs: six test methods per run, 60 total method executions.
- The existing schema validator's 11 tests passed. All 47 positive fixtures passed; all 98 negative fixtures were
  rejected by the built-in validator. The schema was regenerated; existing frame fixtures did not change.
- `.swiftlint.yml` limits were checked by hand, including existing scoped disables: added Swift lines fit 120 columns;
  new test files, functions, types, parameter counts, nesting, and complexity fit the configured limits. The decoder
  initializer remains within the 40-line function warning limit. SwiftLint is not installed on this VM.
- The PR-shape checker's exclusions yield exactly four production files; its `SECURITY_PATHS` match none of the
  changed files. No online PR-shape/review or issue-state check was attempted under the offline constraint.

`HeardTurnProtocolTests` covers both wire shapes, omitted nils, invalid/null UUIDs, unknown fields, command/error-code
restrictions, encoder rejection of turns on other error codes, and unchanged legacy error extension tolerance.
`HostConnectionAmbientHeardTests` verifies unchanged conversation ordering with and without `turn` and no capability
advertising. `RequestRefusalNoticeTests` verifies unchanged notice, announcement, and connection behavior with and
without `turn`. `Tests/ProtocolSchemaTests/test_heard_turn_schema.py` checks the corresponding schema constraints.
Other daemon test edits only ignore the new defaulted associated value in existing pattern matches.
