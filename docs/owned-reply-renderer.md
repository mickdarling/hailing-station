# Owned reply renderer prerequisite (#179)

This host-local prerequisite is not diagnostic publisher composition (#166), whole-job supervision
(#177), an enabled target, or a delivered/physically validated device build. The source version is
0.1.50. Synthetic tests do not establish real Voicebox quality or two-device routing.

## Trusted launch and output configuration

`haild reply ... --say <text>` launches the fixed `/usr/bin/env vbsay` command with trusted local CLI
environment configuration. The text remains a payload argument, not a shell command. The launcher
does not accept a PID, executable, process group, or arbitrary launch operation from a client. stdout
and stderr go to `/dev/null`; public failures use fixed categories without private argv/configuration
or raw renderer errors. The current local renderer is not executed by these tests.

The optional `--renderer-output-root <private-existing-directory>` is local trusted configuration,
valid only with `--say`. Before **any text publication**, the root must be an existing, owner-owned,
0700 plain directory with no extended ACL. A final-component symlink is rejected. The default remains
Foundation's temporary directory, checked under the same rules; setting TMPDIR is **not** a promise
that Foundation will choose it. Composed jobs must pass an explicit private root.

The renderer gets a newly created 0700 child leaf beneath that root via VBSAY_OUT, plus VBSAY_NOPLAY=1.
No supplied root is recursively removed. Creation uses the checked root descriptor. Normal cleanup
opens the recorded leaf with O_NOFOLLOW, checks device/inode/owner/mode, and recursively unlinks only
descriptor-relative entries. Replaced root/leaf paths cannot redirect recursive deletion. Symlinks
are unlinked rather than followed. Unexpected excessive depth/count fails cleanup visibly.

The final empty-directory unlink is rechecked against its recorded identity. POSIX does not offer an
inode-conditional rmdir: concurrent hostile same-UID name rebinding is outside this trusted private
root/renderer contract. This is not an arbitrary filesystem or same-UID sandbox. Failed identity
validation retains the leaf and reports cleanup failure; it never substitutes a broad recursive delete.

## Exact child versus whole job

posix_spawn deliberately sets neither SETPGROUP nor SETSID. The renderer inherits its owning CLI's
group. Only the future #177 supervisor may establish and signal the whole job's group; this helper
signals its exact unreaped child only. PID signaling and waitpid share a lock. A successful reap or
ECHILD/other lost-ownership result permanently cuts off subsequent signals; an interrupted observation
does not silently discard ownership. No caller-supplied numeric PID can become a signal target.

Exclusive waitable-child ownership is a runtime precondition. Before publication/spawn, the helper
rejects ignored/custom SIGCHLD handlers and SA_NOCLDWAIT. An unrelated waitpid(-1) reaper or concurrent
signal-disposition change remains unsupported throughout the child's lifetime: the helper's lock does
not coordinate third-party process-wide reapers. Retrospective ECHILD detection cannot remove every
external-reaper race and is not claimed to do so.

A DispatchSourceProcess exit event plus a single nonblocking registration-race check observes exit.
Only an observed-exit/interrupted-readiness race schedules another nonblocking check; there is no idle
reaping poll or waitUntilExit. The resource lifetime is separate from the consumer facade, so dropping
the facade initiates cancellation/retirement without stranding the source's strong reference cycle.

Successful cleanup requires **both** consumer retirement after stable-file/final-marker reads and
trusted successful renderer exit that waits for all writers. Normal exit alone cannot prematurely
delete PCM before those reads. Actual VB say can use subprocesses, so this is not a single-process
claim. Cancellation, nonzero exit, or lost child ownership **retains the private leaf** with a fixed
deferred/lost-ownership disposition. Exact leader reaping does not establish descendant quiescence.
Controlled synthetic tests demonstrate a descendant can still write after the leader is cancelled.

Cancellation submits exact-child TERM then, after a short grace, exact-child KILL if ownership remains.
Deferred retirement is reported without awaiting kernel exit. The CLI may await the signal-submission
window before returning a failure, but never equates its completion with reaping or directory cleanup.
Scheduling, uninterruptible kernel operations, and process-runtime death prevent any absolute wall-clock
cleanup guarantee. The retained lifetime owner continues asynchronous responsibility only while its
process lives. #177 must own remaining group/output-root cleanup in composed use; standalone abnormal
CLI use may require explicit local cleanup. No whole-command retry is added.

## Protocol compatibility and synthetic evidence

Text-first recipient admission remains ahead of renderer launch. Text, PCM segments, and final audio
use the same reply/request/stream descriptor and sequence progression. Typed requestPending retries
still reuse the identical encoded frame; ambiguous publication is not retried as a whole command.

OwnedReplyRendererTests and OwnedReplyRendererCleanupTests cover startup/cancellation/exit ownership,
facade retirement, lost-PID cutoff, deferred signal-window disposition, stable-read retention,
descriptor-relative replacement/symlink cleanup, and abnormal descendant behavior. The real CLI fixture
creates its own job group and proves inherited grouping, explicit-root containment, owner-only root/leaf
permissions, three correlated frames, successful normal cleanup, rejected roots before publication,
and fixed failure/deferred-cleanup behavior. Fixtures generate synthetic PCM only: no real renderer,
provider, speech, device, signing, host configuration, grant, or selection action is performed.

## Review correction: retain the primary publication failure

Independent review of the original prerequisite observed accepted text followed by refused audio
reporting only cleanup-deferred. That hid the primary transport/publication failure. Version 0.1.49
wraps rendered-audio submission in a fixed `speech reply publication failed` category while separately
reporting deferred output cleanup. Endpoint/NW details and private configuration are not forwarded.
Known safe local validation, renderer and cancellation categories remain distinguishable. Static PCM
and text submission behavior is unchanged; no whole-command retry is introduced.

Actual CLI fixtures now prove both text-accepted/audio-refused and text-accepted/lost-audio-ack paths
exit unsuccessfully with the primary category and deferred disposition, produce no success summary,
send exactly the original text and first audio attempt, preserve their descriptor, and leave the
private leaf for the future whole-job owner. This is synthetic evidence only.

## CI fixture correction: startup versus lifecycle progress

CI run 36793620859 on version 0.1.49 failed ten renderer tests at their three-second fixture
watchdog. Several failures waited for the fixture's first readiness record, before any cancellation,
exit observation or cleanup assertion. Pre/during-start cancellation succeeded. The log's anonymous
watchdog did not identify interpreter startup, fixture assertions or a later lifecycle stage, so it
does not establish a production reaping defect or prove a specific cold-start schedule.

Version 0.1.50 replaces the Python/pathlib test fixture with a smaller built-in Perl fixture. It keeps
actual subprocess launch, inherited-group and 0700 assertions, synthetic PCM, TERM-ignore escalation,
ordinary forked descendant behavior and the **unchanged three-second watchdog**. Watchdog diagnostics
now name the fixed test phase and report only interpreter-started/assertions-ready booleans, never
private paths or identifiers. Local startup-only comparisons with 1, 12 and 24 concurrent synthetic
children measured Python maxima of 77, 143 and 167 milliseconds versus Perl maxima of 6, 9 and 12
milliseconds. Both completed successfully; these measurements support reducing fixture overhead, not
a claimed reproduction of the failed CI schedule. No renderer production lifecycle, cancellation
grace, authority or publication deadline changed.

That run also exceeded the existing guard-performance test's 500-millisecond wall-time limit during
parallel process fixtures. Its issue-backed test correction measures same-thread CPU work, so
unrelated scheduling delays do not masquerade as regex computation; the limit remains 500 milliseconds.
Production guard rules and the 20-millisecond fail-closed elapsed-time budget are unchanged, as are
the dedicated expired-budget and language assertions. A CPU-work benchmark does not prove an elapsed
latency bound on a contended machine.
