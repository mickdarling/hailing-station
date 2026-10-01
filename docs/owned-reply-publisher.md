# Owned diagnostic publisher prerequisite (#177)

Source 0.1.58 adds an unregistered, default-off publisher. This is not #166 daemon composition,
a target grant/selection, TestFlight delivery or physically validated origin routing (#161).
The only payload is the retained `DiagnosticBridgeReply` UUID and its explicitly labelled fixed
diagnostic phrase; no model chooses a recipient or supplies executable, environment or working directory.

## Admission and caller retirement

Trusted local construction supplies the exact CLI executable, matching host, reply socket and existing
private output root. Public construction uses the local environment and a 30-second admission-to-outcome
deadline. These are operator choices, not client-controlled command execution. argv is a fixed `reply`
invocation with the diagnostic target, retained `--request`, fixed `--say`, socket and explicit
`--renderer-output-root`. No shell is used. stdout/stderr are discarded; command exit, cancellation,
deadline, startup, ownership and cleanup failures use fixed categories without private output.

There are at most **16 total admissions**, including queued callers and returned callers whose resources
still await cleanup. At most **four resource-bearing slots** can start; starting, running and retired
cleanup-pending groups/directories all occupy this limit. The diagnostic `running` count means occupied
resource slots, not a claim that those kernels are executing instructions. A queued caller also has a
deadline and can cancel without creating a directory or child. Failed directory identity/removal retains
its admission instead of permitting unbounded residue. Cleanup failure remains separately diagnosable
after cancellation already returned its one-shot outcome.

The callback continuation is separate from cleanup ownership. After pinned quiescence and exact reap,
the fixed CLI outcome is reported before potentially blocking directory deletion. A successful
acknowledgement does not promise deletion completed; subsequent cleanup failure is separately visible
in `lastCleanupFailure` and retains the slot, never a contradictory second command outcome.
No task-group timeout joins a
non-cooperative CLI transaction, and no blocking `waitUntilExit` is used. Deadline/cancellation returns a
fixed failure while the lifetime owner remains held. Dispatch scheduling, filesystem/kernel operations
and supervisor death preclude an absolute wall-clock cleanup guarantee. The bound is resource admission
in a live publisher instance, not automatic recovery of stale files across process restart.

## Group ownership and cleanup proof

`posix_spawn` atomically sets a new group with SETPGROUP(0) and starts the direct leader suspended.
Ownership state and exit observation are installed before exposure to resume/cancellation. Startup
cancellation is latched; a cancelled suspended leader is killed without executing CLI work. A raced
late installation still receives cancellation. Uncertainty in complete membership prevents signaling;
pending escalation can resume only after fresh ownership/membership observations become valid.

All signal admission and exit/cutoff transitions share one lock. Non-consuming `waitid` with WNOWAIT
pins the exact waitable direct child. Only CLD_EXITED/KILLED/DUMPED are terminal events; stopped or
continued metadata cannot authorize reaping. TERM is followed by KILL after a short signal-submission
grace, with fresh nonblocking observation and group inventory at each submission. Exclusive waitable
ownership/default SIGCHLD and no unrelated child reaper throughout the lifetime are preconditions.

An exited leader plus submitted KILL does **not** prove descendants are gone. A successful complete
bounded `proc_listpgrppids` inventory must contain exactly the exited unreaped leader. This API returns
a PID count, not byte count. Missing, zero, negative, full-capacity, duplicate or otherwise invalid
inventory is unknown, not quiescence. Surviving descendants retain the slot/root and are checked again.
The PID reservation is retained until the group-signal gate permanently closes, then only the direct
leader is reaped. No raw PGID observation after reaping can restore signaling. ECHILD/terminal observation
failure permanently forbids later signals and deletion and retains resource admission for local recovery.
The parent does not reap grandchildren; orphan reaping is the operating system's responsibility.

Only after that quiescence proof and exact reap may the job directory be removed. Deletion is bounded,
descriptor-relative, identity-checked and no-follow (depth eight, 1,024 names per directory and 4,096
total entries); symlinks are unlinked, not traversed. Neither the
configured root nor arbitrary external directories are recursively removed. Unexpected identity/depth/
entry-count failure retains the resource. POSIX has no inode-conditional rmdir: concurrent hostile
same-UID path rebinding is outside the trusted private-root contract. A committed normal cleanup is
irrevocable; later cancellation cannot submit another signal or contradict its outcome.

This is a process-group contract for trusted non-daemonizing/non-escaping CLI/renderers, **not a sandbox**.
Uncooperative kernel exits remain retained; deliberate setpgid/daemonization, unrelated group joiners,
external reapers and abrupt supervisor death are not claimed to be contained. Renderer abnormal leaves
retained by #179 can now be removed only by this outer owner's actual group-quiescence proof.

## Synthetic evidence and limitations

OwnedReplyProcessTests / OwnedReplyProcessIntegrationTests use only controlled Perl fixtures and the
actual built CLI against an owner-only test endpoint. They cover pre-spawn/pre-resume cancellation,
zero early work, stopped-event/lost-identity/permanent-cutoff gates, TERM-ignore escalation including an
exited leader's descendant, independent group isolation, unknown-inventory retained admission, cap16/
four-slot refusal before a fifth resource, queued deadline, late-cancel cleanup commitment, and directory
replacement/no-follow behavior. Actual CLI fixtures prove three correlated text/PCM/final frames,
inherited group and explicit-root identity/0700 containment, held text and audio acknowledgements,
cancel/deadline retirement without waiting for the CLI's 15-second transaction, and no whole-command retry.
OwnedReplyPublisherCleanupTests additionally prove caller acknowledgement during a deliberately blocked
cleanup and separately visible cleanup failure with retained admission and no second command outcome.

Initial unpublished testing exposed a draft event-classification error: treating any siginfo PID as an
exit caused a premature closed-gate reap attempt. That failed safely, retained artifacts/resources and
was corrected before review; those old attempts are not proof of cleanup. The fixture also replaced a
misleading path-string-prefix check with actual ancestor device/inode identity because Foundation and
kernel canonical path spellings differ. These are synthetic process/control proofs, not real speech,
provider-session capture, authentication, a live enabled bridge, device hearing or two-client validation.
#177, #166 and #161 remain open until their remaining applicable acceptance and independent review.

## Review correction: cancellation racing job installation

Independent security audit of 0.1.52 found a split-lock cancellation race. Cancellation could latch
while no job was installed, then mistake a subsequently installed job for a queued entry because
startup had cleared `starting`. Removing that entry released admission before its suspended child and
private directory were cleaned. This violated the resource bound even though activation observed the
cancellation latch.

Version 0.1.53 revalidates both startup and installed-job ownership under the removal lock. A raced
installation keeps its resource admission and receives the existing cancellation latch; only an entry
with neither startup nor an installed job may be removed as queued. The deterministic regression
holds cancellation after its first lock, installs the suspended job before the removal lock, and
keeps group inventory unknown. It proves the retired caller still occupies a slot, four retained
resources prevent a fifth startup, and all 16 admissions (including 12 queued callers) reject a 17th.
The regression failed on the previous implementation at retained admission before this correction;
no real renderer or live device was involved.

## Review correction: latest cleanup failure is an event record

GitHub review of 0.1.53 found that `lastCleanupFailure` chose the first failing retained dictionary
entry. Dictionary order is not failure order: different retained failures could report the wrong
category or change after unrelated admission mutations.

Version 0.1.54 records cleanup-failure events directly in publisher status under its state lock.
Startup directory-retention failure, lost observation/failed exact reap, and failed directory removal
all record their fixed category. Each installed job reports its cleanup failure once, so repeated
observations of an older retained failure cannot overwrite a newer event. The field is the latest
reported cleanup-failure category (historical, like `lastFailure`), not an arbitrary current job or a
kernel wall-clock ordering claim. Successful cleanup, entry mutations and stop do not clear it.
Admission/cleanup ownership and the caller's one-shot command outcome are unchanged.

A deterministic synthetic event regression proves both category orderings, repeated older observation,
successful unrelated entry creation/removal, and stop persistence. It failed before the diagnostic
correction and passes after it. Existing actual-process directory-replacement coverage separately
proves a real cleanup failure reaches this status without contradicting successful acknowledgement.
The synthetic event test deliberately does not destroy a real child's waitable ownership or signal a
lost/reaped identity; no deployment, real speech or physical-device proof is claimed.

## Base refresh after #184

Version 0.1.55 merges current main `f6e4deb79afee82835e161f40796284ead3a2fa2`
without rewriting published history. The sole merge conflict was the marketing version in
`project.yml`: #184 advanced main to 0.1.52 while this prerequisite had reached 0.1.54.
The resolution advances to 0.1.55 and retains both prior publisher review corrections unchanged.
The inherited RightyO consumer and its fixture improvements remain main's changes, not new
publisher composition or deployment. Verification and independent review must cover the full
publisher diff against this actual new base; earlier-head approvals remain historical.

The initial refreshed full test run, concurrent with simulator build, missed two short fixture
startup/acknowledgement milestones. After inspecting those failures, the full verifier run without
concurrent simulator load passed all 760 Swift tests/119 suites and 26 CLI fixtures; simulator and
strict uncached lint also passed. No publisher implementation or test was changed to obtain that
result, and the initial failures remain recorded rather than claimed to be a fixed scheduling bug.

## Review correction: interrupted exact reap

GitHub review of 0.1.55 found that EINTR from the final nonblocking `waitpid` was treated as lost
ownership. After the signal gate had closed, that transient interruption could leave the exited
direct child unreaped and retain its directory/admission indefinitely.

Version 0.1.56 retries only EINTR against the same pinned direct leader, still using WNOHANG and
without reopening signal authority. Only that exact leader's returned PID authorizes cleanup.
Zero, wrong PID, ECHILD and other errors remain failures with retained ownership/cleanup resources.
The controlled real-child regression injects three interruptions before the real exact-PID reap;
it failed on the previous single-call implementation and now proves successful outcome, normal
admission/root cleanup and no signals after cutoff. Separate synthetic-result coverage proves other
unexpected results are not retried; it does not deliberately destroy a real child's ownership.

The first refreshed GitHub CI run separately passed all 760 Swift tests but failed one inherited CLI
retry fixture with POSIX error 50 (Network is down), rather than its expected retry-budget error.
The exact log is preserved; cause remains unproven. This reap correction does not claim to fix that
socket failure, and the failed required check is not waived or manually rerun on unchanged code.

The finished correction passes the full local verifier (762 Swift tests/120 suites, 45 trace tests,
five intent tests and all 26 synthetic CLI fixtures), simulator build-for-testing, strict uncached
lint and full actual-base diff check. The two new regressions live in `OwnedReplyPinnedReapTests`
to retain the existing per-file lint limit; existing correlated CLI tests remain unchanged.

## Review correction: inconclusive exit notification

The ready-trigger code review of 0.1.56 found that a resumed normal job's process-exit callback
could receive EINTR or no terminal status from nonblocking waitid and return without scheduling
another inspection. With no second exit notification, a successful child could be reported as a
deadline failure even though its exact waitable identity remained owned.

Version 0.1.57 remembers exit notification under the existing state lock and uses the existing
single scheduled inspection slot to retry inconclusive status reads. Readiness is not proof of
terminal exit, quiescence or permission to reap: the existing terminal-status, complete inventory,
permanent signal-cutoff and exact-reap checks remain necessary. Unknown ownership still fails
closed; no signal gate is reopened and ordinary running jobs are not continuously polled.

A controlled real-child regression holds terminal metadata until the actual exit notification,
then injects two EINTR or two empty-status observations. Both cases failed on the prior branch
with deadline outcomes and now succeed without cancellation/escalation signals, releasing admission
and cleaning the private job root. WNOWAIT preserves the child's exact ownership throughout; no
external reaper, live renderer, device action or deliberately lost real-child identity is used.
Historical timing/network failures remain separate, unproven causes.

The first full run used a one-second deadline for the new fixture and one case reached its deadline
before entering the injected terminal-observation stage (zero injected attempts). The final test uses
the harness's standard three-second deadline with the same outcome/signal/cleanup assertions. With
that final test, the old inspection branch still reproduces both deadline failures; this test setup
change is not a production timeout change or a claimed fix for historical timing/network failures.

Fresh independent review of the local 0.1.57 head separately reproduced a readiness-dependent
failure in the pre-existing escalation test, both in full and focused runs. Its 400 ms admission
deadline could retire a valid startup before the TERM-ignore/descendant fixture wrote its record.
That assertion neither established the intended escalation premise nor identified a kernel cause.

Version 0.1.58 separates those phases in `OwnedReplyDeadlineEscalationTests`: activate the actual
owned job, wait for its fixture record proving installed TERM behavior/descendant creation, then
invoke the same fixed deadline transition used by the timer. Assert the deadline outcome, one TERM
and one KILL, successful pinned cleanup and an empty root. This test does not claim elapsed timer
expiry. Existing queued-deadline and actual CLI socket-wait deadline tests retain real timer-expiry
coverage unchanged, including bounded admission/caller retirement. Production deadlines and
ownership assertions are not weakened. Missing readiness still fails the fixture watchdog.
