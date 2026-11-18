# #1258 — optional host session-update cap (branch B)

Local source candidate, 2026-11-18. **Depends on branch A**, `fix/1258-unlimited-session-updates`,
head `5c4e133b9c6339ff9543906b5cc1cdba05c8fd8c`. Branch A starts at `origin/main` `38c62e4f9f457ac9212578253d8a898a9a4c81c5`.
This commit adds only the optional cap bridge, its tests and docs on top of A. For unlimited/default behavior,
socket regressions and mutation proof, see [branch A's record](1258-unlimited-session-updates.md).

All verification is synthetic and host-local. No live config, daemon install/restart, device build, physical
proof, push or PR is claimed. The host harness uses fake binaries/launchctl and scratch configuration only.

## Implementation and traceability

- Production code retains the implementation from original combined commit
  `2f4e953cdb8bab565f1818f83fdd578167849924`. The original configuration cases remain, with an added
  real-socket check of configured-cap refusals and the independent socket guard.
- Flat host.json keys `sessionUpdatePerSessionLimit` (JSON integer 1..10000) and `sessionUpdateWindowSeconds`
  (JSON integer 1..86400) are both absent by default. Both must be present together with `sessionUpdates: true`.
- `scripts/host.sh` validates typed values before changing the fake lifecycle job and emits
  `--session-update-per-session-limit N --session-update-window-seconds S`. The daemon validates again and
  applies the policy at startup. Removing both keys restores unlimited sends; changes require a restart.
- Configured caps retain the queue's sliding-window `rate_limited` refusal and retry timing; refusals spend
  no queue budget. Independently, A's socket runaway guard admits 60 submissions/minute per host, and its
  control bucket admits 120 status/quiet-on requests/minute. Reply traffic cannot spend either bucket.
  Held bounds remain 20 total, 5 per session, 4 hours.
- `SessionUpdateLimitConfigurationTests` checks absent/valid caps reaching the listener, boundaries,
  malformed/incomplete/duplicate values and disabled combinations. The shell harness checks typed JSON,
  exact generated arguments, compatibility when absent and preflight refusing invalid caps before fake stop.

## Original commands (before round-2 rebase)

Before **each** build/test command, the scratch `run-split-phase.py` runs:

```sh
/Users/mick/.local/share/jarvis/voicework-2026-11-11/hostslot-wait.sh
/Users/mick/.local/share/jarvis/voicework-2026-11-11/voice-quiet.sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export TMPDIR=/Users/mick/codex-workspaces/hs-1258-scratch
```

Each command below uses `python3 /Users/mick/codex-workspaces/hs-1258-scratch/run-split-phase.py <command>`;
the runner enforces 890 seconds after the gates and terminates only its own process group on timeout.

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdate|TaskProgress|LocalReplyEndpoint|ReplyQueuedAudioEndpoint|AmbientDuckTimeoutOptionsTests|AmbientSharedAuditTests|AmbientWiringOptionsTests|DiagnosticSessionTests|HostHealthSessionTests|SingleTerminalReplyFallbackTests|VoiceRouteListingTests'
taskpolicy -b bash scripts/tests/test-host.sh

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftlint lint --strict --quiet \
  Sources/HailDaemonKit/Listener/ConnectionProbeDaemon.swift \
  Tests/HailDaemonKitTests/SessionUpdateLimitConfigurationTests.swift
bash -n scripts/host.sh scripts/tests/test-host.sh
git diff --check
```

## Original results and change shape (before round-2 rebase)

- Build passed, exit 0: **521.12 seconds** (phase wall time 523.506 seconds).
- Strict lint passed on both changed Swift files. Shell syntax and whitespace checks passed.
- Byte comparisons confirm that both production files, the Swift configuration tests and shell test file
  exactly match `2f4e953cdb8bab565f1818f83fdd578167849924`.
- Serial Swift filter passed, exit 0: **273 tests in 70 suites**, **52.231 seconds** (phase 61.543 seconds),
  including all cap-configuration and socket-budget regressions.
- Scratch-only shell harness passed, exit 0: `test-host: OK`, **147.724 seconds**.
- All build/test phases, including the required 120-second quiet waits, completed below 15 minutes. No timeout
  occurred. No failure is claimed as pre-existing; no baseline A/B worktree was needed. The original socket
  mutation and corrected new-fixture defect are documented truthfully in A's record.

The checker's exact exclusions count **two production files relative to A**:

1. `Sources/HailDaemonKit/Listener/ConnectionProbeDaemon.swift`
2. `scripts/host.sh`

`Tests/`, `scripts/tests/` and Markdown docs are excluded; no rename is involved. This branch is intentionally
stacked on A, not a standalone PR against main (the cumulative change would exceed four production files).
The listener and scripts are security-critical. A future PR needs genuine independent exact-head review and
second-key evidence, plus maintainer review of the script diff. No review approval is claimed here.


## Round-2 rebase verification

The candidate is rebased onto corrected A. The cap bridge production code and shell harness remain unchanged
from `0534e7f5e76cf0452e9956408d02bf85649b46d6`. A new configuration-suite test sends real socket requests with a
configured cap of 2/hour: two cards deliver, subsequent queue refusals remain `rate_limited`, the queue retains
only two send timestamps, and attempt 61 is refused `runaway_guard` with a positive retry of at most 60 seconds.
This proves the cap and socket guard remain independent. All peers and lifecycle paths are synthetic/scratch-only.

Current verification passed with the same ordered host-slot/voice-quiet gates and developer directory:

- Build: exit 0, 525.14 s (phase 527.236 s).
- Config/related suites: exit 0, **112 tests in 34 suites**, **20.327 s** (phase 26.103 s).
  All four cap-configuration cases passed; the new cap/guard socket case passed in 0.123 s.
- Scratch host harness: exit 0, `test-host: OK` (phase 140.061 s).
- Strict lint passed on both changed Swift files. Shell syntax and staged whitespace checks passed.
- The two production files and shell harness remain byte-for-byte equal to original B. Only the additional
  configuration-suite socket test and the documentation reconciliation extend the replayed cap change.

Each command below used `python3 /Users/mick/codex-workspaces/hs-1258-scratch/run-split-phase.py <command>`.
A's complete touched-family and mutation results are recorded separately in its linked record; these B runs
focus on configuration and the cap/guard composition.

```sh
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter \
  'SessionUpdateLimitConfigurationTests|TaskProgress|AmbientDuckTimeoutOptionsTests|AmbientSharedAuditTests|AmbientWiringOptionsTests|DiagnosticSessionTests|HostHealthSessionTests|SingleTerminalReplyFallbackTests|VoiceRouteListingTests'
taskpolicy -b bash scripts/tests/test-host.sh
swiftlint lint --strict --quiet \
  Sources/HailDaemonKit/Listener/ConnectionProbeDaemon.swift \
  Tests/HailDaemonKitTests/SessionUpdateLimitConfigurationTests.swift
bash -n scripts/host.sh scripts/tests/test-host.sh
git diff --cached --check
```

All B build/test command phases completed below 15 minutes. The host harness used its fake lifecycle commands
and scratch paths; no live configuration, daemon installation/restart or physical delivery is claimed.
