# Reply pacing lead (#904 ask 4, option b)

These are synthetic host-local measurements, without devices, providers or speech.
They do not reproduce the incident or prove device transport completion.

## Choice and interactions

With no other reply queued for the socket's audio turn, the lead before
admitting a whole audio frame is 3 seconds. The device starts
playback immediately. After a stall, `ReplyPlayoutPolicy` holds for 1.5 seconds,
then 2 seconds after another stall, or releases when final audio arrives. Three
seconds leaves a nominal one-second jitter margin above the largest catch-up
target without building the former 20-second socket backlog. A whole 1.25-second
frame can make total sent audio lead reach 4.25 seconds. Unbounded jitter or a
paused client is outside this steady-playback bound.

A queued job holds `LOCK_SH` on `reply-audio.waiters`, a separate 0600 file beside
its socket, opened with `O_NOFOLLOW` and `O_CLOEXEC` like the turn lock. Before each
frame admission the holder probes that file with `LOCK_EX | LOCK_NB`. Contention
selects the former 20-second lead; an uncontended probe selects 3 seconds. The
pacer keeps the same audio clock and admitted duration when switching leads.
Acquiring the audio turn, failure and cancellation release the shared signal; process
exit (including SIGKILL) releases it in the kernel. No persistent count or stale
PID can keep the larger lead selected. A frame already waiting retains its
admitted time; later admissions observe the new contention state.

This restores the former drain time when a request for another target queues:
that request cannot supersede the holder and must receive audio within the CLI's
40-second data budget after its last accepted text frame, inside the host's
60-second request idle gap. In the synthetic 60-second holder case, the last
holder audio leaves around 39 seconds and the next reply starts before 40 seconds.
The larger lead restores the previous queue behavior; it does not guarantee
liveness behind arbitrarily long replies, multiple queued jobs, stalled rendering
or endpoint rate refusals. No host keepalive or request-budget extension is added.
Same-target request supersession still uses the existing stop file.

The `latest` override (#467) still caps both audio and rate waits, even when
that exceeds the nominal lead/rate budget. The CLI's 40-second data and
55-second terminal budgets remain below `HostReplyRequest.streamIdleGap` (60
seconds). Dedicated pacer tests cover both caps. The 100-frame/minute cap still
counts text and terminal markers; real streamed audio settles at 48 frames/minute.
The device's 20-second idle watch still runs after scheduled audio drains and
is refreshed by its own frames; it was not shortened. Its obsolete lead comment
was corrected. The 30-minute `maxAudioSeconds` limit, exact-bound sample-rate
checks, and unpaced behavior are unchanged.

## Measurement method

Both measurements send 45 seconds of synthetic 24 kHz mono PCM16: one 24,000-byte
frame (0.5 seconds), one 36,000-byte frame (0.75 seconds), and 35 60,000-byte frames
(1.25 seconds). The renderer makes audio available at 2.5 times real time. A client
reads at each frame's playback start and consumes at real time, starting with the
first frame; no startup hold or jitter is injected. Counts exclude text and
terminal markers, and exclude the frame already read for playback. JSON bytes
include base64 and frame metadata, excluding WebSocket/TCP framing.

`ReplyStreamPacerBacklogTests` advances a deterministic clock using the actual
`ReplyStreamPacer` and CLI `StreamedReplyFrames.bytes(sequence:)`. Its fixed
bounds (3 unread frames, 180,000 PCM bytes, 4.25 seconds lead) fail with the old
20-second constant. It also checks no frame misses its playback start in this model.

`ReplyStreamPacerSocketBacklogTests` submits actual encoded frames through
`LocalReplyEndpoint` and `WebSocketListener` to a loopback URLSession WebSocket
client. It uses the same PCM ramp and counts acknowledged sends not yet read by
the application. Reads can race acknowledgements, so already-read sequences are
excluded. This observes application unread backlog, not kernel/URLSession prefetch
or a device `.contentProcessed` deadline. Its conservative CI bound allows 5 unread
frames, 300,000 PCM bytes and `leadSeconds + 1.25 + 1` seconds lead (5.25 seconds
at the normal 3-second setting). The extra second covers loopback observation
scheduling; the former 20-second lead still produces about 16 unread frames and
21 seconds lead, failing clearly. The deterministic bounds remain exact.

| Measurement | Lead setting | Max unread frames | Max PCM bytes | Max JSON bytes | Max sent audio lead |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deterministic simulation | 20 s | 16 | 960,000 | 1,288,240 | 21.25 s |
| Deterministic simulation | 3 s | 3 | 180,000 | 241,545 | 4.25 s |
| Loopback endpoint + WebSocket | 20 s | 16 | 960,000 | 1,288,240 | 21.215124 s |
| Loopback endpoint + WebSocket | 3 s | 3 | 180,000 | 241,545 | 4.244379 s |

The previous job measured the table above: baseline runs failed the new bounds;
revised runs passed. Its ten further serial runs of both tests measured 3 unread
frames, 180,000 PCM bytes and 241,545 JSON bytes, with loopback lead between
4.210152 and 4.246986 seconds and deterministic lead exactly 4.25 seconds.

## Initial verification (before round 2)

Fresh finishing checks ran under `taskpolicy -b`, `-j 4`, the Command Line Tools Testing
framework/plugin/rpath flags, and a 600-second watchdog with process-group cleanup.

- `swift build -Xswiftc -warnings-as-errors`: passed.
- `swift build --build-tests`: passed.
- `swift test --skip-build --disable-xctest --no-parallel --filter 'ReplyStreamPacer|ReplyCommand|ReplyBackground|LocalReplyEndpoint|ReplyTiming|ReplyPlayback|ReplyPlayout'`:
  174 tests in 32 suites passed, including both measurements.
- `swift test --skip-build --disable-xctest --no-parallel --filter 'ReplyStreamPacer(Backlog|SocketBacklog)Tests'`:
  passed five further runs (10 tests total); each measured 3 unread frames,
  180,000 PCM bytes and 241,545 JSON bytes. Loopback lead ranged from
  4.233364 to 4.265998 seconds; deterministic lead was exactly 4.25 seconds.
- `python3 -m unittest discover -s Tests/ReplyCLITests -p test_reply_cli.py -v`:
  all 50 tests passed under `taskpolicy -b`.

`.swiftlint.yml` was checked by hand: changed Swift files are at most 200 lines;
new functions, types, parameter counts, nesting, and branch counts are below the
40/150/5/2/10 warning thresholds. New code lines are at most 120 characters.
No new lint suppressions were added.

The initial PR had one behavior-changing production file and a comment-only
production file. Round 2 adds `Sources/haild/ReplyCommand.swift`, bringing the
whole PR to three production files under the PR-shape exclusions.

## Round 2 queue regression and verification

`ReplyQueueTests.test_cross_target_request_gets_all_audio_within_its_data_budget`
starts real detached CLI jobs against a private synthetic Unix-socket receiver:
an older 60-second reply followed by a request-bound one-second reply to another
target. It checks caller success while queued, first new audio within 40 seconds
of the accepted text, serialized streams, every sequence, all PCM bytes and both
terminal markers (50 and 3 audio frames). On `3fbe8f1` it failed with zero new
audio frames after the caller reported success; the older stream completed.

`ReplyQueueTests.test_killed_waiter_releases_signal_and_holder_returns_to_small_lead`
kills a real queued job with SIGKILL, checks kernel release of its shared lock
and verifies the older 30-second reply returns to the 3-second pacing schedule.
`ReplyStreamPacerQueueTests` checks deterministic lead switching without resetting
the audio clock, plus preservation of rate and request-latest caps.

Round 2 uses the same offline Command Line Tools flags, explicitly:

```sh
fw=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
flags=(-j 4 -Xswiftc "-F$fw" -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker "$fw"
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib)
taskpolicy -b swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors "${flags[@]}"
taskpolicy -b swift build --build-tests --disable-automatic-resolution "${flags[@]}"
taskpolicy -b swift test --skip-build --disable-xctest "${flags[@]}" --no-parallel \
  --filter 'ReplyStreamPacer|ReplyCommand|ReplyBackground|LocalReplyEndpoint|ReplyTiming|ReplyPlayback|ReplyPlayout'
taskpolicy -b swift test --skip-build --disable-xctest "${flags[@]}" --no-parallel \
  --filter 'ReplyStreamPacer(Backlog|SocketBacklog)Tests'
taskpolicy -b python3 -B -m unittest discover -s Tests/ReplyCLITests \
  -p test_reply_queue.py -k cross_target -v
taskpolicy -b python3 -B -m unittest discover -s Tests/ReplyCLITests -v
```

Each command has a 600-second process-group watchdog. The repeated unloaded
phase runs the cross-target test and both backlog tests five times serially.
The loaded phase does the same under exactly four `yes` workers, with a separate
590-second watchdog and EXIT/TERM/INT/HUP cleanup traps for all workers. The
unloaded wrapper initially hit a Bash empty-array cleanup error after its 15
successful test executions; that wrapper was corrected before the loaded phase.
No CPU load workers ran in the unloaded phase.

The hand check of `.swiftlint.yml` covers 200/250 file, 40/60 function,
150/200 type, 10/12 complexity, 5/6 parameter, 120/140 line and two-level nesting
warning/error limits. The pacer is 86 lines, the socket test 133, and the new
pacer test 28. `ReplyCommand.swift` retains its existing file-length exemption;
its modified turn acquisition body is 37 lines and has complexity at most 10.
New helpers/types and changed lines meet the other limits; no lint suppression
was added. SwiftLint is unavailable locally, so this is a manual check.

Both final builds passed without warnings. The requested serial Swift selection
passed 178 tests in 34 suites. The three repeated tests passed 15/15 executions
unloaded and 15/15 under four load workers. All ten deterministic backlog runs
retained their exact bounds; all ten loopback runs measured three unread frames,
180,000 PCM bytes and 241,545 JSON bytes. Every cross-target run delivered all
50 older and all three newer audio frames, with the newer first audio inside
40 seconds of its accepted text. The load phase completed in approximately
424 seconds, below its 590-second watchdog, and all four workers were stopped.
The unloaded first-audio waits ranged from 39.175 to 39.298 seconds; loaded waits
ranged from 38.921 to 39.232 seconds. Loopback lead ranged from 4.239677 to
4.244482 seconds unloaded and 4.230612 to 4.245318 seconds loaded.
The complete ReplyCLITests discovery passed all 96 tests, including the SIGKILL
waiter cleanup and restored-small-lead regression. These are synthetic host-local
checks, not simulator builds or physical-device/captured-output proof. Verification
was offline; no PR, issue, installed build or release was modified.
