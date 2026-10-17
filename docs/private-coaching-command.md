# Foreground coaching command — source only (#269 / #268 / #225)

`haild coaching` is a separate foreground composition, never the daemon/ambient run mode. It constructs no
HailHost, actions, tmux, network listener, target grant or ordinary reply publication. Main dispatch enters
this branch independently. Explicit absolute paths and distinct local output/room-microphone IDs are required.
Native composition is compiled only: no test queries devices, calls its Apple factory or renders real speech.

The command requires a local terminal for input and status, starts OFF and never automatically resumes.
Only the owner keyboard can issue `enable aware`, confirming participant awareness on every fresh run.
Owner-answer activity defaults busy each run; separate `owner idle` is required and actual private queue
observation must be known. Descriptive producer voice/roles/text never supply authority or activity flags.
`off`, awareness/permission loss, invalid input, terminal EOF and interrupt/termination signals retire the
same foreground owner; quit/exit joins owned retirement. Bounded asynchronous terminal reading never blocks
the one-second renewal/audio actor. Buffered enable commands cannot revive authority after terminal loss.
Close and deinitialization cancel signal observers and restore their complete prior dispositions;
a later interrupt/termination follows that original process policy while retirement joins. Authored
tests inspect this test process's handler, flags and mask without delivering a signal. Off clears the
playback observer, and native playback observation weakly references its audio owner, so an ended run
does not retain a HAL/engine graph or overlap the next native allocation merely through observation.
The listener profile is an immutable validated startup snapshot; changing a profile requires off/quit and
a fresh command, never a silent reload or transcript instruction. Fifteen-minute run and original advice
deadlines, route/fixed-binding fences, caps and owned child/renderer cancellation remain unchanged.

Full Round1 rejected the .142 command head for synchronous actor-bound terminal status output: an eligible
synthetic PTY filled to backpressure blocked the exact status write for 0.523 seconds until an independent
drain, preventing ready EOF retirement meanwhile. The corrected feedback descriptor is nonblocking, accepts
only bounded content-free ASCII messages, and queues nothing. Partial writes, backpressure and errors retire
the same owner and join before exit; even the initial instructions use this path. The shared actual run loop
is tested with authored ports and a full synthetic PTY without any drain. Original nonblocking status mode is
restored after joining. The original probe and subsequent test diagnostics remain preserved; fresh integrated
head reviews are still required, and the prior verdict is not an approval of this correction.

A further actual CLI probe found the final coaching refusal used ordinary blocking stderr after those flags
were restored: a full authored PTY kept invalid configuration running until the controller drained it.
The coaching-only final diagnostic now uses the same bounded nonblocking writer and then exits 64, even
for a full or disconnected pipe. It never echoes input and does not change other commands' error reporting.
Other redirected destinations are silently skipped: nonblocking flags do not bound regular-file I/O.
Actual isolated executable regressions use invalid configuration before any native factory, no terminal
drain, and software descriptors only. The red evidence remains preserved. This is an exit/reporting fix,
not evidence of continued private effects after retirement or physical-device qualification.

Native audio/child factories execute only after explicit aware enable; the local PCM-only speech bridge only
after admitted advice. Native service/runtime remain trusted operator prerequisites. The executable proof
uses the same owner with generated capture, pinned authored producer, mock TTS and synthetic private player.
This source command does not establish actual AirPods support, speech quality, hardware-atomic fallback privacy,
production advice-provider readiness or physical proof. No live/device/service/provider/model/public/push/merge,
installation/signing/deployment or recording/archive action is authorized by this change.

Independent full exact-head reviews, full verification and command-level synthetic tests remain pending.

Fresh native review found that a duplicated terminal descriptor shared its nonblocking status with the
launching shell. Feedback now reopens and verifies the same terminal device with its own nonblocking
description. Redirected refusal feedback accepts only already nonblocking pipes; blocking redirected
stderr is silent with the same refusal exit status rather than changing another writer's flags.
An admission-time HUP/error check also rejects buffered enable after the writer has closed, including
when the consumer was already waiting. Authored PTY/pipe tests cover these orderings without native audio.

Canonical terminal Ctrl-D reports readable EOF without HUP. The same bounded keyboard reader now
drains ready input and EOF before actor suspension and rechecks through that reader at admission.
The queue/line bounds and an eight-read ceiling bound actor work. A precise pending-EOF admission
regression fails before this correction; an already-waiting canonical terminal consumer is also covered.
