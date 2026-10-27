# Reply segments device foundation (#932 P4a)

This is offline, synthetic macOS VM evidence, using fake players and an injected clock for controller tests.
It is not an iOS app build, simulator playback, a live captured-output round trip, acoustic echo testing,
physical-device proof, or a TestFlight delivery. P4a alone does not complete P4 or close #932.

## Four-file split decided before implementation

Full P4 crosses the existing controller, its idle watch, PCM player, settings, ambient capture/echo guard,
transport and app wiring. Fitting it in four production files would require unrelated code to share files.
Only P4a is implemented here; no network, dependency installs or other clones are used.

P4a production files (four, no `SECURITY_PATHS` matches under `scripts/pr-shape.py`):

- `Sources/HailCore/Replies/ReplyPlaybackController.swift`: marker scheduling barrier, observable pause/yield
  state, validated saved settings, generation/active-reply cancellation.
- `Sources/HailCore/Replies/ReplyPlaybackController+Segments.swift`: settings value, played-marker counting,
  timer, reply-scoped callable yield, and relocated existing idle-watch/clock support.
- `Sources/HailCore/Replies/ReplyPlaybackController+Idle.swift`: exempt the marker barrier/pause from idle time.
- `Sources/HailCore/Replies/PCM16AudioPlayer.swift`: actual-playback marker callbacks, intentional batch-end
  accounting, no adaptive-stall training or gap counting, and short-tail release of an earlier catch-up hold.

Minimal proposed P4b (four production files, subject to preflight before that job):

- `AmbientReplyEchoGuard.swift`: analyze the existing pre-mask capture inputs only while ambient is enabled,
  privacy is off and a played window is open; sustain the gate, release only the yielded reply's mask/tail,
  and expose content-free yield/no-ambient-request counters. Account for the existing ~400 ms echo tail.
- `Transport/HostConnection+Protocol.swift`: capability-gated `reply_yield` and device hello advertising.
- `Replies/ReplyPlaybackController+Presentation.swift`: make bulk Replay use the segment-aware FIFO too.
- `Apps/Hail-iOS/RootView.swift`: wire fresh per-connection privacy/ambient state, callable yield/transport and
  ambient-request counter observation. P5 adds the notice and Station tools control separately.

Paths above without a prefix are relative to `Sources/HailCore`. P4b must remain independently fail-closed:
no onset analysis/yield with privacy on or ambient off, no audio bypass, no claim that an absent gate is wired.
The inspected device streamer and guard pass PCM to host-side speech processing; they do not expose a local
scalar energy threshold. P4b must resolve/reuse an available speech/energy-gate input and document its threshold
before calling onset detection complete. No new detector or threshold is invented in this foundation.
Advertising stays deferred so a negotiated host cannot activate this partial implementation.

## Implemented behavior and limits

The FIFO schedules through one `segmentEnd`, then withholds every following frame until that marker's
`.dataPlayedBack` callback and the configured pause complete. New frames retain normal queueing. The reply stays
output-busy, preserving the existing echo mask across the window. Separate user pause, capture suppression and
interruption idle holds remain authoritative. Stop/failure/generation replacement invalidate timers and callbacks;
late frames of retired replies cannot restart them. Muting keeps its existing whole-reply silent playback behavior;
headset stop-and-mute retires playback. This slice does not introduce a separate dismiss or privacy UI action.
Bulk replay retains its prior behavior until the explicit P4b integration above.
The player ends intentional-pause accounting at the configured deadline, even without a new frame. When no
following frame is ready then, ordinary adaptive stall recovery resumes and later silence counts as a gap.

`ReplySegmentSettings` reads/saves one UserDefaults dictionary (`hailing-station.reply-segments.v1`). Defaults
**v1, pending Mick**: pause 1.5 seconds, sustained onset 0.3 seconds. Inclusive bounds are 0.1–10 seconds and
0.05–2 seconds respectively; each invalid/nonfinite value falls back independently. Persisted values must be
numeric; booleans, strings, nulls and nested values are rejected. Settings are read at controller
creation; callers may assign and save a new validated value. A window uses the pause value when it opens.
There is no spoken "go on" path.

The callable `yieldPausedReply(ambientListening:privacyOn:)` requires a played window, current ambient-on and
privacy-off flags. It stops only that descriptor on that endpoint, leaves other queued replies, records a bounded
`lastSegmentYield` and returns endpoint/reply UUID/played-marker count. Those identifiers stay in memory, never
logs or defaults. It sends nothing and accepts no mic PCM. P4b must supply fresh flags and connection identity,
release the mask promptly and send only to a ready host advertising `reply_segments`.

Onset audio choice B: lose the triggering onset. No mic pre-roll is retained, logged, written or replayed; with no
yield there is likewise no pre-roll to discard. Subsequent audio uses normal ambient capture after P4b releases
the mask, subject to its existing privacy gate. The bounded-onset/replay/privacy integration is not tested here.

## Synthetic coverage

- `ReplySegmentPauseTests`: playback completion versus scheduling, two windows and counts, configured timing,
  arrivals within the pause, legacy unsegmented scheduling, watchdog exemption and fresh deadline, user pause,
  stop/late-frame rejection, headset stop-and-mute, capture suppression.
- `ReplySegmentYieldTests`: only the paused reply retires, endpoint/descriptor and played count, queued replies
  survive, stale callbacks cannot open a replacement window, outside-window/privacy/ambient-off refusal,
  and an engine-discarded marker retires its barrier without opening a false window.
- `ReplySegmentPlayoutTests`: intentional boundaries do not train adaptive policy, short tails release catch-up,
  planned silence contributes no gap while later genuine underruns still count. These execute the pure accounting
  methods used by PCM16AudioPlayer, without creating an audio engine.
- `ReplySegmentSettingsTests`: defaults, inclusive bounds, negative/zero/out-of-range/nonfinite fallback,
  individual fallback, one saved dictionary, round trip and malformed persisted values.
- `ReplySegmentsDeviceSessionTests`: marker barrier after wire decoding, hello still defers segment advertising,
  and a host-originated `reply_yield` remains unexpected and closes the connection.

Deferred expectations (actual missing P4b work, not passing tests): sustained energy at/above a documented gate,
short bursts, energy outside a pause, privacy/ambient analysis prohibition at capture time, capability-gated
`reply_yield` transmission, prompt reply-specific mask release, subsequent onset-audio handling through the normal
ambient path, false-yield counters and N-second ambient-request observation, hello advertising, segmented bulk
replay, and end-to-end dismiss/privacy wiring. P5 must test the notice and saved Station tools setting.

## VM verification commands

Every Swift invocation uses `/tmp/hs932-p4-tools/swift`, an offline wrapper expanding to:

```sh
/usr/sbin/taskpolicy -b /usr/bin/swift "$@" -j 4 -Xswiftc -j1 --disable-automatic-resolution \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

`/tmp/hs932-p4-tools/phase.py` runs each phase in a new process session with a 590-second deadline and SIGINT/SIGTERM
traps. On interruption/timeout it kills the owned process tree (TERM then KILL). The load shell additionally traps
EXIT/INT/TERM to kill and wait for exactly four owned `yes` workers. Builds/tests never install dependencies.
The known VM-only `HailDaemonKitTests.DiagnosticReplyComposition` failure (#955) is excluded; all test filters are
HailCore-only as well.

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat.sh normal
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat.sh loaded
# Each repetition script invokes this five times; loaded runs launch four owned yes workers.
/tmp/hs932-p4-tools/swift test --skip-build --no-parallel --filter 'HailCoreTests\.ReplySegment' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.(Reply|Playback|PCM16|Echo|Capture|Ambient|HostConnection|Privacy|Mute|Dismiss|Segment)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
git diff --check
```

Final-source results on the Dev Work VM:

- `swift build -Xswiftc -warnings-as-errors`: passed, 14.84 seconds, no compiler diagnostics.
- `swift build --build-tests`: passed, 26.40 seconds, no compiler diagnostics.
- Segment filter: 22 test functions in five suites (including parameterized cases), five of five normal
  repetitions and five of five repetitions under four `yes` workers passed. Final individual runs took
  0.109–0.511 seconds of test execution; the five-run phases finished well below 590 seconds. Owned load
  workers were killed and waited for by the exit trap.
- Exact requested HailCore regression filter: 353 tests in 79 suites passed, 82.154 seconds. The excluded
  daemon diagnostic test was never run. No simulator or physical-device tests were run.
- `git diff --check`: passed. Manual `.swiftlint.yml` review covered file/type/function length, line length,
  parameter count, nesting, cyclomatic complexity and opted-in rules. SwiftLint is not installed on this VM;
  this is a hand check, not a claimed SwiftLint invocation. Controller/segments/idle files have 191/141/200
  lines; the PCM file retains its pre-existing `file_length` waiver. Main type bodies have 148/145 code
  lines excluding comments/blanks, below the 150 warning limit. No new waiver was added.
- Local source/security classification used the checker's exact exclusion tuples and `SECURITY_PATHS`:
  four production files, no security-path matches, no renames. Full GitHub PR-shape/review/issue-state checks
  were not run because this job is offline and creates no PR.

## P4a fix round 1 (#956)

Starts at `b716675c973ab4e267e55263b8637c206794a3ee` on `codex/932-p4-device`. Only the two reviewed
production files, their regression tests/support and this evidence record change. The P4b1 branch is untouched.
All evidence is offline and synthetic on the Dev Work VM; no network, other clone, simulator, physical audio,
deployment, upload or installed-build change was used.

The controller's existing pause timer now ends player accounting at the captured deadline, before draining
queued frames. Missing next audio enters ordinary adaptive catch-up; queued audio does not train a stall.
User/capture/interruption holds remain authoritative, and cancelled windows never end a replacement window.
`ReplySegmentPlayoutTests.lateFrameCountsOnlySilenceAfterThePauseDeadlineAndTrainsStallRecovery` checks
a 1.5-second pause and a frame at +7 seconds: one gap of exactly 5.5 seconds and an adaptive stall. The existing
planned-silence test still checks no gap or adaptive training. Controller tests check queued/missing audio,
held windows and cancellation at the deadline boundary without creating an audio engine.

Settings now require numeric values and reject CFBoolean and NSNumber Boolean encodings before conversion.
The two new settings tests check true/false through real UserDefaults, and independently reject booleans,
numeric/other strings, NSNull, arrays and dictionaries in either field while preserving a valid companion.
NSNull dictionaries are injected at the UserDefaults read boundary because NSNull cannot be persisted there.
Valid numeric NSNumber/Double values and the existing round trip still pass.

Every Swift command uses the `/tmp/hs932-p4-tools/swift` wrapper documented above (`taskpolicy -b`, `-j 4`,
one compiler worker per target, offline resolution and all supplied Testing flags). Each build/test phase runs
serially through the existing 590-second `phase.py` deadline and owned-process-tree kill trap; no load workers
are launched. Exact commands:

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests -Xswiftc -warnings-as-errors
for iteration in 1 2 3; do
  python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
    --filter 'HailCoreTests\.ReplySegment' --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
done
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.(Reply|Playback|PCM16|Playout|Segment)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
git diff --check
```

Results:

- Both warnings-as-errors builds passed: production 6.35 s; build-tests 57.88 s.
- Segment filter passed 3/3: 25 functions in five suites, 38 case invocations per run (75 function executions,
  114 case invocations total), in 0.499/0.533/0.536 s. The malformed-settings function also checks 24
  independent invalid-field/valid-companion combinations per run.
- Exact requested serial regression passed: 160 tests in 30 suites, 1.717 s. The daemon diagnostic test
  (#955) was explicitly excluded and is outside both HailCore filters.
- `git diff --check` passed. Changed noncomment Swift lines fit 120 columns; changed types/functions fit
  the configured length limits, with no new lint waiver. SwiftLint is unavailable; this is a manual check.
- Exactly two production files change; tests/docs are excluded. No PR, remote review or GitHub checks ran.

## Host build and physical follow-up

A full-Xcode host must build the iOS/iPadOS simulator app and macOS app/package with warnings as errors, confirming
Observation state, AVAudioPlayerNode completion ordering, actor isolation, session routing and the saved-settings
API. Once P4b/P5 land together, verify segmented Replay, capability negotiation with both old/new hosts,
per-connection yield routing, prompt mask release, echo-tail false positives, muted/stop/dismiss/privacy behavior,
ambient on/off transitions and the paused notice/Station tools setting. On real speaker/headphone routes confirm
that the window begins after sound finishes, lasts the configured interval, does not count as a stall/gap, and
that any-voice onset works without sending reply echo or private audio. No build upload/installation is in scope.
