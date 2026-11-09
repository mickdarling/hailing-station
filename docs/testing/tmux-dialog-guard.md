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
conditional retry. Inspection uses `capture-pane -p -t <paneID>` for the visible screen plus cursor metadata
in the same tmux invocation, without scrollback. A thrown capture, nonzero exit, empty output, or missing
or invalid cursor produces `unknown`, which never authorizes input. A successfully captured blank screen
is still an inspectable screen.

A pre-paste veto deletes the unused buffer and throws `AdapterError.deliveryFailed`. It sends no paste,
Enter, or Escape. A veto after paste throws without flushing or rolling back text. The existing launch
accounting keeps an executed or possibly executed paste and taints that pane against subsequent input.
The admission ticket, whole-submission admission at paste launch, and possible-submission accounting
are unchanged: the safety veto applies even after admission.

The pre-paste inspection excludes no payload. Before each Enter, the submission ticket supplies the exact
pasted text, including any framing. The input region runs from the nearest border-stripped row starting
with `>` at or above the captured cursor through the cursor row. Only rows inside that region whose
trimmed text (dropping a leading `> `) is a non-empty substring of the whitespace-normalized payload are
excluded. Rows outside that region always remain eligible, even when identical to payload lines. If a
dialog replaces the input box and no prompt row remains, nothing is excluded.

The evidence ledger's `submitted` method marks an insert submitted even for a failed outcome. When no
Enter was executed or possibly executed, the adapter therefore reports the failed submit outcome through
the outcome observer without calling that ledger method. This pre-Enter branch also covers framed
agent-gate refusal and pre-launch admission errors. No Enter ran in those cases, so no
`tmux_submit outcome=failed` line is logged. The planned dialog-specific audit-kind change must cover
these refusal paths as well. The insert remains `own_submitted=false`
and `last_submit=none`. A later taint refusal exposes those conservative fields. If an earlier Enter may
have executed, including a veto before retry, the normal failed-submit evidence remains appropriate.

The existing routing default maps this adapter error to a device refusal with `target action was refused`.
The ambient route already publishes its refusal notice and `ambient_delivery_refused`; this change does
not add dialog-specific device wording or claim that blocked input was delivered.

## Detector rules

Each visible line loses Unicode box drawing and block elements U+2500–U+259F and surrounding whitespace.
Blank lines do not count toward the bottom region. Matching priority is known title, tool permission, then footer.
Only fixed table titles leave the adapter; arbitrary pane text is never included in a refusal.

- Anywhere on screen, an entire normalized line equal to `Computer Use needs macOS permissions` gives
  `computerUsePermissions`; `Computer Use wants to control these apps` gives `computerUseAppApproval`.
  Leading and trailing non-alphanumeric decoration (icons or a colon) is trimmed before whole-title
  comparison. Adjacent normalized lines joined with one space can equal a title wrapped at a word boundary.
- Within the last 12 nonblank lines, a case-insensitive line beginning `Do you want to ` together with a
  line matching `^(❯\s*)?1\.\s*Yes` gives `toolPermission`, titled `a tool permission dialog`.
- Within that region, a case-insensitive whole line ending with the words `esc to cancel` gives
  `modalFooter`, titled `a dialog`. The implemented pattern is `^(?:.*\s)?esc to cancel$`.
  This includes confirm/select/submit instructions, `Press Esc to cancel`, and retry-edit instructions.
- `esc to interrupt` is clear. Tool questions and footers above the bottom region are clear, including
  quoted transcript. A known title anywhere is the intentional exception. Prose containing a title as
  only part of a longer line does not equal that title.

The two known titles were verified against Claude Code 2.1.319 and may drift. The footer and
"Do you want" rules cover recognised dialog shapes. Dialogs with other option glyphs, footers with hints
after "Esc to cancel", "Would you like to …" prompts, or other agents' approval overlays are not guarded
unless another rule recognises them. A generic numbered-select rule is a possible follow-up. The future
doctor change should flag when a known title stops matching its fixture; no doctor check ships in this slice.

## Atomicity limit

Inspection and input remain separate tmux commands. A dialog can appear between the capture and paste
or Enter. #1172 tracks composing the predicate into the same tmux command, using fixed result tokens
and fail-closed capture handling. Even that composition cannot synchronize with the target's renderer
or input loop. This slice narrows the window and does not claim atomic protection.

## Initial synthetic coverage and verification

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

## Review delta verification

The review follow-up adds position-bounded payload exclusion, cursor capture validation, decorated whole-title
fixtures, and exact refusal-error assertions. The detector checks multiline payloads directly. Submission
fixtures render a single-line payload across multiple input rows because public delivery rejects literal
line breaks. Identical dialog text above the input, a dialog replacing the prompt, and missing cursor
metadata still veto Enter. The pre-paste inspection continues to exclude nothing.

Verification uses Swift 6.3.3 on the Dev Work VM, in a fresh checkout synchronized only by local git bundles.
The verified source/test snapshot is `23346ca1b1753b0ef0e5d166b5f12261d77ea587`; the subsequent verification
record changes documentation only. No GitHub calls or pushes were made. Each run first waited with
`while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done`, then used `taskpolicy -b`, no more than four
workers, and a 600-second cap with a cleanup trap. SSH used closed stdin and remained attached until exit.

The exact focused filter, run three times after rebuilding the corrected fixtures, was:

```text
HailDaemonKitTests\.(TmuxDialogDetectionTests|TmuxDialogSubmissionTests)
```

All three runs exited 0: 16 tests, 40 cases, two suites, no skips. Two preliminary focused runs exposed
fixture setup errors: literal newlines were rejected before submission, then a replacement-screen cursor
did not match its rows. Both were corrected before the three final runs.

The exact neighboring filter ran once, unsplit:

```text
HailDaemonKitTests\.(Tmux|CommandLaunch|LocalDispatch|LocalReply|TaskProgressTmux|TaskProgressPeer|ProviderReply|WebSocketReceivePump)
```

It exited 0 in 135.116 seconds: 291 reported tests in 49 suites, with the ten tmux-dependent skips listed
above. Five deliberate `withKnownIssue` records came from `LocalDispatchPreflightWaitTests`: missing
arrival and late arrival (two), dispatch ending before listing (two), and the suspended-step deadline (one).
These are expected synthetic failure-path assertions, not unexpected failures. Tests used
`swift test --skip-build --no-parallel -j 4` with the isolated build directory and CLT Testing flags.

The `vw-werr.sh` wrapper with the fresh workspace argument exited 0 and reported `werr build=0`.
It built the package and tests with four workers and `-Xswiftc -warnings-as-errors` in 102.95 seconds.
The linker again emitted missing SDK module-cache debug-file warnings; this was a successful build,
not a warning-free linker run.

Host `swiftlint lint --strict --quiet` with the Xcode developer directory and the following check both
produced no output for all ten Swift files changed from the supplied main baseline:

```sh
awk 'length($0)>120 && $0 !~ /^[[:space:]]*\/\//'
```

`git diff --check` passed. The checker exclusions and rename handling still yield exactly the same four
production files. Both VM build directories were deleted, and no verification jobs remained running.
This is synthetic package-test evidence; no live dialog, simulator, installed build, or physical-device
validation is claimed for the delta.
