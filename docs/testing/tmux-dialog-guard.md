# Tmux dialog guard

Part of #1119. This safety slice refuses pane input when the visible screen shows a dialog or cannot be
inspected. It does not complete the issue's notice wording, dialog-specific audit record, holding,
redelivery, or doctor work. No installed build or device delivery is part of this change.

## Cause and behavior

Previously, submission pressed Enter before interpreting paste acceptance. When a dialog kept the paste
from appearing at the cursor, acceptance timed out and the adapter sent one Enter anyway, returning
`unsettled`. That Enter could select the focused dialog option. Pending-input detection and the framed
agent gate cannot detect a dialog inside a running agent.

The new inspection runs after the buffer is filled, immediately before the paste launch, and again
immediately before every Enter launch, including the first Enter after timed-out acceptance and the
conditional retry. Inspection uses `capture-pane -p -t <paneID>` for the visible screen only, without
scrollback or cursor metadata. A thrown capture, nonzero exit, or empty output produces `unknown`,
which never authorizes input. A successfully captured blank screen is still an inspectable screen.

A pre-paste veto deletes the unused buffer and throws `AdapterError.deliveryFailed`. It sends no paste,
Enter, or Escape. A veto after paste throws without flushing or rolling back text. The existing launch
accounting keeps an executed or possibly executed paste and taints that pane against subsequent input.
The admission ticket, whole-submission admission at paste launch, and possible-submission accounting
are unchanged: the safety veto applies even after admission.

The evidence ledger's `submitted` method marks an insert submitted even for a failed outcome. When no
Enter was executed or possibly executed, the adapter therefore reports the failed submit outcome through
the outcome observer and log without calling that ledger method. The insert remains `own_submitted=false`
and `last_submit=none`. A later taint refusal exposes those conservative fields. If an earlier Enter may
have executed, including a veto before retry, the normal failed-submit evidence remains appropriate.

The existing routing default maps this adapter error to a device refusal with `target action was refused`.
The ambient route already publishes its refusal notice and `ambient_delivery_refused`; this change does
not add dialog-specific device wording or claim that blocked input was delivered.

## Detector rules

Each visible line loses Unicode box-drawing characters U+2500–U+257F and surrounding whitespace. Blank
lines do not count toward the bottom region. Matching priority is known title, tool permission, then footer.
Only fixed table titles leave the adapter; arbitrary pane text is never included in a refusal.

- Anywhere on screen, an entire normalized line equal to `Computer Use needs macOS permissions` gives
  `computerUsePermissions`; `Computer Use wants to control these apps` gives `computerUseAppApproval`.
  Adjacent normalized lines joined with one space can equal a title wrapped at a word boundary.
- Within the last 12 nonblank lines, a case-insensitive line beginning `Do you want to ` together with a
  line matching `^(❯\s*)?1\.\s*Yes` gives `toolPermission`, titled `a tool permission dialog`.
- Within that region, a case-insensitive whole line ending with the words `esc to cancel` gives
  `modalFooter`, titled `a dialog`. The implemented pattern is `^(?:.*\s)?esc to cancel$`.
  This includes confirm/select/submit instructions, `Press Esc to cancel`, and retry-edit instructions.
- `esc to interrupt` is clear. Tool questions and footers above the bottom region are clear, including
  quoted transcript. A known title anywhere is the intentional exception. Prose containing a title as
  only part of a longer line does not equal that title.

The two known titles were verified against Claude Code 2.1.319 and may drift. The footer and
"Do you want" rules are the version-independent catch. The future doctor change should flag when a
known title stops matching its fixture; no doctor check ships in this slice.

## Atomicity limit

Inspection and input remain separate tmux commands. A dialog can appear between the capture and paste
or Enter. #1172 tracks composing the predicate into the same tmux command, using fixed result tokens
and fail-closed capture handling. Even that composition cannot synchronize with the target's renderer
or input loop. This slice narrows the window and does not claim atomic protection.

## Synthetic coverage and verification

`TmuxDialogDetectionTests` covers both titles, wrapped/bordered rendering, footer variants, each tool
question variant with a Yes option, case-insensitivity, the 12-nonblank-line boundary, transcript above
that boundary, busy-agent interruption text, and thrown/nonzero/empty captures.

`TmuxDialogSubmissionTests` covers fill–inspection–paste order, bracketed paste, inspection before Enter,
pre-paste veto and buffer deletion, failed capture, a dialog after paste with timed-out acceptance,
post-paste capture failure, unsent ledger evidence, retry veto, and normal confirmation. These use
scripted panes and fake runners, not a live Claude Code dialog or physical-device proof.

Existing-test adjustments retain the original expectations:

- **KEPT:** listing-only fake runners now return an explicit clear visible prompt for the new inspection.
  Cursor observations and history captures retain their previous responses. Inline fixtures in
  `TmuxPrePasteTests` and `TmuxSendEscapingTests`, plus the capability-only runner in
  `TmuxLaunchCapabilityTests`, receive the same explicit response so their cancellation, paste-failure,
  rebind, and unsupported-admission assertions still reach the intended boundary.
- **TIGHTENED:** `deliversLiterallyByArgvToTheSessionIdNotTheName` retains its complete command sequence
  assertion and additionally requires visible-screen inspection immediately before paste and Enter.
- No assertion was weakened. `textThatNeverAppearsGetsOneEnterAnywayAndIsUnsettled` is unchanged.

The initial combined neighboring run reached the 600-second cap and was terminated. It also exposed
listing-only fixtures whose empty capture responses correctly vetoed input; the explicit responses above
preserve those tests' original purposes. Final verification splits the same requested filter into the
four disjoint neighboring groups below.

VM verification used Swift 6.3.3 on the Dev Work VM. The four neighboring groups reported 894 tests in
180 suites in total, with the existing skips detailed below. The fresh Dev Work VM checkout was
synchronized through a bundle containing `origin/main..HEAD`. Each run waited for the shared lane to
be idle and used background task policy, at most four workers, and a 600-second watchdog with
process-group cleanup. SSH had closed stdin and remained attached until completion. Build directories
were removed afterward, and no verification jobs remained running.

| VM wrapper role | Exact filter or command | Result |
| --- | --- | --- |
| Focused build and test, three runs | `HailDaemonKitTests\.(TmuxDialogDetectionTests\|TmuxDialogSubmissionTests)` | PASS each: 12 tests, 29 cases, 2 suites |
| Neighboring core build and test | `HailDaemonKitTests\.(Tmux\|CommandLaunch\|HailHost\|Host\|DeliveryAdmission)` | PASS: 276 reported tests, 52 suites; 10 skipped |
| Ambient A–M build and test | `HailDaemonKitTests\.Ambient[A-M]` | PASS: 111 tests, 21 suites |
| Ambient N–R build and test | `HailDaemonKitTests\.Ambient[N-R]` | PASS: 293 tests, 58 suites |
| Remaining ambient build and test | `HailDaemonKitTests\.Ambient([^A-R]\|$)` | PASS: 214 tests, 49 suites |
| Reply CLI tests | `python3 -m unittest discover -s Tests/ReplyCLITests` | PASS: 124 tests, exit 0 |
| Warnings-as-errors build of package and tests | Workspace-specific verification wrapper | PASS: build 0, wrapper exit 0; module-cache debug warnings |

The warnings-as-errors build completed successfully and its wrapper exited 0. The linker emitted
missing SDK module-cache debug-file warnings, consistent with the previously documented VM lane;
this result is not described as a warning-free linker run.

Ten existing tmux-dependent test functions in five suites were skipped because tmux was unavailable on
the VM: `TmuxDeliveryCommitFakeTUITests`, `TmuxDeliveryCommitShellPromptTests`, `TmuxIntegrationTests`,
`TmuxPasteAgentTests`, and `TmuxPasteEnterTests`. The new suites all executed. No live tmux dialog or
physical-device validation is claimed.

Host strict SwiftLint with the Xcode developer directory and the required non-comment 120-column awk
check both passed for all ten changed Swift files, with no output. `git diff --check` also passed.
Exactly four production files change, using the PR-shape exclusions; no production path is renamed.
