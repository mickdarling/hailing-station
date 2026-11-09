# Delivery mapping invariants

Part of #1120.

This cleanup preserves reachable delivery outcomes relative to main
`1ec93244e7d8c17050d56cdf9c0efbdceb75561e`. It removes unused mappings and helpers within four
production files. No protocol definitions or wire messages change.

## Removed paths and reachability

- `Listener/HostSession+Routing.swift`: remove the `PolicyRetiredDelivery.pastedUnsent` and
  `HostError.partial(_, _, pastedUnsent: true)` refusal mappings and their shared reason constant.
  `Adapters/Tmux/TmuxAdapter+Paste.swift:263` (`pasteBuffer`) admits the complete submission at
  paste launch; `pressEnter` at line 299 consumes that ticket without reacquiring retired authority.
  Retirement alone cannot leave an admitted paste unsent. `TmuxAdapter.failDelivery` preserves genuine
  failures and can throw `possiblySubmitted`, but never throws `pastedUnsent`
  (`Adapters/Tmux/TmuxAdapter.swift:190`).
- `Listener/HeldRequests.swift`: remove only the `pastedUnsent` known-unsent classification in
  `HeldSendFailure.knownUnsent`. No producer throws that case. Existing classifications for
  policy, binding, pending input and held authority remain intact.
- `Daemon/HailHost.swift`: remove the `pastedUnsent` derivation in `preservingPartial` and rely on
  the existing false default. `deliverLine` still appends the current line on `possiblySubmitted`,
  and partial policy, cancellation and adapter reasons remain unchanged.
- `Listener/HostReplyDelivery.swift`: remove `noteLastInput(to:generation:)`, the private
  `stopSegmentedRepliesForRequest()` helper, and their outdated caller comments. A reference audit
  across Sources, Tests and Apps found no callers of the former and only that method calling the
  latter. The actual commit paths in `HostSession+Routing` call `recordLastInput` under the commit
  gates and `didNoteLastInput` afterward (`Listener/HostSession+Routing.swift:299` and line 304).
  Attribution, segmented-reply stopping and interaction events retain that ordering.

All production paths above are under `Sources/HailDaemonKit`. The exact exclusions and rename
handling in `scripts/pr-shape.py` count four production files; this document and the new test file
are excluded. No GitHub-dependent checker is executed.

## Compatibility and carried items

`HostError.partial` retains its `pastedUnsent: Bool = false` parameter. The complete reference audit
found `Sources/haild/main.swift:401` destructuring all three associated values. Removing the parameter
would require a fifth production file. Its declaration comment now states the current invariant;
all reachable production constructors use the false default. CLI formatting remains untouched.

`Adapters/Tmux/TmuxAdapter.swift` remains unchanged: `PolicyRetiredDelivery.pastedUnsent` is unused
but still defined, and its enum comment remains a carried item. `Sanitize/PastedContent.swift`'s
stale `TmuxAdapter.pasteToAgent` comment is also carried forward without modification.

## Unchanged-behavior evidence

No existing test is edited or deleted. No existing test constructs or asserts either removed mapping
or calls either removed helper.

The new `HostSessionRetirementOutcomeTests` adds:

- `admittedRetirementAndFailureOutcomesStayStable`: eight combinations of retirement after paste
  or Enter admission, successful or failed Enter, and one or two input lines. An admitted single
  line completes; later unadmitted lines and genuine failures keep the generic refusal. Failed
  Enter retains sticky pending input even after the pane is cleared, including the same phone
  error frame and no additional paste or Enter. Successful completion permits fresh input.
- `genuineFailureAndPartialFailureKeepTheSameRefusal`: first-line and second-line adapter failures
  keep the same session refusal and the exact successful delivery prefix.

The same new test file is run against unchanged main production sources before the cleanup and
against the cleanup sources afterward. Existing `TmuxPolicyRetirementTests` retain their exact
`possiblySubmitted` delivered-line accounting, policy-partial reasons, taint and phone-refusal
expectations. `FinalDeliveryCommitTests.lastInputObserversRunAfterCommitGatesRelease` retains the
observer-order proof. All existing tests and expectations remain unchanged.

## Verification

Verification uses the Dev Work VM, Swift 6.3.3, with a fresh baseline clone and a local
`origin/main..HEAD` bundle. Runs wait for the shared lane to become idle, use at most four workers,
close SSH stdin, and finish sequentially. Shared verification helpers remain unchanged.

The source/test bundle snapshot is `352bb069612ad87d1cbee61bdd7a067d465b73f4`.
The final verification-record commit changes only this document.

| Check | Result |
| --- | --- |
| New outcome tests on unchanged main production sources | 2 tests in 1 suite, 10 parameterized cases; build=0, test=0; 0.027 seconds |
| Delivery, host, held, tmux, reply, task, local and WebSocket regressions | 520 tests in 105 suites; build=0, test=0; 164.327 seconds; 10 existing known issues |
| Ambient regressions | 618 tests in 128 suites; build=0, test=0; 527.607 seconds; no issues |
| Reply CLI | `python3 -m unittest discover -s Tests/ReplyCLITests`; 124 tests; 216.577 seconds; OK, exit 0 |
| Warnings as errors | `werr build=0`, exit 0; four workers |

The first regression filter is
`HailDaemonKitTests\.(HostSession|Held|HailHost|Host|Tmux|FinalDelivery|DeliveryAdmission|TaskProgress|LocalDispatch|Reply|WebSocket)`.
The remaining requested Swift coverage uses `HailDaemonKitTests\.Ambient` separately. Together they
cover the complete requested filter. The ten known issues are five each in
`LocalDispatchPreflightWaitTests` and `ReplyRecipientHandoffWaitTests`; no unexpected issues occurred
in either group. The requested Swift filters passed 1,138 tests in 233 suites in total.

Strict host lint passed with zero violations on all four production files and
`Tests/HailDaemonKitTests/HostSessionRetirementOutcomeTests.swift`, using
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>`
once per file. The non-comment over-120-character check printed nothing for every changed Swift
file. `git diff --check` passed. `deliverLine`, including its `possiblySubmitted` handling, and the
active `recordLastInput`/`didNoteLastInput` code are byte-for-byte unchanged from main.

The warnings-as-errors build uses a separate, external Swift wrapper to cap the existing helper at
four workers. It emitted the existing missing module-cache debug-info warnings; the compiler build
completed successfully. All requested runs finished, and no job from this session remains running.
The final source and tests match the verified bundle snapshot; only this record changed afterward.

This is synthetic Swift package evidence and host strict lint only. No host build or test, simulator, physical-device proof, live captured-output
round trip, installation, upload or push is part of this cleanup.
