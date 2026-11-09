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
conditional retry. Inspection uses a single `capture-pane -p -t <paneID>` for the visible screen,
without scrollback or cursor metadata. A thrown capture, nonzero exit, or empty output produces `unknown`,
which never authorizes input. A successfully captured blank screen is still an inspectable screen.

A pre-paste veto deletes the unused buffer and throws `AdapterError.deliveryFailed`. It sends no paste,
Enter, or Escape. A veto after paste throws without flushing or rolling back text. The existing launch
accounting keeps an executed or possibly executed paste and taints that pane against subsequent input.
The admission ticket, whole-submission admission at paste launch, and possible-submission accounting
are unchanged: the safety veto applies even after admission.

All visible rows remain eligible at every inspection, including the pasted payload. PR 1 stays fail-closed;
position-based own-input exclusion is deferred to #1179.

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
- Within the last 12 nonblank lines, a case-insensitive line beginning `Do you want to ` (optionally after `❯`) together with a
  line matching `^(❯\s*)?1\.\s*Yes` gives `toolPermission`, titled `a tool permission dialog`.
- Within that region, a case-insensitive whole line ending with the words `esc to cancel` gives
  `modalFooter`, titled `a dialog`. The implemented pattern is `^(?:.*\s)?esc to cancel$`.
  This includes confirm/select/submit instructions, `Press Esc to cancel`, and retry-edit instructions.
- `esc to interrupt` is clear. Tool questions and footers above the bottom region are clear, including
  quoted transcript. A known title anywhere is the intentional exception. Prose containing a title as
  only part of a longer line does not equal that title.

The two known titles were verified against Claude Code 2.1.319 and may drift. The footer and
"Do you want" rules cover recognised dialog shapes only; a dialog outside those shapes is not recognised
by this slice. Broader recognition is follow-up work. The future
doctor change should flag when a known title stops matching its fixture; no doctor check ships in this slice.

## Availability cost (accepted)

A pasted line ending with `esc to cancel` can match the modal footer rule. Pasted `Do you want to …`
plus a separate `1. Yes` row can match the tool permission rule, including a single-line payload wrapped
across screen rows. Both shapes veto Enter even when they are haild's own input. This fail-closed cost is
accepted for PR 1: after the paste, the pane is tainted until haild restarts. #1179 tracks own-input exclusion
and recovery.

Claude Code 2.1.319 renders its input prompt as `❯` between full-width `─` rule rows, not `>`.
An old `> old user prompt` transcript row above a replacement dialog must never hide that dialog.
The regression fixtures use the 2.1.319 input box shape, and replacement dialogs remain eligible even
when their text also appears in the submitted payload.

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

## Prior review delta verification (superseded behavior)

The prior review follow-up added position-bounded payload exclusion, cursor capture validation, decorated whole-title
fixtures, and exact refusal-error assertions. Those detector fixtures checked multiline payloads directly.
Submission fixtures rendered a single-line payload across multiple input rows because public delivery
rejects literal line breaks. Identical dialog text above the input, a dialog replacing the prompt, and
missing cursor metadata vetoed Enter. The prior pre-paste inspection excluded nothing.

That verification used Swift 6.3.3 on the Dev Work VM, in a fresh checkout synchronized only by local git bundles.
The verified source/test snapshot is `23346ca1b1753b0ef0e5d166b5f12261d77ea587`; the subsequent verification
record changes documentation only. No GitHub calls or pushes were made. Each run first waited for the
shared VM lane to be idle, then used `taskpolicy -b`, no more than four
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

The VM warnings-as-errors build of the package and tests exited 0 and reported `werr build=0`
in 102.95 seconds.
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

## Fail-closed delta verification

This delta removes position-based payload exclusion and cursor capture validation. It retains decorated
whole-title matching, block-element stripping, exact refusal-error assertions, the #1172 atomicity note,
and the recognised-dialog-shapes coverage limits. Tests retain the real dialog above the input and the
replacement dialog vetoes, and add the old-transcript-prompt counterexample and both accepted availability
costs, including sticky taint after refusal. Own-input exclusion and recovery move to #1179.

Verification used Swift 6.3.3 on the Dev Work VM, with a fresh checkout synchronized by a local git
bundle. The verified source/test snapshot is `cdcbf66c88470e15e95395e647fd0e02b1f073d6`; the subsequent
verification record changes documentation only. No GitHub calls or pushes were made.

Before each run, the driver waited for the shared VM lane to be idle. Every run used `taskpolicy -b`, at most four
workers, and a 600-second process-group watchdog with signal handling and kill cleanup. SSH stdin was
closed with `< /dev/null`, and each connection stayed attached until the run exited.

The commands below used an isolated build directory (`B`) and the CLT Testing framework, macro-plugin,
and linker search flags (`F`):

```sh
swift build --build-tests -j 4 --build-path "$B" "${F[@]}"
swift test --skip-build --no-parallel -j 4 --build-path "$B" "${F[@]}" --filter "$FILTER"
```

The initial build completed in 143.96 seconds. These were the exact filters:

```text
HailDaemonKitTests\.(TmuxDialogDetectionTests|TmuxDialogSubmissionTests)
HailDaemonKitTests\.(Tmux|CommandLaunch|LocalDispatch|LocalReply|TaskProgressTmux|TaskProgressPeer|ProviderReply|WebSocketReceivePump)
```

The dialog filter ran three times; each exited 0 with 16 tests, 37 cases, two suites, and no skips.
Reported test durations were 0.075, 0.025, and 0.026 seconds. The neighboring filter ran once, unsplit,
and exited 0: 291 reported tests in 49 suites, 115.251 seconds. Its ten existing tmux-dependent test
skips are the same five suites named above. The five deliberate known-issue records are from
`LocalDispatchPreflightWaitTests`: missing/late arrival (two), dispatch ending before listing (two),
and the suspended-step deadline (one). There were no unexpected test failures.

The VM warnings-as-errors build of the package and tests exited 0 and reported `werr build=0`
in 139.45 seconds. The log contained no
compiler errors. The linker emitted the known missing SDK module-cache debug-file warnings; this is
a successful warnings-as-errors build, not a warning-free linker run.

Host `swiftlint lint --strict --quiet` with
the Xcode developer directory and the required check below both exited 0
and printed nothing for all ten Swift files changed by PR 1:

```sh
awk 'length($0)>120 && $0 !~ /^[[:space:]]*\/\//'
```

`git diff --check` passed. The PR still changes exactly the same four production files under the
PR-shape checker's exclusions and rename handling. Against the round-1 head `54fc6a0b`, only
`TmuxAdapter+Dialog.swift` differs among them.
Both isolated VM build directories were deleted, and no verification jobs remained running.
This is synthetic package verification, with no live dialog, simulator, installed build, physical-device,
or captured-output round-trip proof.

## Structured dialog evidence

The dialog detector now throws an internal cause-only veto. The delivery failure boundary attaches
`DialogBlock` effects from the existing paste and Enter accounting: `none`, `pasteMayHaveExecuted`,
or `enterMayHaveExecuted`. Known causes carry a bounded public `DialogKind`; failed inspection uses
`uninspectable`. Taint, authority retirement, possible-submission precedence, ledger updates and
submit outcomes retain their existing behavior.

`DialogKind` provides exhaustive fixed `title` and `spokenName` properties. Titles retain the existing
CLI text byte for byte. Spoken noun phrases support the planned PR 2b notices; this slice does not
add those notices. Detector matching and fail-closed behavior are unchanged. Tests iterate every kind
for non-empty names and pin all four titles and all four spoken names.

`AdapterError.blockedByDialog` preserves the previous interpolated `deliveryFailed("…")` text.
A later-line `HostError.partial` retains a `.dialog` reason after policy and cancellation precedence;
a first-line refusal retains the adapter error. Existing String reasons construct `.text` through
an overload, preserving equality assertions and CLI interpolation without changing the CLI source.
`HostDialogPartialTests` pins block messages, adapter error text, reason descriptions and partial
interpolation byte for byte. Submission tests assert causes and effects while retaining their
buffer deletion, key, taint and ledger checks. Routing and device wording remain follow-up work.

### Structured-evidence verification

The source and Swift-test snapshot is `cee96a649781a7fc68ebb60232a8d54c46a41a3a`.
Verification used Swift 6.3.3 on the Dev Work VM in a fresh checkout synchronized by local bundles.
Each run waited for the shared lane, used background task policy and at most four workers, and had
a 600-second cap with signal handling and process-group cleanup. SSH stdin was closed and each
connection remained attached until completion.

The focused filter ran three times after the corrected package/test build:

```text
HailDaemonKitTests\.(TmuxDialogDetectionTests|TmuxDialogSubmissionTests|HostDialogPartialTests)
```

Each run passed: 21 tests in three suites, no skips. Durations were 0.030, 0.029 and 0.028 seconds.
Preliminary verification caught a parameterized-test declaration error and a nested non-dialog
refusal description mismatch; both were corrected before these final passes.

The requested neighboring filter ran once, unsplit:

```text
HailDaemonKitTests\.(Tmux|CommandLaunch|HailHost|Host|DeliveryMappingCleanup|LocalDispatch|DeliveryAdmission|Reply)
```

It passed: 400 reported tests in 76 suites, 167.140 seconds, with ten expected known-issue records.
Five came from `LocalDispatchPreflightWaitTests` and five from `ReplyRecipientHandoffWaitTests`;
these deliberately exercise deadline and cancellation failure paths. The same ten tmux-dependent
functions in the five suites listed above were skipped because tmux was unavailable. All new tests ran.

At that snapshot, `python3 -m unittest discover -s Tests/ReplyCLITests` ran 124 tests in 231.936
seconds and exited 1 with one setup error. The `DeliveryMappingCleanupCLITests` fixture then extracted
only the `case partial(...)` line into an isolated Swift enum, without `HostPartialReason` or the
String convenience overload, so its probe failed to compile.

With maintainer approval, `1ce33c633b916a90d39bf6139a7b4d245c0f9bbc` changed only that fixture's source
extraction. It now splices `HostPartialReason`, the String overload, `AdapterError`, `DialogBlock` and
`PendingInputReason` from the production sources; no definition is hand-copied. Its assertions are
unchanged: exact stderr text including pluralization and the trailing newline, empty stdout, and exit 6,
for all three reasons with zero, one and two delivered lines. On the Dev Work VM, under the same lane
conditions, the focused fixture passed (1 test), the full Reply CLI suite passed (125 tests, 231.110
seconds), and the warnings-as-errors build exited 0.

`c880200b6e636ac4c442b6feb67d2835dca1788b` adds only a setup assertion that fails if the extraction no
longer finds the partial reason, its overload or the adapter declarations. At that head, on the host
with Swift 6.2.4, a package-and-test build (`swift build --build-tests`, four jobs, background task
policy) exited 0, and the `test_delivery_mapping_cleanup.py` fixture alone passed (1 test, 4.544
seconds). The full Reply CLI suite was not rerun on the host.

The repository's policy CLI checks passed with exit 0 and no output after a successful
`swift build --product haild -j 4` with the lane's CLT Testing flags.

The warnings-as-errors package/test build completed in 135.06 seconds. Both the build and its enclosing
verification exited 0. The linker emitted the lane's known missing module-cache debug-file warnings;
this is a successful warnings-as-errors build, not a warning-free linker run.

Host strict SwiftLint with the Xcode developer directory and the non-comment 120-column awk check
both exited 0 and printed nothing for all six changed Swift files. The checker exclusions and rename
handling yield exactly four production files, with no renames. The CLI source is unchanged.
Both VM build directories were deleted and no verification jobs remained running.
This is synthetic package and CLI evidence, with no live dialog, simulator, installed-build,
physical-device or captured-output round-trip validation.

### Typed-kind verification

The source/test snapshot is `ef593f4278b96574ced511dfab5b295575c39733`. The subsequent verification
record changes documentation only. Verification used Swift 6.3.3 on the Dev Work VM in a fresh
checkout synchronized by local bundles. No GitHub calls or pushes were made.

Each phase waited for the shared lane and used background task policy. Swift builds used at most
four build jobs with a single compiler frontend job each, plus the lane's Command Line Tools Testing
framework, plugin and linker flags. Each phase had a 600-second cap with signal handling and
process-group cleanup. SSH stdin was closed and each connection remained attached until
completion.

The package/test build passed (236.50 seconds); after the final source bundle synchronization, the
incremental package/test build also passed (5.64 seconds). Tests ran without rebuilding and without
parallel test execution. The focused filter ran three times:

```text
HailDaemonKitTests\.(TmuxDialogDetectionTests|TmuxDialogSubmissionTests|HostDialogPartialTests)
```

Each run exited 0: 22 tests in three suites, no skips, in 0.034, 0.034 and 0.027 seconds.
The requested neighboring filter ran once, unsplit:

```text
HailDaemonKitTests\.(Tmux|CommandLaunch|HailHost|Host|DeliveryMappingCleanup|LocalDispatch|DeliveryAdmission|Reply)
```

It exited 0: 401 reported tests in 76 suites, 164.814 seconds, with ten expected known-issue records.
Five came from `LocalDispatchPreflightWaitTests` and five from `ReplyRecipientHandoffWaitTests`.
The same ten tmux-dependent functions in the five suites listed above were skipped because tmux was
unavailable. All dialog and host partial tests executed.

`python3 -m unittest discover -s Tests/ReplyCLITests` passed all 125 tests in 234.826 seconds, exit 0.
The repository policy CLI test passed with exit 0 and no test output after a successful
`swift build --product haild` (0.35 seconds). The isolated package/test warnings-as-errors build
passed in 218.21 seconds: build exit 0 and enclosing verification exit 0. The linker emitted the
known missing module-cache debug-file warnings; this is not a warning-free linker claim.

All four title literals match the supplied pre-delta source byte for byte. The CLI source and host
formatting are unchanged. `HostDialogPartialTests` retains every text pin, with only typed case inputs
substituted. The Python CLI test methods are AST-identical; only dependency extraction adds
`DialogKind`, retaining all non-empty extraction assertions. No CLI expected-output assertion changed.

On the host, strict SwiftLint with the Xcode developer directory and the non-comment 120-column
check both exited 0 and printed nothing for all seven Swift files this PR changes against `main`,
including `TmuxDialogDetectionTests.swift`, at `2bf8cea0bc89777f16aa1ed9c2fe442801fc4302`. No builds
ran on the host for this delta. `git diff --check` passed. The PR-shape exclusions and rename
handling still count exactly the same four production files, with no renames; this delta modifies
two of them.
Both VM build directories were deleted, and no verification jobs remained running.
This is synthetic package and CLI evidence, with no live dialog, simulator, installed-build,
physical-device or captured-output round-trip validation.

## Per-request dialog notices

This slice carries the typed dialog cause, possible paste or Enter effects, and earlier delivered-line
count through routing and local dispatch. Dialog refusals keep ambient listening active on both the
configured target and a voice-routed target. Other own-target refusal behavior is unchanged. Reply
ownership and the last-input device are never committed for a dialog refusal.

The device names the target using its configured spoken route name, with the listed target name as
fallback. Known causes say `A <title> dialog is open on <target>.`; failed inspection says
`Couldn't check <target> for a dialog.` The next sentence distinguishes untouched requests, possible
input-box text, possible submission, and singular or plural earlier delivered lines. Existing phone
refusal codes, request UUIDs, heard-turn correlation, notice order and acknowledgement snapshots are
preserved. No notice prefix is added.

The current wording table uses the first sentence above, followed by the exact text below.
`E` is the number of earlier delivered lines. Each cause uses every row; `L` is
`1 earlier line` for E=1 and `2 earlier lines` for E=2 (and the corresponding plural for larger counts).

| Effects | E | Text after the first sentence | Not-sent clip eligible |
| --- | --- | --- | --- |
| none | 0 | `Nothing was sent.` | Yes |
| paste | 0 | `Your words may be in the input box, but nothing was submitted.` | No |
| enter | 0 | `Your words may have gone through; check the Mac before resending.` | No |
| none | >0 | `<L> went through; the rest were not sent.` | No |
| paste | >0 | `<L> went through. The next line may be in the input box; the rest were not submitted.` | No |
| enter | >0 | `<L> went through, and the next line may have too; check the Mac before resending.` | No |

The `confirm-not-sent` clip is eligible only when effects are `none` and no earlier line was delivered.
Possible paste, possible Enter, or any earlier delivered line suppresses it. Existing privacy and
connection-teardown checks still apply to eligible clips. The existing delivery-refusal audit remains.
Tests use synthetic typed errors, adapters, child events and loopback device frames; they do not prove
a live dialog, device hearing, an installed build, or a captured-output round trip.

Verification used Swift 6.3.3 on the Dev Work VM, in a fresh checkout synchronized by local bundles.
The prior source/test snapshot is `b3ddae98f61b4a1358128f306470e6fbb9a12009`. Before every run, verification
waited for the shared lane; each attached SSH run had closed stdin, background task policy, at most
four workers, a 600-second cap, signal handling and process-group cleanup.

The focused filter covered `HostSessionDialogNoticeTests`, `WebSocketListenerDialogNoticeTests`,
`AmbientWiringDialogNoticeTests`, `HostDialogPartialTests` and `RightyoInputConsumerTests` three times.
All passed: 117 reported tests in five suites, in 12.237, 11.853 and 11.145 seconds, with no skips.
This includes all wording rows, clip eligibility, real split-delivery counts, stable CLI tokens,
request UUIDs, own-target heard turns and acknowledgement snapshots. Routed refusals keep their
existing nil heard turn and absent acknowledgement; the next own-target utterance still succeeds.

The broader ambient, routing, host, reply, listener, local-dispatch and tmux filter passed once,
unsplit: 723 reported tests in 128 suites, 297.224 seconds. Ten deliberate known-issue records came
from the existing preflight and recipient-handoff deadline/cancellation tests. Ten existing
functions in five tmux-dependent suites were skipped because tmux was unavailable; all new tests ran.
The full Reply CLI suite passed: 126 tests, 228.417 seconds. Its existing text-reason assertions are
unchanged; the additional dialog case pins the production partial-error branch. Policy CLI checks
exited 0 with no output after a successful haild build.

The warnings-as-errors package/test build completed in 138.48 seconds. The build and its enclosing
verification both exited 0. The linker emitted the VM's known missing module-cache debug-file
warnings; this is a successful warnings-as-errors build, not a warning-free linker run.
Host strict SwiftLint with the Xcode developer directory and the non-comment 120-column check both
exited 0 and printed nothing for all ten changed Swift files. No host builds were run. The production
file count is four relative to the structured-evidence base, using the checker exclusions, with no
renames. Existing test assertions were retained. Preliminary verification caught and corrected an
async fallback expression and new-fixture setup/expectation errors before the final passes above.
Both isolated VM build directories were deleted and no verification jobs remained running.
All evidence remains synthetic; no simulator, live dialog, installed build, device hearing or
captured-output round trip is claimed.
