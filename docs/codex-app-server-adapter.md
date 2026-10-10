# Disabled owned Codex adapter

Part of #153 and #134. This macOS-only internal adapter is experimental library
code for a newly created, explicitly host-owned stdio child and ephemeral thread.
There is no default executable, daemon registration, listener integration, session
discovery, existing-thread resume/fork, reconnect, cloud/remote attachment, output
publication, speech/mobile delivery or TestFlight change. Source version is
`0.1.25`, build `1`; clean exact-head full CI remains required before merge.

## Supported contract and compatibility

The [official App Server documentation](https://learn.chatgpt.com/docs/app-server)
was searched and fetched before public-schema inspection. It establishes the
initialize/initialized handshake, creation of new threads, turn requests and
separate streamed lifecycle events. This adapter deliberately implements a much
narrower profile than the full documented interface.

The supported public-schema profile is CLI `0.159.0`. Trusted host composition
must explicitly supply an absolute executable, argv/environment and an exact
`verifiedVersion` declaration before construction can launch anything. Missing
or incompatible declarations are refused. Despite its name, `verifiedVersion`
is a trusted host attestation, not an independent installed-binary check. The
initialize response has no dedicated version field in this pinned schema;
`userAgent` and `codexHome` are not mined for a version, retained as diagnostics,
or treated as authentication/configuration evidence. A future real launcher must
supply genuine binary/version and configuration-isolation evidence.

Initialization uses the stable API (`experimentalApi: false`), then sends the
typed no-ID initialized notice before creating an ephemeral thread. It requests
`approvalPolicy: never`, `approvalsReviewer: user` and read-only sandboxing, and
refuses an effective response that does not match never/user/readOnly with
network access absent or false. Turn input retains never/readOnly/no-network
restrictions. These checks are not proof that inherited hooks, instruction files,
credentials or configuration are isolated. No server approval/tool request is
answered; the underlying transport rejects server requests.

## Launcher evidence (#399)

`CodexLauncher.verify` replaces the attestation for real composition. The
adapter's `withOwnedAdapter(launch:environment:)` launches only from that
evidence. The `verifiedVersion` seam stays internal, for synthetic tests.

- Takes a configured absolute path, with no PATH lookup, and resolves symlinks.
  The target must be a regular executable thin-64 or universal Mach-O, so the
  `bin/codex` shell wrapper in ChatGPT.app is refused.
- The file and its folder must be owned by root or the current user and be
  writable by nobody else, with no extended ACL on either.
- The code signature must validate strictly against a configured requirement.
  The default is OpenAI's Developer ID designated requirement: identifier
  `codex`, Apple-anchored, a Developer ID intermediate and Developer ID
  Application leaf (two marker OIDs), team `2DC432GLL2`. Team development
  certificates fail.
- `--version` comes from that same file, run through the owned stdio child
  with an empty environment, a 5 s deadline and a 256-byte cap. The child is
  reaped on every exit. The output must be exactly `codex-cli <version>\n`, and
  the version must be in an exact allowlist (`0.159.0`, `0.162.0-alpha.17.2`).
  The second entry is based on the stable-schema subset check recorded on #153.
- The file's device, inode, size, modified and status-change times are rechecked
  after the probe and again when the App Server command is built. A swapped
  file is refused.

What this does not prove: configuration or authentication isolation (#153 step
B), provider interruption (step C), or that the binary behaves as its schema
says. Any extended ACL on the file or its folder is refused. The child's exit
status is not checked; the exact output format is. The file is user-owned in
ChatGPT.app, so the same user can still replace
it between the identity check and `posix_spawn`. Running the real binary
against these checks is a local check only. CI uses system binaries and
synthetic scripts.

## Authority, input and lifetime

Use `CodexAppServerAdapter.withOwnedAdapter` as the explicit trusted scope. The
adapter implements the registered `singleLineContextual` profile and only
user-visible text, explicit acceptance and explicit completion capabilities.
Legacy input requires context rather than falling back, and snapshot capture is
unavailable. It exposes only its own opaque session binding; after stopping, it
lists no target and cannot restart the same generation.

The real `HailHost.withObservedSession` path remains responsible for fresh capture
authorization, policy/lockdown revalidation, exact Registry binding, sanitization,
confirmation and guarded dispatch. Capture permission is separate from input
authority. The adapter independently checks its exact immutable session/target
and observed context before requesting a turn. The host's registered shape
preflight rejects sanitized multiline input before confirmation consumption or
provider writes. One delivery creates at most one provider turn; a pending/active
turn refuses a second request. Already exhausted item/context retention refuses
the next context before the provider request.

Child creation and lease installation share the synchronous stop lock, so a
stopped lease cannot admit a later launch. Cancellation invalidates that immutable
generation and cancels only its exact owned transport immediately, before joins.
The same lock prevents post-invalidation event acceptance. The scope joins the
lifecycle and transport cleanup on return, throw or parent cancellation. A valid
in-progress turn response after a completed underlying write commits delivery
receipt independently of observation reconciliation. A refused held prefix ends
observation without exposing any of that prefix, but cannot erase the sent turn
or invite replay. Invalid responses and pre-receipt transport failures remain
failed delivery. Sent evidence is not renamed unsent merely because cancellation
subsequently stops output. This is child/lease cancellation, not
an implementation or proof of provider `turn/interrupt` semantics.

## Attribution, visibility and bounds

One pending context buffers pre-response events without attributing by arrival
order. The validated in-progress start response supplies the provider turn ID;
that response has no thread ID in the pinned schema. Every held event must match
both the already-owned thread and exact returned turn. The whole held prefix,
including duplicate/terminal consistency, is validated before any prefix event
is yielded. Unknown/mismatched IDs, conflicting item identity or terminal status,
duplicate turn binding, malformed payloads and overflow fail closed. There is no
history fallback or promotion of an unknown event to the currently active turn.

Explicit `turn/started` produces acceptance. Only completed `agentMessage` items
with explicit `final_answer`, omitted/null delivery and no questions become
user-visible final text, bounded to 8,192 UTF-8 bytes. An empty questions array
contains no questions and is allowed by the pinned schema. Deltas, async delivery,
commentary, missing/null phase, reasoning, tools and file/account metadata do not
become visible text; unknown delivery values/types are refused. Text alone never
ends a turn. Only an explicit completed terminal with no contradictory error
produces finished; failed and interrupted remain distinct fixed lifecycle events.

Early records are bounded to 16 and 32,768 retained bytes. Each generation retains
at most 64 contexts/turn tombstones and 256 composite turn/item fingerprints;
duplicates use a canonical bounded-item digest, not retained hidden content.
Exact duplicates do not repeat output; changed text or visibility under the same
identity is refused even after terminal state. Terminal tombstones reject a
contradictory later terminal. Known ended-turn suppression runs before buffering
a newer pending turn, but after those conflict checks: late old acceptance or
previously unseen old items cannot poison the new prefix, revive an ended turn
or complete a new one. Host event sequence is monotonic and bounded;
the adapter event channel holds at most 64 events. Transport framing, decoded
depth, raw notification bytes, request deadlines and child chunk queues remain
separately bounded by the transport prerequisite. Loss has fixed public-safe
reasons, not raw provider errors, identifiers or stderr. Captured text stays
host-local; visibility is not output-disclosure permission.

## Synthetic evidence and pending verification

Tests use invented Perl JSONL children over actual OS pipes, not a real CLI,
account, credential, inference, active user task or private configuration.
`CodexAppServerAdapterTests` registers the actual adapter with Registry and uses
the guarded owned host scope, including pre-response output, capture/binding
denial, confirmation reuse, single-line refusal, cancellation and actual reaping.
`CodexAppServerStartupPolicyTests` covers effective reviewer-policy refusal before
the consumer operation. `CodexAppServerEventsTests` and its protocol extension
cover exact IDs, whole-prefix refusal, visibility, conflicting duplicates,
terminal distinctions, byte/count bounds and preflight item capacity.

Earlier draft compile failures and their repairs remain in ignored local logs,
including integration draft/compile-repair/unused-result-repair lanes. The queued
policy/capacity test's first compile attempt referenced a safety helper absent
from the intentionally unre-based transport base; the next exposed throwing
macro closure inference. Both were repaired without changing production limits
(`artifacts/codex-adapter-reviewer-capacity-focused.log` and
`codex-adapter-reviewer-capacity-compile-repair-focused.log`). A configured lint
lane exposed an empty-count assertion in the new startup test; its owner repaired
that test without weakening the zero-entry assertion. The final combined command
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --parallel
--filter CodexAppServer -Xswiftc -warnings-as-errors` passed 26 tests in two
suites, exit 0 (`artifacts/codex-adapter-startup-policy-combined-focus.log`). The
guarded startup table passed all four effective-policy refusals: auto_review,
guardian_subagent, omitted and null. The separate protocol table also proves
the explicit user response succeeds; its child asserts that the outgoing request
actually includes user. Item capacity, conflicting item/terminal identities and
the registered integration cases passed in the same combined run. Configured
`scripts/verify.sh lint` passed, exit 0
(`codex-adapter-startup-policy-configured-lint.log`); whitespace checks passed.
These are unre-based draft results, not approval evidence.

After rebasing onto merged transport base
`70244e7ec532a62a8a7361b0487fe5b741e9d7fb`, with the same Xcode selection:

- Combined adapter/transport focused verification passed 61 tests in five suites,
  exit 0 (`artifacts/codex-adapter-merged-focused.log`). Configured strict lint
  passed, exit 0. These results precede the ended-turn ordering repair below.
- First `scripts/verify.sh all` exited 1: 587 tests in 93 suites, three unexpected
  `inUse` issues in unchanged audit tests:
  `AuditLogTests.aTamperedOrMislabelledFileIsRefusedAndLeftAlone` at line 78,
  `AuditLogFileTests.aSymlinkOrAWorldReadableFileIsRefused` at line 37 and
  `aClockStepBackStillFindsATailOlderThanEightDays` at line 112.
  Log: `artifacts/codex-adapter-merged-all.log`. #79 remains unresolved; no audit
  code or locking semantics changed and no exact cause is claimed.
- Inspected affected audit suites passed 16 tests in two suites, exit 0
  (`codex-adapter-merged-audit-focused.log`). Separate audit CLI and script lanes
  passed, exit 0 (`codex-adapter-merged-audit-cli.log` and
  `codex-adapter-merged-scripts.log`), including 45 checker, five intent and one
  reply CLI tests. Auxiliary passes do not rename the failed full run.
- Simulator build-for-testing passed, exit 0 (`codex-adapter-merged-sim.log`).
  Read-only generated app/UI-test bundle metadata inspection confirmed `0.1.24`
  / `1`; this is not installation, simulator UI execution or physical proof.
- Offline trace passed, exit 0: seven expectations and zero problems, without
  deferring the now-delivered adapter suites/document. Whitespace checks passed.

An independent draft security check then found a valid ended-turn ordering P2:
after A finishes and B begins but is still awaiting its response, late A events
were buffered into B's prefix; the same events were ignored once B was bound.
The repair places known-ended suppression before pending buffering, preserving
conflicting item fingerprints and terminal checks first. The regression proves
late old started/unseen-item/identical-item/terminal events remain ignored while
B is pending, old conflicts still fail, and valid B's acceptance/text/finish
continue with its exact context and sequences. Repair-focused verification passed
27 tests in two suites, exit 0
(`artifacts/codex-adapter-ended-pending-repair-focus.log`). A new test assertion
initially exceeded the line-length gate by one character
(`codex-adapter-ended-pending-repair-lint.log`); formatting was repaired without
changing the assertion. This is a meaningful source repair, not an unchanged
full-run retry. Final configured lint passed, exit 0
(`codex-adapter-ended-pending-repair-final-lint.log`). The failed first full run
remains retained evidence.

Final verification after that meaningful ordering repair, with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- The new `scripts/verify.sh all` run exited 1: 588 tests in 93 suites, two
  unexpected `inUse` issues in unchanged
  `AuditLogFileTests.aClockStepBackStillFindsATailOlderThanEightDays` at line 112
  and `AuditLogTests.aTamperedOrMislabelledFileIsRefusedAndLeftAlone` at line 78.
  All 62 transport/adapter tests passed. Log:
  `artifacts/codex-adapter-final-ordering-all.log`. This is a failed full run,
  not a passing verifier. #79 remains unresolved, with the
  [recurrence recorded separately](https://github.com/mickdarling/hailing-station/issues/79#issuecomment-5905452158).
  There was no further unchanged full rerun or audit implementation change.
- The inspected audit diagnostic passed 16 tests in two suites, exit 0
  (`codex-adapter-final-ordering-audit-focused.log`). Separate
  `scripts/tests/test-audit-cli.sh` and `scripts/verify.sh scripts` lanes passed,
  exit 0 (`codex-adapter-final-ordering-audit-cli.log` and
  `codex-adapter-final-ordering-scripts.log`), including 45 checker, five intent
  and one reply CLI tests. Configured `scripts/verify.sh lint` passed, exit 0.
  Auxiliary passes do not convert the full-run failure to green.
- Final `scripts/verify.sh sim` build-for-testing passed, exit 0
  (`codex-adapter-final-ordering-sim.log`). This remains simulator build evidence,
  not UI execution or physical-device proof.
- Final offline `scripts/spec_trace.py` against #153 passed, exit 0: seven
  expectations and zero problems, with no deferred adapter expectations.
  `git diff --check` passed. Fresh independent exact-head reviews and clean
  exact-head full CI/gates remain required; no approval or passing full-run
  result is fabricated.

## Source 0.1.25 receipt and CI-test repair

Required [CI run 36678823919](https://github.com/mickdarling/hailing-station/actions/runs/36678823919)
on `b695006495dc998bae98788a101c14c232bade37` failed its 588-test/93-suite verify
lane in unchanged
`HostConnectionDisconnectHandoffTests.disconnectReturnsWhileCancellationInsensitiveOpenDrains`,
throwing unavailable; the new Codex tests passed. This is separate from #79.
[Issue #157](https://github.com/mickdarling/hailing-station/issues/157) records the
causal fixture repair, not an ignored gate or a connection-product change. The
test now directly awaits disconnect while the cancellation-insensitive open gate
stays closed. A retained five-second deadlock watchdog explicitly records failure
before releasing the gate; it is cancelled and joined on every outcome. Before
release, assertions require disconnected state, one active held open and zero
stale closes. Release/drain then requires one close exactly; initial-readiness
failure also releases and drains cleanup, preserving the original error and
explicitly recording a cleanup failure. No 100 ms performance claim or increased
completion-polling timeout remains.

The completed review's [valid sent-receipt P2](https://github.com/mickdarling/hailing-station/pull/156#discussion_r4141541070)
found that a conflicting prefix rejected after a valid turn response could erase
delivery evidence. Source 0.1.25 separates validated RPC receipt from subsequent
event binding. Both mismatched-turn and contradictory matching-item synthetic
prefixes now produce an exact guarded-host sent ledger, followed by fixed
observation loss and no delivered prefix or late events. The stopped scope refuses
a retry; a synthetic child counter remains exactly one after actual reaping.
An invalid completed-status start response still fails with invalidProtocol,
alongside existing malformed-frame/EOF/server-request failures. No provider-side
effect success is inferred from sent.

Affected command, with Xcode explicitly selected:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter
'HostConnectionDisconnectHandoff|CodexAppServer' -Xswiftc -warnings-as-errors`.
The first run passed 30 tests in three suites, exit 0
(`artifacts/codex-adapter-send-receipt-disconnect-focused.log`). After strengthening
the cleanup-error preservation and adding the invalid-response case, the final
run passed 31 tests in three suites, exit 0
(`codex-adapter-send-receipt-disconnect-final-focused.log`). Configured
`scripts/verify.sh lint` passed, exit 0
(`codex-adapter-send-receipt-disconnect-final-lint.log`); whitespace checks passed.
The earlier source 0.1.24 full failures and metadata evidence above are historical,
not relabelled as this repair.

Final source 0.1.25 verification, with the same explicit Xcode selection:

- `scripts/verify.sh all` exited 1: 590 tests in 93 suites and eight unexpected
  `inUse` issues, all in unchanged audit tests. The affected cases were
  `AuditLogTests.aTamperedOrMislabelledFileIsRefusedAndLeftAlone` (line 78) and
  `aFileShorterThanWhatThisWriterWroteIsRefused` (131);
  `AuditDayLinkTests.eachDayNamesTheVerifiedTailOfTheLatestEarlierDay` (20),
  `aCorruptLatestEarlierDayIsReportedRatherThanSkipped` (38),
  `deletingTheNamedPreviousDayRefusesAnExistingLaterDay` (57) and
  `aLegacyV1DayRemainsWritableAndBecomesTheNextDaysPredecessor` (99);
  `AuditHistoryTests.deletionOfAnIntermediateDayBreaksTheNextLink` (53); and
  `AuditLogFileTests.aClockStepBackStillFindsATailOlderThanEightDays` (112).
  Log: `artifacts/codex-adapter-send-receipt-final-all.log`. All Codex and new
  receipt/disconnect tests passed. The full verifier stopped before auxiliary
  lanes; this is not `verify: OK`. #79 remains unresolved. No audit implementation
  change, unchanged full rerun or exact-cause claim is included.
- Inspected affected audit suites passed 31 tests in four suites, exit 0
  (`codex-adapter-send-receipt-final-audit-focused.log`). Separate
  `scripts/tests/test-audit-cli.sh` and `scripts/verify.sh scripts` passed, exit 0
  (`codex-adapter-send-receipt-final-audit-cli.log` and
  `codex-adapter-send-receipt-final-scripts.log`), including 45 checker, five
  intent and one reply CLI tests. These independent passes do not erase the
  failed full run.
- `scripts/verify.sh sim` passed simulator build-for-testing, exit 0
  (`codex-adapter-send-receipt-final-sim.log`). This is build-only evidence,
  not installed metadata, UI execution, physical-device or TestFlight proof.
- Offline `scripts/spec_trace.py` passed for #153 (seven expectations, zero
  problems) and separately #157 (one expectation, zero problems), exit 0 for
  each. Whitespace checks passed. Fresh independent exact-head reviews and clean
  current-head full CI/gates remain required before merge; no approval or passing
  full verifier is fabricated.

## Live-enablement blockers

The [bounded disposable interruption probe](https://github.com/mickdarling/hailing-station/issues/153#issuecomment-5903882829)
observed an exact-owned in-flight gate, accepted exact-ID interrupt and matching
interrupted terminal, but overall exit was 1 because held server-request
resolution was not observed within the remaining bound. It did not establish
complete held-request invalidation, real-provider late-output exclusion, lease
cleanup or inherited-configuration/authentication isolation. No probe is rerun
by this implementation. Killing a child is not proof of provider interruption.

Real registration stays disabled until those independent evidence and trusted
launcher/configuration prerequisites are resolved. #153 and #134 remain open.
Authentication/confidential transport and output disclosure (#7/#21) remain
prerequisites for captured-content publication; this slice does not send output
through the existing unauthenticated non-TLS listener or claim an iPhone/iPad
round trip.
