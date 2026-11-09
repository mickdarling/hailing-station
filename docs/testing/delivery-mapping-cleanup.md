# Dead-mapping cleanup

Part of #1120.

This dead-mapping cleanup removes mappings that can no longer run. It was first verified against main
`d13765e79ffc52dcbff55af091b7c2552c28a7d5` and then rebased unchanged onto later main, as described under
Rebased verification. Delivery errors, reasons, exit codes and partial accounting are unchanged.

## Removed mappings and comments

- `Sources/HailDaemonKit/Adapters/Tmux/TmuxAdapter.swift`: remove the unused
  `PolicyRetiredDelivery.pastedUnsent` case. A pre-change `git grep` across Sources and Tests found
  no construction of it. The enum comment now describes the remaining `possiblySubmitted` case:
  an Enter may already have reached tmux when authority retires.
- `Sources/HailDaemonKit/Daemon/HailHost.swift`: remove the always-false `pastedUnsent` associated
  value and its compatibility comment from `HostError.partial`. The same reference audit found
  no call passing that argument. `deliverLine` and `preservingPartial` remain unchanged, including
  counting the current line for `possiblySubmitted` and preserving each partial reason.
- `Sources/haild/main.swift`: destructure the two remaining partial values. The error formatting
  and exit code 6 remain unchanged.
- `Sources/HailDaemonKit/Sanitize/PastedContent.swift`: replace the stale `pasteToAgent` reference
  with `TmuxAdapter.pasteBuffer`, the current function that launches the paste with the agent check
  in the same tmux command. This file changes only a comment.

These are exactly four production files under the exclusions and rename handling in
`scripts/pr-shape.py`. The new tests and this document are excluded. No GitHub-dependent checker
was executed. After the cleanup, `git grep` finds no `pastedUnsent` references in Sources or Tests.

## Parity coverage

`DeliveryMappingCleanupTests` adds two tests with seven parameterized cases:

- Partial equality retains the delivered lines, their order and the reason for
  `target_policy_changed`, `delivery cancelled` and `adapter delivery failed`. Changing the line
  prefix, order, reason or error case still makes the values unequal.
- The existing `TmuxAuthorityRig` and command gate exercise `possiblySubmitted` through the host
  path, with successful or failed Enter replies and one or two counted lines. Each partial retains
  the current line, the same policy reason, the exact paste prefix and the Enter count. No sleep
  is added.

`DeliveryMappingCleanupCLITests` compiles the production partial declaration, formatting helpers
and CLI switch branch in an isolated harness. Nine cases cover all three reasons with zero, one
or two delivered lines, checking exact stderr, empty stdout and exit code 6. This is synthetic
branch coverage; the existing Reply CLI suite exercises the built executable.

Both new test files pass against unchanged main production sources before the cleanup. Existing
tests are KEPT: no existing test or suite annotation is edited, deleted or weakened, including
`TmuxPolicyRetirementTests`, `TmuxAuthorityBoundaryTests` and `TmuxDeliveryAuthorityTests`.

## Verification

Verification uses the Dev Work VM, Swift 6.3.3, with a fresh clone at the main base and local
`origin/main..HEAD` bundles. Runs wait for the shared lane to become idle, close SSH stdin,
use at most four workers and finish sequentially.

The unchanged-main baseline passed two Swift tests in one suite (seven parameterized cases),
with build and test exit 0, and one CLI parity test (nine cases), exit 0.

The first verification ran on the cleanup source/test snapshot `2bf619280087fefab0df81c5dd3b925cd5360c7f`,
based on `d13765e7`. The verification-record commit changes only this document.

| Check | Result |
| --- | --- |
| Requested tmux, host, provider, confirmation, paste and delivery-admission filter | 450 tests in 74 suites; build=0, test=0; 113.122 seconds; 10 integration tests initially skipped by availability checks |
| Initially skipped real-tmux integration suites, rerun unchanged | 10 tests in 5 suites; exit 0; 46.478 seconds; no skips or issues |
| New Swift parity suite after cleanup | 2 tests in 1 suite, 7 parameterized cases; build=0, test=0; 0.011 seconds |
| `python3 -m unittest discover -s Tests/ReplyCLITests` | 125 tests; 215.926 seconds; OK, exit 0 |
| Warnings as errors | `werr build=0`, exit 0; four workers |

The regression filter is
`HailDaemonKitTests\.(Tmux|HailHost|Host|Provider|Confirmation|PolicyConfirmation|Paste|DeliveryAdmission)`.
The new Swift parity filter is `HailDaemonKitTests\.DeliveryMappingCleanupTests`. The regression log
confirms all three named tmux suites and `HostSessionRetirementOutcomeTests` passed unchanged.

The initial regression environment lacked tmux. A local copy of tmux 3.5a and its runtime libraries
was supplied outside the repository without network access. The same compiled tests then ran
unchanged against scratch tmux servers: `TmuxDeliveryCommitFakeTUITests`,
`TmuxDeliveryCommitShellPromptTests`, `TmuxIntegrationTests`, `TmuxPasteAgentTests` and
`TmuxPasteEnterTests`. This completed all ten tests initially skipped by their existing availability
checks. The warnings-as-errors command passed again afterward.

Host strict SwiftLint passed with zero violations on all four production files and
`Tests/HailDaemonKitTests/DeliveryMappingCleanupTests.swift`, using
strict SwiftLint with the Xcode developer directory, under background priority,
once per file. The non-comment over-120-character check printed nothing for every changed Swift
file. `git diff --check` passed.

The warnings-as-errors build used an external Swift wrapper to cap compilation at four workers.
Its first link attempt exhausted VM disk space. After removing this session's completed ordinary
build artifacts, the same command passed without source changes. The linker emitted missing
module-cache debug-info warnings; the compiler build completed successfully. All requested runs
finished, and no job from this session remains running.

## Rebased verification

The same patch, with an unchanged stable patch-id and no overlap with the intervening main changes,
was rebased onto `7dc953c4d2aff222a5018496f51bf2704c1df560` and verified again on a fresh Dev Work VM
clone (Swift 6.3.3):

| Check | Result |
| --- | --- |
| The regression filter above, extended with `DeliveryMappingCleanup` | 452 tests in 75 suites; build=0, test=0; 10 tmux availability skips |
| `python3 -m unittest discover -s Tests/ReplyCLITests` | 125 tests; exit 0 |
| Warnings as errors | build=0, exit 0 |

A host build-only check of the package and tests, with Xcode Swift 6.2.4 under `taskpolicy -b` and
`-j 4`, passed at that rebased head. The pull request records the final head and its CI.

This records Swift package tests and CLI verification on the Dev Work VM, Swift 6.3.3, host lint
and a host build-only check. No host test run, simulator run, physical-device proof, live
captured-output round trip, installation or upload is claimed.
