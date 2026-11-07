# #327 PR 1 — ambient router stream targets

Host-local groundwork only. The gate still admits its startup-pinned target. This slice adds no follow-selection flag or device behavior.

## Scope and traceability

- STARTED carries the gate's pinned target.
- The router retains each stream's target and binding on Active and across reloads. The configured target retains the exact startup binding; other targets resolve through the existing listed/alive/policy-pinned voice-route check. A nil binding refuses before child construction or making room.
- Child consumer, dispatcher, acknowledgements, heard/overheard messages, stop/mute confirmations and refusal notices use the stream target. Connection-level confirmations retain the last gate-admitted target through stream end and forget it on teardown. Idle status reports the configured target.
- Admission/policy generation (#1028), selection generation (#636), voice routes, privacy/duck/meeting/media decisions, take-over (#366), and reply-reference authorization (#230) retain their existing checks.
- `AmbientRouterStreamTargetTests` adds four consumer/dispatcher/reload combinations, five missing-binding cases (unlisted, unknown policy, offline, unbound, rebound), and configured startup-binding preservation. Existing event matches/constructions carry the new value explicitly.

## Changed files

Production count: **3**, using the exclusions in `scripts/pr-shape.py`; no renames.

- `Sources/HailDaemonKit/Listener/AmbientAudioGate.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener+PrivacyPark.swift`
- `Sources/HailDaemonKit/Listener/WebSocketListener.swift`
- `Tests/HailDaemonKitTests/AmbientAudioGateTests.swift`
- `Tests/HailDaemonKitTests/AmbientOwnerReplyRoutingTests.swift`
- `Tests/HailDaemonKitTests/AmbientPolicyAdmissionRaceTests.swift`
- `Tests/HailDaemonKitTests/AmbientPolicyStartTests.swift`
- `Tests/HailDaemonKitTests/AmbientStreamSelectionTests.swift`
- `Tests/HailDaemonKitTests/AmbientTakeOverTests.swift`
- `Tests/HailDaemonKitTests/AmbientTargetGuardBudgetTests.swift`
- `Tests/HailDaemonKitTests/AmbientVoiceMeetingTeardownTests.swift`
- `Tests/HailDaemonKitTests/AmbientWiringForcedTakeOverTests.swift`
- `Tests/HailDaemonKitTests/TaskProgressFinalOwnerTests.swift`
- `Tests/HailDaemonKitTests/TaskProgressLivenessTests.swift`
- `Tests/HailDaemonKitTests/TaskProgressOwnerControlTestSupport.swift`
- `Tests/HailDaemonKitTests/AmbientRouterStreamTargetTests.swift`

This verification record is also changed and is excluded as documentation.

## Verification

All Swift build/test invocations use `taskpolicy -b`, one at a time. No full suite runs.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swift test --no-parallel --filter AmbientRouterStreamTargetTests
```

Interrupted with Ctrl-C (exit 130) before any tests ran, to replace default build concurrency with two jobs. Its compiler children exited before the retry.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swift test --jobs 2 --no-parallel --filter AmbientRouterStreamTargetTests
```

Stopped with Ctrl-C after ten minutes without new build output (exit 1). The last completed step was `Emitting module HailDaemonKit`; no compiler diagnostics or test results appeared. The test executable never finished building, and **no test cases ran**. The process and its compiler children exited before this work was committed. No further retries or regression suites were started against the same host-load blocker.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict $(git diff --name-only -- '*.swift') Tests/HailDaemonKitTests/AmbientRouterStreamTargetTests.swift
```

Passed: 0 violations across all 16 changed Swift files. The final helper-only rename also passed a focused strict lint invocation. `git diff --check` passed.

## Deferred / not proven

Compilation and runtime verification remain unverified. The remaining focused regressions for policy/selection generations, reload, take-over, privacy/modes, acknowledgements, heard/overheard messages, stop/mute confirmations, reply references and task progress were not run because the test executable never finished building. Re-run the new router suite and those filtered suites under `taskpolicy -b` when the host can complete the build. The full unfiltered suite was deliberately not run under the task's explicit restriction. No simulator/app build, physical-device capture or playback, live captured-output round trip, installation, upload, daemon restart, push or PR creation was performed. Follow-selection gate/session/flag work belongs to PR 2; deployment and physical checks belong to the later authorized delivery slice.
