# Reply segments device foundation (#932 P4a/P4b1)

This is offline, synthetic macOS VM evidence, using fake players and an injected clock for controller tests.
It is not an iOS app build, simulator playback, a live captured-output round trip, acoustic echo testing,
physical-device proof, or a TestFlight delivery. P4a/P4b1 do not complete P4 or close #932.

## Split decided before implementation

Full P4 crosses the existing controller, its idle watch, PCM player, settings, ambient capture/echo guard,
transport and app wiring. Fitting it in four production files would require unrelated code to share files.
P4a and the inert P4b1 detector are implemented here; no network, dependency installs or other clones are used.

P4a production files (four, no `SECURITY_PATHS` matches under `scripts/pr-shape.py`):

- `Sources/HailCore/Replies/ReplyPlaybackController.swift`: marker scheduling barrier, observable pause/yield
  state, validated saved settings, generation/active-reply cancellation.
- `Sources/HailCore/Replies/ReplyPlaybackController+Segments.swift`: settings value, played-marker counting,
  timer, reply-scoped callable yield, and relocated existing idle-watch/clock support.
- `Sources/HailCore/Replies/ReplyPlaybackController+Idle.swift`: exempt the marker barrier/pause from idle time.
- `Sources/HailCore/Replies/PCM16AudioPlayer.swift`: actual-playback marker callbacks, intentional batch-end
  accounting, no adaptive-stall training or gap counting, and short-tail release of an earlier catch-up hold.

Coordinator-approved P4b1 split (two production files, **v1, pending Mick**):

- `Sources/HailCore/AmbientReplyEchoGuard.swift`: opt-in pre-mask tap, scalar RMS onset gate and content-free
  diagnostics. It reads the guard's configured tail; the default remains `AmbientReplyEchoGuard.defaultTail`
  (400 ms). No yield, mask release, transport or capability advertising is wired.
- `Sources/HailCore/Replies/ReplyPlaybackController+Segments.swift`: independently validated threshold setting
  and dictionary-preserving saves. No controller behavior changes.

P4b2 still owns fresh played-window/privacy/ambient wiring, the callback to `yieldPausedReply`, reply-specific
mask release, capability-gated transport and advertising, admitted-request observation and bulk Replay integration.
P5 owns the notice and Station tools UI. P4b1 does not open a detector window on its own.

## P4b1 inert onset detector

All parameters are **v1, pending Mick**: pause 1.5 s (0.1–10), sustained onset 300 ms (50 ms–2 s), absolute
threshold −35 dBFS (−60…−15), calibrated-floor margin +6 dB, floor calibration 200 ms, and no-admitted-request
observation N = 5 s. The threshold falls back independently, including nonfinite values. Saves merge all three
validated settings into the existing defaults dictionary, preserving other keys.

`EchoMaskedCapture.start()` calls `observeSegmentOnset` immediately before `silenceIfMasking` on each existing
capture PCM buffer. Until `configureSegmentOnset(input:onOnset:)` is called there is no analysis. The caller must
supply current ambient/privacy flags and the current played P4a window on **each buffer**, and call
`segmentOnsetGate.closeWindow()` when the window closes (even without further capture). `stopSegmentOnset()`
removes the opt-in tap and clears detector state. This slice adds no such app/controller wiring.

Order: played window opens → configured guard echo tail expires → 200 ms of measured floor PCM → sustained
onset. Tail samples never enter calibration, including in buffers crossing the tail boundary. Calibration measures
mean normalized PCM power; RMS dBFS is 10 log10(power), over all channels. Calibration cannot fire an onset.
After calibration, each analysed buffer portion must meet **both** the absolute threshold and floor +6 dB for
at least `sustainedOnset`; a below-gate buffer, missing capture or invalid PCM breaks sustain. A steady −30 dBFS
floor therefore does not fire, but a sustained rise to −24 can. A window shorter than tail + calibration + onset
cannot fire. This is an energy gate for any sufficiently loud sound, not speaker recognition or a speech classifier.

The signal is a no-argument callback, once per window. Detection keeps timing, energy and duration scalars only;
closing/replacing the window discards them. No PCM reference, pre-roll, transcript or identity is retained. Choice B
still drops onset audio: the existing mask remains raised across the window; P4b1 never releases it or calls yield.

Diagnostics expose only two counters and two five-bucket count histograms (analysed post-calibration level and
completed calibrated floor): <−60, [−60,−45), [−45,−35), [−35,−25), [−25,0] dBFS. Silence is in the first bucket.
Internal pending deadlines contain only clock instants, separately from disposable detection state. With the
injected clock, diagnostics reads, analysis and `ambientRequestAdmitted()` expire deadlines at >=5 s exactly once,
including after window close. P4b2 must call the admission hook for an actual admitted ambient request; one such
request satisfies all earlier onsets still within their own deadlines. Earlier/late requests cannot erase an expired
outcome. Nothing is logged or persisted by this detector.

## Implemented behavior and limits

The FIFO schedules through one `segmentEnd`, then withholds every following frame until that marker's
`.dataPlayedBack` callback and the configured pause complete. New frames retain normal queueing. The reply stays
output-busy, preserving the existing echo mask across the window. Separate user pause, capture suppression and
interruption idle holds remain authoritative. Stop/failure/generation replacement invalidate timers and callbacks;
late frames of retired replies cannot restart them. Muting keeps its existing whole-reply silent playback behavior;
headset stop-and-mute retires playback. This slice does not introduce a separate dismiss or privacy UI action.
Bulk replay retains its prior behavior until P4b2 integration.

`ReplySegmentSettings` reads/saves one UserDefaults dictionary (`hailing-station.reply-segments.v1`). Defaults
**v1, pending Mick**: pause 1.5 seconds (0.1–10), sustained onset 0.3 seconds (0.05–2), and threshold −35 dBFS
(−60…−15). Each invalid/nonfinite value falls back independently. Settings are read at controller
creation; callers may assign and save a new validated value. A window uses the pause value when it opens.
There is no spoken "go on" path.

The callable `yieldPausedReply(ambientListening:privacyOn:)` requires a played window, current ambient-on and
privacy-off flags. It stops only that descriptor on that endpoint, leaves other queued replies, records a bounded
`lastSegmentYield` and returns endpoint/reply UUID/played-marker count. Those identifiers stay in memory, never
logs or defaults. It sends nothing and accepts no mic PCM. P4b must supply fresh flags and connection identity,
release the mask promptly and send only to a ready host advertising `reply_segments`.

Onset audio choice B: lose the triggering onset. No mic pre-roll is retained, logged, written or replayed; with no
yield there is likewise no pre-roll to discard. Subsequent audio uses normal ambient capture after P4b releases
the mask, subject to its existing privacy gate. Live onset/replay/privacy integration remains deferred.

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

Deferred expectations (actual missing P4b2 work, not passing tests): live caller wiring and current connection
identity, capability-gated `reply_yield` transmission, prompt reply-specific mask release, subsequent audio through
the normal ambient path, live admitted-request observation, hello advertising, segmented bulk replay, and end-to-end
dismiss/privacy wiring. P4b1 synthetic detector coverage and verification are recorded below. P5 must test the
notice and saved Station tools setting.

## P4a VM verification commands

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

P4a final-source results on the Dev Work VM (historical baseline):

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

## P4b1 synthetic verification

Final source on the offline Dev Work VM, based on P4a `b716675c973ab4e267e55263b8637c206794a3ee`.
The same `/tmp/hs932-p4-tools/swift` wrapper above supplies `taskpolicy -b`, `-j 4`, one compiler worker,
no automatic dependency resolution, and the supplied Testing framework/plugin/rpath flags. Every phase uses
`phase.py` above (590-second deadline, owned-tree kill traps). The loaded repetition script starts exactly four
background `taskpolicy -b yes` workers; EXIT/INT/TERM traps kill and wait for those owned PIDs. All phases passed
within the deadline. No install, upload, simulator, physical audio, network or other-clone work was performed.

Exact final verification commands:

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat-b1.sh normal
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat-b1.sh loaded
# repeat-b1.sh runs the following five times per phase, with the owned load workers only in loaded mode:
/tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.ReplySegment(Onset|Settings)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.(Echo|Capture|Ambient|ReplySegment|Reply|Playback|Privacy|Diagnostic)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
git diff --check
```

Results:

- Both final-source builds passed with warnings as errors (1.89 s production, 2.66 s build-tests).
- Focused filter: 24 test functions in three suites, 48 case invocations including parameterized cases per run;
  five/five normal and five/five loaded repetitions passed (240 function executions, 480 case invocations).
  Final normal runs took 0.093–0.096 s of test execution; loaded runs took 0.097–0.104 s.
- Exact requested serial regression: 287 tests in 57 suites passed, 24.818 s. #955's daemon diagnostic test was
  excluded in every test command and is outside both HailCore filters.
- `ReplySegmentOnsetTests`: synthetic RMS levels at/above the threshold; independent absolute/margin checks;
  short/interrupted bursts; loud TV floor and exact +6 dB rise; tail/calibration exclusion including a mixed
  boundary buffer; configured guard tail; exact minimum and insufficient windows; duplicate/missing/invalid
  capture; fresh ambient/privacy/window refusal; close/reopen resets floor/sustain and releases the PCM reference.
- `ReplySegmentOnsetDiagnosticsTests`: all five histogram buckets and boundary counts; floor/level integration;
  exact five-second injected-clock expiry after close; timely, prior and late admissions; independent successive
  deadlines; the existing capture stream observes pre-mask PCM, signals once and still forwards zeroed audio.
- `ReplySegmentSettingsTests`: bounds/nonfinite and malformed-value fallback, independent settings, preserving
  pause/onset when saving a threshold, dictionary round trip and preserving an unknown future key.
- Hand check against `.swiftlint.yml`: file/type/function length, line length, parameter count, complexity,
  nesting, identifiers, force operations and opted-in whitespace rules. No new waiver. The guard retains its
  pre-existing `file_length` waiver (597 lines); the settings/segments file has 149 lines. The largest changed
  type is the guard (145 code lines excluding comments/blanks); added function bodies are below 40 code lines,
  parameters <=5, and changed noncomment lines <=120 columns. Test files are <=140 lines. SwiftLint is absent,
  so this is a manual check, not a claimed lint invocation. `git diff --check` passed.
- The checker's exact exclusions and rename handling classify exactly two production files, no renames and no
  `SECURITY_PATHS` matches. Tests/docs are excluded. No PR, issue-state, remote review or GitHub checks were run.

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
