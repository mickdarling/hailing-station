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
The listener profile is an immutable validated startup snapshot; changing a profile requires off/quit and
a fresh command, never a silent reload or transcript instruction. Fifteen-minute run and original advice
deadlines, route/fixed-binding fences, caps and owned child/renderer cancellation remain unchanged.

Native audio/child factories execute only after explicit aware enable; the local PCM-only speech bridge only
after admitted advice. Native service/runtime remain trusted operator prerequisites. The executable proof
uses the same owner with generated capture, pinned authored producer, mock TTS and synthetic private player.
This source command does not establish actual AirPods support, speech quality, hardware-atomic fallback privacy,
production advice-provider readiness or physical proof. No live/device/service/provider/model/public/push/merge,
installation/signing/deployment or recording/archive action is authorized by this change.

Independent full exact-head reviews, full verification and command-level synthetic tests remain pending.
