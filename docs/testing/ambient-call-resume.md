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

Every Swift command uses `taskpolicy -b`, `-j 4 -Xswiftc -j1`, a shared-process gate for `swift-build`, `swift-test`
and `xcodebuild`, and a 590-second process-group kill bound. Commands run to completion. SwiftPM automatic resolution
is disabled. The already-installed Command Line Tools Testing framework requires these additional flags:

```text
-Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

`DiagnosticReplyComposition` is excluded from every test selection. No network, tool installation, push or GitHub
operation is involved. SwiftLint is unavailable and remains a host check. Full Xcode and simulator/device validation
are unavailable on this VM.
