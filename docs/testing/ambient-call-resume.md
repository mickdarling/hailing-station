# Ambient call pause and resume

Part of #982. Base: `88cf644f1deaace0436525e115747cc1a8710ffb`.

An ending route notification can precede a call's interruption notification. Capture previously retired its
observer on the route, reporting a terminal stop and losing the subsequent interruption. Capture now keeps its
observer and stream for an injectable 200 ms window after an ending route. An interruption in that window ends
capture with the interruption marker, so ambient records `ambient_stop reason=system_interruption` and pauses.
An isolated route still ends with its original reason. Further routes do not extend the window, and the engine
reconfiguration caused by the route cannot preempt it. Stop cancels the window; observer identity and cancellation
checks reject a stale wake. Existing engine-running, input-change and app-override guards still apply first.

A microphone pause retains listening intent across a socket generation change for the same host, target and
selection serial. Different destinations, selection changes and destination loss remain terminal. The existing
transport coordinator now includes paused microphones: it retains the destination through temporary nil bindings,
reauthorizes selection in the background, and restores the binding without starting capture in the background.
Microphone resume waits for an authorized transport. Its fresh stream opens with the existing resume flag.

Main already repeats the final microphone backoff delay indefinitely after #1021. This change retains that behavior;
there is no call-length deadline. The tests hand-step more than ten minutes of microphone failures and then resume.
An initially-off controller never creates capture or a resumer.

Known privacy or rubber-duck state is retained through the pause. Fresh private microphone streams use #904's
existing generation-bound privacy reassertion and confirmation before capture starts; a transport restore can
supply the same proof. Parked host privacy already applies to normal and resumed streams before the child is made,
so no daemon change is needed. Owner stop, selection changes and privacy taps veto the paused intent, including
while a confirmation is held. Both privacy-on and privacy-off taps keep their newer host-confirmed state and do not
automatically resume capture. Outstanding privacy requests and failed confirmations fail closed. Late confirmations
cannot reopen an ended run. Resume success uses `ambient_start`; failed microphone or private-confirmation attempts
use the existing `capture_error code=resume_failed` vocabulary.

## Synthetic verification

The regression tests were committed before production changes (`5a6f557`, then fixture initialization correction
`52e0376`). Against unchanged base production, seven test functions ran: five failed with twelve issues; long-call /
owner-stop and initially-off coverage passed. The failures included both route orderings, absent route deferral,
generation changes terminating the pause, privacy actions retaining resume intent, and missing private confirmation.

Fixtures use scripted transports, held replies, hand-stepped waits and clocks, and explicit system notifications.
Their scheduling watchdog yields while checking signals; it does not sleep or make elapsed-time assertions.
The prior guard that made a microphone interruption during a transport gap terminal is superseded by the call
resume ruling. Its replacement proves that transport-first interruptions also pause and resume. Additional guards
cover background reauthorization, destination/selection loss, route reconfiguration, and rejected,
timed-out or late private confirmations. These are macOS SwiftPM tests of device logic, not physical iPhone proof.
The host's existing privacy park/admission tests cover the daemon side of resumed starts.

The original `stoppingInterruptionDuringGapEndsInsteadOfStartingAnInterruptionResumer` body was temporarily
restored verbatim against production at `11f9eb91dfe715ee1c2ba8c2c570c6a800d155dd`. It reproduced the timeout at
`AmbientReconnectTestSupport.swift:158`: that body stops the fake capture and posts a **system interruption**,
but never calls the owner's `turnOff()`. Its terminal `.modeChanged` expectation conflicts with the call-resume
ruling; this is not a scheduling timeout or evidence that an owner stop was ignored. The transport-first
replacement requires automatic resume. Separate `ownerStopDuringTransportGapNeverResumes` cases now call
`turnOff()` both before and after interruption publication, then reconnect, publish interruption-ended, release
the injected retry and cross the foreground resume entry point. Both require off/unpaused state, one original
capture start, an owner-stop veto, and no audio on the replacement socket. The owner-stop assertion is retained
and strengthened, not converted into a resume expectation.

An initial version of that new owner-stop probe used the fixture's single-waiter `SleepGate`. Owner stop cancels
ambient pacing and creates an ordinary transport retry while the cancelled injected wait is still held; a single
continuation slot can lose or release the wrong wait. The probe now uses the existing indexed `AmbientRetrySteps`,
waits for both registrations, releases only the ordinary retry to reconnect, and then releases the cancelled
ambient wait late. No production change or longer watchdog was needed for that fixture failure.

Every Swift command uses `taskpolicy -b`, `-j 4 -Xswiftc -j1`, a shared-process gate for `swift-build`, `swift-test`
and `xcodebuild`, and a 590-second process-group kill bound. Commands run to completion. SwiftPM automatic resolution
is disabled. The already-installed Command Line Tools Testing framework requires these additional flags:

```text
-Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

`DiagnosticReplyComposition` is excluded from every test selection. Transport fixtures are synthetic or loopback;
no external network, tool installation, push or GitHub operation is involved. SwiftLint is unavailable and remains
a host check. Full Xcode and simulator/device validation are unavailable on this VM.

The first unsharded serial family run was stopped after its obsolete terminal-gap assertion failed; no result from
that obsolete binary is counted as a completed sweep. The requested family selection is partitioned by module and
suite into disjoint groups to keep every serial command within its 590-second bound. Each completed sweep covers
the union of `Ambient|Capture|Interruption|Resume|HostConnection|Privacy`, with only
`DiagnosticReplyComposition` excluded. This preserves all selected tests without overlapping test processes.

## PR 1034 independent-review corrections

Part of #982. Review input head: `84b3023556bfe59fccd2bfcf6dada1fd08e04a28`.

P1-1: the route classification window now closes capture admission as soon as an ending route is evaluated.
An interruption closes it on the notification thread, before an actor hop. Main-thread ending signals run
synchronously; no callback can slip PCM through a queued main-actor notification. The shared admission epoch
also rejects already queued capture, converter output and sends. Ambient's pause marker closes admission for
capture wrappers too. Capture retains only its observer and ending decision for the 200 ms window; gap PCM is
never retained for later replay. The original route guards and isolated-route terminal reason still apply.
`endingSignalDiscardsPCMThroughoutRouteWindow` feeds a saved fake tap before and during the held window, then
fully drains the streamer and requires zero sent frames, with both interruption and expiry outcomes. It also
reopens the transport gate during the held window: a separate per-capture-run veto keeps that ended capture shut.
That added ordering failed against the first review correction before the per-run veto was added
(`review-window-reopen-fail-before.log`); an ending route must not be undone by a fast transport restore.
`interruptionImmediatelyDiscardsPCMFromAYieldingTap` covers the immediate interruption boundary. Signals that
end even a running engine close admission on the notification thread. Startup keeps the original post-start
engine-running guard: synchronous startup's transient stopped state cannot end or gate a healthy new run.
`startupSignalsUseTheRunningStateAfterEngineStart` feeds PCM after startup category and engine-configuration
notifications. Both cases failed against the initial synchronous dispatch (three issues in
`review-startup-fail-before.log`) and now require a live tap, sent PCM and no system-end notice.

P1-2: an already-private host deliberately sends no notice for a duplicate same-socket privacy-on request.
After that socket has streamed, its gate also declines pre-arm. Private call recovery therefore replaces that
transport through the existing paced reconnect path, retaining the same host, target and selection authorization.
The fresh generation reauthorizes the destination, reasserts privacy and waits for its real pre-arm confirmation
before opening capture. It never uses the old socket's cached privacy state as permission to send PCM.
`privateSameSocketUsesFreshTransportAndConfirmedPreArm` starts with an actual synthetic PCM stream, pauses on
that socket, advances the injected clock beyond five seconds, and confirms recovery only on the replacement
transport. Held confirmation admits zero PCM; confirmation resumes a fresh stream without a spurious stop.
Existing privacy, late-confirmation, owner-stop and refusal tests now drive that normal replacement path.

P1-3: any URL change of the bound host during a call pause vetoes recovery before endpoint refresh can retain it.
The appended `callAddressChanged` stop reason preserves all prior numeric values and displays exactly
`listening stopped: host address changed during call`, in both the stop status and a pending-recovery notice.
`URLChangeDuringCallStopsWithVisibleReason` covers a live socket and a transport gap while backgrounded. Both
require listening off, the visible reason, one original capture start and no PCM on either destination, including
after interruption-ended, late retry release and foreground entry. An owner must restart listening by hand.

All evidence is synthetic SwiftPM verification on macOS; this does not establish a physical-device call round trip.
The new tests were committed before production edits. Against unchanged reviewed production, the three initial
regression functions failed (five parameterized cases, eight issues): route PCM escaped, same-socket recovery
never reached a fresh transport, and both URL-change paths kept listening intent. Evidence remains host-local in
`hs-982-evidence/review-fail-before.log`. The earlier baseline fail-before evidence remains recorded above.
