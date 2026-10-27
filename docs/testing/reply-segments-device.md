# Reply segments device wiring (#932 P4a/P4b1/P4b2)

This is offline, synthetic macOS VM evidence, using fake players and an injected clock for controller tests.
It is not an iOS app build, simulator playback, a live captured-output round trip, acoustic echo testing,
physical-device proof, or a TestFlight delivery. P5 and host/device validation remain open; this does not close #932.

## P4b2 current implementation

P4b2 is live in device code with a P3 host: hello advertises `ReplySegments.capability` beside `HeardTurns.capability`.
The historical P4a/P4b1 records below describe their inert foundations at those revisions.

Exactly four production files change from `af3ea8212a61bac32cad745d54c4a60212f0df1b`:

- `HostConnectionStore.swift`: one-time pre-mask bridge, fresh authorization on every buffer and onset,
  played-window observation/closure, local yield and ordered safe tail handoff, owned-connection send and
  content-free admission from the existing `ambient_heard` dispatch.
- `HostConnection+Protocol.swift`: hello capability and actor-side ready/capability/generation/endpoint checks.
  Host-originated `reply_yield` remains an unexpected control frame.
- `ReplyPlaybackController+Presentation.swift`: marker-bearing bulk Replay uses the segment FIFO; other queued
  replies and late-frame refusal survive. Unsegmented Replay retains its existing behavior.
- `RootView.swift`: thin installation using current ambient state, selected endpoint, current duck-mode privacy
  and pending privacy-on request. P5 can read existing observable `lastSegmentYield`; no notice UI is added.

The capture forwarder (a detached task, not the real-time engine callback) synchronizes with the main actor
for current state and the onset handler. Installation happens once before capture, and these callbacks never
synchronously configure or stop the tap. A stale/closed window or fresh ambient-off/privacy-on state refuses yield.
On success, reply audibility is synchronized after local cancellation/drain. The existing safe tail API runs
**before** analysis closes. Its false result retains the normal tail; an audible queued replacement keeps its mask.
The guard implementation is unchanged. The tap-capture mask and tail remain authoritative. No audio bypass,
PCM retention or pre-roll is added; triggering onset may be lost (choice B).

The yielded endpoint and captured socket generation gate transmission in both the store and actor. A missing,
older, non-ready, replaced or reconnected destination receives nothing; other endpoints are never fallback
destinations. Local stop stands even without transmission. Admission passes only the current endpoint identity
to the gate, only for the yielded connection generation; transcripts remain in the existing conversation path.

P4b2 tests extend existing files only: actual detached pre-mask onset, two played-marker count, only-reply local
stop and queued other-endpoint survival; capable/older/negotiating/disconnected transport and stale-generation
refusal; privacy/ambient changes between capture authorization and signal; closed-window refusal; safe tail API
success before close, active tap/tap-tail preservation and unsafe normal-tail fallback; hello advertising and
host-originated-yield refusal; timely/other-endpoint/late ambient admission; marker-aware bulk Replay.

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
removes the opt-in tap and clears detector state. Shutdown/replacement and analysis/callbacks share a lock;
a generation token rejects an observation that read authorization before stop, including across reconfiguration.
After stop returns no old observation can analyse or call back. Stop waits for a callback already running;
callbacks must not synchronously configure or stop the tap. This slice adds no such app/controller wiring.

Order: played window opens → configured guard echo tail expires → 200 ms of measured floor PCM → sustained
onset. Tail samples never enter calibration, including in buffers crossing the tail boundary. Calibration measures
mean normalized PCM power; RMS dBFS is 10 log10(power), over all channels. Calibration cannot fire an onset.
Calibration and sustained progress use integer sample counts at the buffer's sample rate, with one completion
rule (`count >= ceil(duration * rate)`). A rate change discards detection state and requires fresh calibration.
After calibration, RMS intervals are at most **10 ms** (shorter at buffer edges). Each interval must meet **both**
the absolute threshold and floor +6 dB; only consecutive qualifying samples count toward `sustainedOnset`.
Any non-qualifying interval, missing capture or invalid PCM breaks sustain. A steady −30 dBFS
floor therefore does not fire, but a sustained rise to −24 can. A window shorter than tail + calibration + onset
cannot fire. This is an energy gate for any sufficiently loud sound, not speaker recognition or a speech classifier.

The signal is a no-argument callback, once per window. Detection keeps timing, energy and duration scalars only;
closing/replacing the window discards them. No PCM reference, pre-roll, transcript or identity is retained. Choice B
still drops onset audio: the existing mask remains raised across the window; P4b1 never releases it or calls yield.

Diagnostics expose only two counters and two five-bucket count histograms (one post-calibration level per
analysed sub-interval and one completed calibrated floor): <−60, [−60,−45), [−45,−35), [−35,−25), [−25,0] dBFS. Silence is in the first bucket.
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

## P4b1 fix round 1 (offline bundle r2)

Starts at `52f06a77f595ca4bae7165ec6f2bcd80fed22599` on `codex/932-p4b1-gate`. Merge
`809d529d895deb6a293cd4c045054f519e4371a1` includes P4a fix
`baf7bfc2f43005b8de4645e5f96ddf72de030931`. The settings conflict keeps strict numeric reads for all three
keys (booleans/strings rejected), independent fallback, and saves preserving every dictionary key. Both historical
test records above were retained when resolving the documentation conflict. The settings regressions now also
exercise malformed and persisted Boolean threshold values with valid companion settings.

The three P2 findings are fixed in `AmbientReplyEchoGuard.swift`:

- Integer calibration/onset sample counts replace accumulated floating seconds. Calibration uses a single
  integer completion rule and sample-weighted energy; it cannot reset on a zero-length remainder and ingest onset
  into the floor. Rate changes require a fresh floor. `ReplySegmentOnsetCadenceTests` covers the Cartesian product
  of 16 kHz, 44.1 kHz and 48 kHz with 160, 256, 512, 1024 and 4800 frames (15 cadences), crossing calibration
  inside a buffer where necessary. Each cadence asserts onset at the required sample count, exactly one floor
  measurement in the original quiet-floor bucket, and one onset even after further loud buffers.
- Tap generations, analysis and callbacks synchronize with stop/reconfigure under the same lock. The test hook
  pauses after authorization while privacy turns on, ambient turns off, the window closes and stop returns.
  Resuming cannot analyse or signal, including after replacing the tap. Another interleaving test verifies that
  stop waits until an already-running callback completes.
- Post-calibration RMS uses **10 ms maximum sub-intervals**, shorter at buffer edges. Each interval must pass
  both threshold and floor +6 dB; non-qualifying/invalid intervals reset consecutive sample progress. Tests reject
  a 1 ms full-scale click in a 300 ms buffer, accept 300 ms continuous speech-level signal, and reject a single
  buffer containing 150 ms speech + 20 ms silence + 150 ms speech. Histogram expectations count sub-intervals.

P4b1 remains inert: no yield, mask release, transport, advertising, app/controller wiring or delivery change.
Evidence is synthetic macOS VM PCM/fake-player evidence only, with no network, other-clone access, simulator,
physical-device audio, upload or installed-build change. No PR or independent review was created or claimed.

Every Swift command uses the existing wrapper documented above (`taskpolicy -b`, `-j 4`, one compiler worker
per target, offline resolution and all supplied Testing framework/plugin/rpath flags). Each serial phase uses
`phase.py` with a 590-second deadline and owned-process-tree kill trap. The loaded script starts exactly four
owned background `taskpolicy -b yes` workers and kills/waits for them in EXIT/INT/TERM traps.

Exact final-source verification commands:

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat-b1-r2-final.sh normal
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat-b1-r2-final.sh loaded
# Each repetition script runs this five times; loaded mode owns four yes workers:
/tmp/hs932-p4-tools/swift test --skip-build --no-parallel --filter 'HailCoreTests\.ReplySegment' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.(Echo|Capture|Ambient|ReplySegment|Reply|Playback|Privacy|Diagnostic)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
git diff --check
```

Results:

- Both warnings-as-errors builds passed: production 5.86 s; build-tests 63.19 s, then 9.61 s after test-helper cleanup.
- Combined P4a/P4b1 segment filter: 51 test functions in nine suites, 93 case invocations per run. All five
  normal and all five loaded runs passed (510 function executions, 930 case invocations). Normal execution times:
  0.743/0.768/0.644/0.895/0.434 s; loaded: 0.568/0.334/0.736/0.712/0.618 s. All phases met the deadline.
- Exact requested serial regression passed once: 296 tests in 59 suites, 24.581 s. The known #955 daemon
  diagnostic test was explicitly excluded in every test command and is outside the HailCore filters.
- Before the test-helper cleanup, another five normal/five loaded runs passed with the same counts, and the
  requested serial regression passed in 23.562 s. Total across both verification rounds: 20 segment runs
  (1,020 function executions, 1,860 case invocations) and two 296-test regression runs.
- `git diff --check` passed. Changed Swift lines fit 120 columns; no new lint waiver. SwiftLint is unavailable.
- Final verification logs are host-local `/tmp/hs932-p4b1-r2-*.log`, outside version control.

## Host build and physical follow-up

A full-Xcode host must build the iOS/iPadOS simulator app and macOS app/package with warnings as errors, confirming
Observation state, AVAudioPlayerNode completion ordering, actor isolation, session routing and the saved-settings
API. Once P4b/P5 land together, verify segmented Replay, capability negotiation with both old/new hosts,
per-connection yield routing, prompt mask release, echo-tail false positives, muted/stop/dismiss/privacy behavior,
ambient on/off transitions and the paused notice/Station tools setting. On real speaker/headphone routes confirm
that the window begins after sound finishes, lasts the configured interval, does not count as a stall/gap, and
that any-voice onset works without sending reply echo or private audio. No build upload/installation is in scope.


## P4a fix round 2 (#956, offline bundle r3)

Starts at `baf7bfc2f43005b8de4645e5f96ddf72de030931` on `codex/932-p4-device`.
The settings reader now identifies Booleans only by
`CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()`. Every other NSNumber reaches the existing
independent bounds validation; the `objCType` rejection is removed so signed-char numeric values are accepted.
`numericRepresentationsAreAcceptedIndependently` injects NSNumber values built from Int8(1), Int16, Int,
Float and Double into each field, checking all ten field/type combinations with a valid companion.
Existing malformed-value tests still reject true/false NSNumber Booleans, strings, NSNull, arrays and dictionaries
independently; real UserDefaults Boolean round trips remain covered.

The existing wrappers above supply `taskpolicy -b`, `-j 4`, one compiler worker per target, offline resolution,
and every supplied Testing framework/plugin/rpath flag. Each serial phase has the 590-second deadline and
owned-process-tree kill trap. No load workers, network, other clones, simulator, physical audio or delivery were used.
Exact commands (each test iteration is a separate bounded phase):

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests -Xswiftc -warnings-as-errors
for iteration in 1 2 3; do
  python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
    --filter 'HailCoreTests\.ReplySegment' --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
done
git diff --check
```

Both warnings-as-errors builds passed (production 5.37 s; build-tests 59.20 s). The segment filter passed 3/3:
26 test functions in five suites, 39 case invocations per run (78 function executions, 117 case invocations total),
in 0.574/0.457/0.492 s. P4a has no onset detector suites; those belong to P4b1. `git diff --check` passed.
One production file changes, plus settings regressions and this record. Logs are host-local
`/tmp/hs932-p4a-r3-*.log`. No PR, independent review or GitHub checks were created or claimed.


## P4b1 carry-forward of P4a fix round 2 (offline bundle r3)

Starts at `e58bd6f7eb08783e4d0831af2a2498e6769d77c7` on `codex/932-p4b1-gate`.
`git merge --no-edit codex/932-p4-device` brought in P4a
`d7e8e2ccaca0b73a03b51c7017bfcc4716112bf9` without conflicts. All three saved fields use the same
CF-type-only Boolean check. The merge preserves threshold bounds, independent fallback, and dictionary-merging
saves that retain every existing key. The merge commit also includes the threshold numeric-type regression
and this evidence record.

The merged numeric tests cover Int8, Int16, Int, Float and Double for pause, sustained onset and threshold
(15 field/type combinations). The inherited malformed-value and persisted-Boolean tests check independent
fallback in all three fields, and `savingThresholdPreservesOtherSettingsAndUnknownKeys` checks save preservation.
P4b1 remains an inert detector; this fix adds no app/controller wiring or physical-device proof.

The same offline Swift wrapper and 590-second owned-process-tree kill trap documented above were used for
each serial phase, with `taskpolicy -b`, `-j 4`, one compiler worker per target and all supplied Testing flags.
No load workers, network, other clone, simulator, physical audio, upload or installed-build change was used.
Exact commands:

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests -Xswiftc -warnings-as-errors
for iteration in 1 2 3; do
  python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
    --filter 'HailCoreTests\.ReplySegment' --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
done
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.(Reply|Playback|PCM16|Playout|Segment|Echo|Capture|Ambient)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
git diff --check
```

Both warnings-as-errors builds passed (production 5.45 s; build-tests 60.46 s). Combined segment/onset filter:
53 test functions in nine suites, 95 case invocations per run; 3/3 passed in 0.816/0.910/0.831 s
(159 function executions, 285 case invocations total). The exact requested serial regression passed:
317 tests in 62 suites, 24.952 s. The #955 daemon diagnostic test was explicitly excluded in every command.
`git diff --check` passed. Logs are host-local `/tmp/hs932-p4b1-r3-*.log`.
Evidence is synthetic macOS VM evidence only; no PR, independent review or GitHub checks were created or claimed.


## P4b1 safe yield-tail API (#958, offline bundle r4)

Starts at `ebce4446ebbfbcb7b1d5cd27c7dff08b65979180` on `codex/932-p4b1-gate`.
`AmbientReplyEchoGuard.endReplyTailForYield() -> Bool` is a callable foundation for P4b2 immediately after
successful yield. No production caller is added. This round changes only `AmbientReplyEchoGuard.swift` among
production files; P4b1 still has two production files relative to its P4a base.

The no-argument API uses the gate's last analysed window and configured sustained onset. P4b2 must call it
before closing that onset window. Missing, closed or expired windows fail closed, as do an audible reply or
an absent reply quiet edge. The injected `ContinuousClock` instant must reach
`max(replyQuietAt, window.lowerBound + tail) + calibration + sustainedOnset`, where `replyQuietAt` already
includes the guard's tail. Each addition is a `Duration` advancement, and calibration is the same exact
200 ms constant used for the detector's sample counts; no wall-clock or floating-point duration sum is used.
Checking both starts prevents an old window or an old quiet edge from shortening the safe interval.

Success clears only the reply's `quietAt` and returns true; subsequent calls return false. `tapActive` and
`tapQuietAt` are never written. The next `setReplyAudible(true)` raises the reply mask synchronously as before.
The ordinary reply tail still expires naturally; this API retires its state after the longer safe interval.
There is no new logging, identity, PCM retention, yield, transport, advertising or app/controller wiring.

`ReplySegmentEchoTailYieldTests` adds seven test functions (16 case invocations): playback refusal; one
nanosecond before and exactly at the deadline for three tails × three configured onset durations; independent
quiet-edge/window-start checks; active tap and tap-tail preservation; next-reply re-masking and its own tail;
missing/closed/expired-window refusal; and repeated-call idempotence.

Every phase runs serially through the existing 590-second deadline/owned-process-tree kill trap. Every Swift
command uses the wrapper above (`taskpolicy -b`, `-j 4`, `-Xswiftc -j1`, offline resolution, and all supplied
Testing framework/plugin/rpath flags). No background load workers are added. Exact commands:

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests -Xswiftc -warnings-as-errors
for iteration in 1 2 3; do
  python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
    --filter 'HailCoreTests\.ReplySegment' --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
done
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.(Echo|Capture|Ambient|ReplySegment|TapCapture)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
git diff --check
```

Final-source results:

- Both warnings-as-errors builds passed: production 2.42 s; build-tests 8.13 s.
- Combined segment/onset filter passed 3/3: 60 test functions in 10 suites, 111 case invocations per run
  (180 function executions, 333 case invocations total), in 0.813/0.823/0.861 s.
- Exact requested serial regression passed once: 189 test functions in 38 suites, 23.214 s. The #955 daemon
  diagnostic test was explicitly excluded in every test command.
- `git diff --check` passed. Local classification using the checker's exact exclusions found one production file
  this round, two for cumulative P4b1, and no security-path matches. `rg` found only the API declaration under
  `Sources`, confirming no production caller. SwiftLint is unavailable; changed Swift lines were checked by hand.
- Logs are host-local `/tmp/hs932-p4b1-r4-*.log`, outside version control.

Evidence remains synthetic macOS VM evidence only. No network, other-clone access, simulator, physical-device
audio, install, upload, PR, independent review or GitHub check is performed or claimed.

## P4b2 offline VM verification

Base: `af3ea8212a61bac32cad745d54c4a60212f0df1b`. Every Swift command uses the existing
`/tmp/hs932-p4-tools/swift` wrapper documented above: `taskpolicy -b`, `-j 4`, one compiler worker
per target, offline resolution, and all supplied Testing framework/plugin/rpath flags. Every counted phase
runs serially through `phase.py` with a 590-second deadline and owned-process-tree termination traps.
The loaded script owns exactly four background `taskpolicy -b yes` workers and kills/waits for them
on EXIT/INT/TERM. No other clone is used.

Exact final verification commands:

```sh
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift build --build-tests -Xswiftc -warnings-as-errors
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat-b2.sh normal
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/repeat-b2.sh loaded
# Each repetition script runs this five times; loaded mode owns four yes workers:
/tmp/hs932-p4-tools/swift test --skip-build --no-parallel --filter 'HailCoreTests\.ReplySegment' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
python3 /tmp/hs932-p4-tools/phase.py /tmp/hs932-p4-tools/swift test --skip-build --no-parallel \
  --filter 'HailCoreTests\.(Reply|Playback|PCM16|Playout|Segment|Echo|Capture|Ambient|HostConnection|Privacy|Diagnostic|Heard)' \
  --skip 'HailDaemonKitTests.DiagnosticReplyComposition'
git diff --check
```

Final results:

- Both warnings-as-errors builds passed: production 6.66 s; build-tests 50.43 s, no compiler diagnostics.
- Segment filter: 69 test functions in 12 suites, 128 case invocations per run, including nine new test
  functions with 17 invocations. All five normal and all five loaded repetitions passed: 690 function
  executions / 1,280 case invocations across the counted ten runs. Normal test times:
  6.374/6.357/6.807/7.022/6.958 s; loaded: 5.364/5.376/4.911/4.573/5.111 s.
- Exact requested serial regression passed once: 424 test functions in 91 suites, 100.856 s.
  The known #955 daemon diagnostic test was explicitly excluded and is outside these HailCore filters.
- All phases finished below 590 seconds. Loaded workers exited through their cleanup trap.
- `git diff --check` passed. SwiftLint is unavailable; hand review checked file/type/function length,
  line length, parameter count, complexity, nesting and opted-in rules. No new waiver was added.
  RootView/presentation have 197/200 lines; their type/extension bodies have 134 and 102/73/16 code lines.
  The new wiring type has 75 code lines. Store/protocol retain their pre-existing file-length waivers;
  changed code fits 120 columns.
- Local classification uses the checker's exact exclusion tuples and `SECURITY_PATHS`: exactly four
  production files, no renames, no security-path matches. Tests extend existing files only.
- Logs are host-local `/tmp/hs932-p4b2-*.log`, outside version control. No network, PR, independent review,
  GitHub check, simulator, physical audio, signing, upload or installed-build change is performed or claimed.

A full-Xcode host must build the iOS/iPadOS app (RootView is outside this VM's package build) and macOS app
with warnings as errors. Check the fresh SwiftUI selected-host binding, weak store capture, actor isolation,
background installation and capture-forwarder/main-actor synchronization. Confirm actual AVAudioPlayerNode
played-marker ordering, per-endpoint/generation sends against old/new hosts, normal versus safe tail handoff,
tap-mask preservation, ambient/privacy/selection/reconnect transitions, stop/dismiss/mute and segmented Replay.
Physical speaker/headphone tests must check onset/echo behavior, ordinary subsequent ambient admission and
absence of private/reply-echo audio. P5 still owns the paused notice and Station tools UI. Nothing here is
a live captured-output round trip, acoustic validation or TestFlight delivery.
