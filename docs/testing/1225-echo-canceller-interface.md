# Echo-canceller interface

Part of #1225, slice S1c. This is a HailCore contract for a future capture factory.
The application capture path has no call site in this slice.

## Selecting a canceller

Start each capture generation by resolving its platform and qualified output class with
`EchoCancellerRegistry`. Configuration maps that pair to a stable identifier. Each
registered factory makes a fresh instance. Registration and a configuration change
are sufficient to substitute a different frame processor.

| Qualified output | Mac or iPad app on Mac | iPhone or iPad |
| --- | --- | --- |
| Room speaker, room hands-free or other room output | `aec3` (reserved, currently resolves to mask) | `apple-voice-processing` |
| Verified private headphones | `none` | `none` |
| Unknown | Mask | Mask |

Qualification concerns actual output. A USB input or a Bluetooth profile alone cannot verify private listening.
The registry masks unknown output before configuration lookup, even with an explicit mapping to `none`.
A missing route entry or factory also resolves to an explicit mask decision. The future caller must send silence
for the affected interval and retain timing. Privacy, tap-to-talk and explicit user masks still apply.

## Processing contract

- **Frame processors** receive interleaved signed 16-bit PCM with a per-channel sample rate and channel count.
  Each frame starts at `startSample` on the capture run's sample clock. The exclusive end advances by the
  interleaved sample count divided by the channel count. The caller maps actual reference playout time onto
  this same clock. Each result pairs the cleaned frame with
  its health and optional estimated delay in milliseconds and whole-decibel ERLE. Implementations can reject
  unsupported formats and frame sizes. Passthrough validates the format and complete channel groups, returns
  the original samples, and leaves acoustic estimates unavailable.
- **Timing.** Configure once per run and read the constant, nonnegative `outputLatencySamples` in
  per-channel samples. Passthrough and synchronous processors declare zero. Pair render and capture on
  the shared sample clock across callback boundaries. An uncovered reference position is silence.
- **Worker deadline.** Each nonblocking `process(capture:)` submits the new PCM and returns the output due
  on that call. For input interval `[s, e)` and latency `L`, output covers `[s − L, e − L)` with the same
  format and sample count. For example, with two samples of latency, submitting A at 30 produces a masked
  warm-up frame at 28. A can finish after that call. Submitting B at 32 then returns A's cleaned samples
  at 30. If A is still unfinished, return a masked placeholder at 30 and discard any subsequent A completion.
- **Mask alignment in S3b.** Delay the stream and its capture-time mask decisions by the same `L`. Match each
  returned frame with the saved decisions for its source interval, then apply its output diagnostics and any
  current privacy veto. A gap, overlap, reconfiguration or reset flushes pending intervals. Mark those
  intervals masked in the delayed stream, discard stale completions even when positions repeat, and warm up
  on the new timeline. The discontinuous input itself must be masked when due.
- **Graph processors** describe required wiring. The Apple descriptor needs input voice processing enabled
  and replies rendered through the same running capture engine. It stays unconfigured until the graph owner
  reports the requirement met and reports failure if that assurance is revoked. It receives no frames.
- **Health and lifetime.** Serialize operations per run. Mask affected output after any error and while
  health is unconfigured, adapting, unavailable or failed. Reset discards run state. A graph confirmation is only a
  wiring observation. It does not measure acoustic cancellation.

## Verification

The deterministic suites cover identity, validation, content-free health, reset, route qualification,
implementation substitution, per-run isolation and graph-health transitions. The following regressions cover the reviewed contract:

| Review item | Test evidence |
| --- | --- |
| P1. Unknown output always masks | Explicit Mac mapping from unknown to `none` still produces the mask decision. |
| P2. Shared capture sample clock | A mono probe records two reference callbacks paired with differently sized capture intervals. Expected sample values include a gap filled with silence and one capture spanning both references. |
| P2. Capture continuity | Stereo positions advance per channel. Forward gaps and overlaps each mask one frame, then contiguous processing resumes. An unrepresentable interval end fails closed. |
| Constant output latency | Passthrough and the synchronous reference-pairing probe declare zero. The worker declares two per-channel samples (one stereo frame in this fixture). |
| Warm-up and successful completion | The first submission returns earlier silence with masking diagnostics. Completing A through its job handle before submitting B returns cleaned samples derived from A, at A's position. |
| Missed worker deadline | B returns masked silence at A's position. Completing A late is rejected. C returns B's own completed samples. |
| Flush and reuse | Reset, a forward gap and an overlap retire pending handles. The tests reuse sample positions and check both masked placeholders and recovery with fresh samples. |
| P3. Desktop identifier | A probe registered under the exact reserved identifier resolves for every room class on both Mac runtimes. The separate absent-registration check still requires masking. |

All inputs are synthetic. Physical echo reduction, residual self-voice, owner preservation and talk-over
require S3b wiring and device measurements.

Each build, test and lint phase waits for the host slot followed by the voice-quiet gate, under background
task policy with the Xcode developer directory selected. Build and test concurrency is limited to two jobs.
SwiftPM uses the slice's scratch build directory. The Mac compile uses scratch DerivedData.

| Round C command | Result |
| --- | --- |
| `swift build --build-tests -j 2` | Passed. The linker emitted scratch module-cache warnings. |
| `swift test --skip-build --no-parallel -j 2 --filter EchoCanceller` | All 16 tests in four suites passed, including both cases of the gap/overlap test. |
| `swift test --skip-build --parallel --num-workers 2 -j 2 --filter EchoCanceller` | Three runs. All 16 tests passed in each run. |
| `taskpolicy -b scripts/verify.sh mac` | Hail-macOS compile passed. |
| `swiftlint lint --strict --no-cache` on all six changed Swift files | Zero violations. |

The protocol and registry diff against the base contains one case-insensitive backend-name match,
the configuration string `"aec3"`. The PR-shape exclusions leave three production files.
