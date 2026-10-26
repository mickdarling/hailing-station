# Reply pacing lead (#904 ask 4, option b)

These are synthetic host-local measurements, without devices, providers or speech.
They do not reproduce the incident or prove device transport completion.

## Choice and interactions

The lead before admitting a whole audio frame is 3 seconds. The device starts
playback immediately. After a stall, `ReplyPlayoutPolicy` holds for 1.5 seconds,
then 2 seconds after another stall, or releases when final audio arrives. Three
seconds leaves a nominal one-second jitter margin above the largest catch-up
target without building the former 20-second socket backlog. A whole 1.25-second
frame can make total sent audio lead reach 4.25 seconds. Unbounded jitter or a
paused client is outside this steady-playback bound.

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
or a device `.contentProcessed` deadline. Its conservative bound allows 4 unread
frames and 4.30 seconds lead (50 ms observation tolerance).

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

## Verification

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

There is one behavior-changing production file (`ReplyStreamPacer.swift`) and
one additional comment-only production file (`ReplyPlaybackController+Idle.swift`).
The PR-shape checker's exclusions leave two production files; all other changes
are tests or Markdown documentation. Verification is offline; no PR or release
was created or modified.
