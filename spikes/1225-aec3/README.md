# AEC3 feasibility lab — issue #1225

Part of #1225. This is an offline lab harness, with no production effect. It builds the
standalone AudioProcessing module and exercises AEC3 against locally synthesized
fixtures. No audio devices, application integration, installs, signing identities, device execution
or TestFlight delivery are involved.

## Reproduce on the main Mac

Requirements: Apple silicon macOS, full Xcode, Python 3 (standard library only), `curl`,
`shasum`, `tar`, `unzip`, and the already available macOS Samantha and Daniel voices. Do
not download voices as part of this experiment. Everything including build tools is
local to `.work/`; no package manager or install step.

From the repository root, set `VOICE_QUIET` to the owner-provided quiet-gap script, then
run these commands sequentially:

```sh
export VOICE_QUIET=/absolute/path/to/voice-quiet.sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p spikes/1225-aec3/.work
spikes/1225-aec3/build.sh macos > spikes/1225-aec3/.work/macos-build.log 2>&1
spikes/1225-aec3/build.sh ios > spikes/1225-aec3/.work/ios-build.log 2>&1
python3 spikes/1225-aec3/make_fixtures.py generate
python3 spikes/1225-aec3/make_fixtures.py measure --label run1
python3 spikes/1225-aec3/make_fixtures.py measure --label run2
```

Each build is split into tool bootstrap (if needed), compilation batches of at most 150
object targets, and archiving/linking. Every phase runs the quiet gate before launching
its own command with `taskpolicy -b`, a 14-minute phase deadline and an exclusive lab
lock. Timeout or interruption terminates only that command's newly created process
group. TERM gives Ninja time to forward termination to its own compiler groups; a
two-second grace period precedes KILL of the phase group. Other direct children inherit
the phase group. Builds use Ninja `-j 2`; tool bootstrap is serial with its final
rebuild also capped at two jobs. Completed objects stay in `.work/`; after an
interrupted build with unchanged sources, SDK and flags, `build.sh macos --resume` (or
`ios`) plans only missing objects. For a link-only retry with complete, unchanged
libraries, use `build.sh macos --link-only` (or `ios`). A normal invocation starts from
verified sources and a fresh target build directory. Never alter scheduling or terminate
processes that the lab did not start. The quiet gate's waiting time precedes the phase
deadline. A hard kill of the supervisor can leave `.work/phase.lock`; inspect the lab's
own job before manually removing that empty directory. No VM or remote machine is
involved.

`build.sh` downloads only the pinned artifacts below (and checks all hashes on every
invocation), prevents Meson dependency downloads, writes the iOS SDK cross file into
`.work/ios-arm64.ini`, and builds static release libraries with `-Os`, no debug
assertions, function/data sections and arm64 NEON. Deployment targets: macOS 13.0 and
iOS device 16.0. Artifacts and size reports are in `.work/artifacts/{macos,ios}/`. Each
phase independently links both probe variants twice, dead-strips and strips them. Static
archive sizes are read twice from one library build per target; these are repeated size
reads, not independent rebuilds. Only the probe symbol is exported, enabling
dead-stripping of other symbols. The exported probe creates APM, disables
NS/AGC/high-pass, enables AEC3, and calls `ProcessReverseStream` and `ProcessStream`.
The Apple link explicitly adds CoreFoundation for WebRTC logging; no upstream source
patch is needed. Both variants have the same fixed `@rpath` install name and export only
`_aec3_probe`. The baseline exports the same signature without APM. This measures the
APM dependency reachable through that API, including any runtime-configurable code the
linker retains, rather than assuming disabled features disappear. It is a stripped dylib
size proxy, not an application archive/download size. The iOS binary is cross-linked
only, never run.

For a custom mono PCM16 WAV pair at 16 or 48 kHz, with matching lengths in whole 10 ms
frames:

```sh
python3 spikes/1225-aec3/make_fixtures.py phase -- \
  spikes/1225-aec3/.work/artifacts/macos/aec3_lab \
  render.wav capture.wav spikes/1225-aec3/.work/out.wav \
  --near near.wav --echo 3:7.5 --double 8:9 --stop 13.12:14.1
```

Repeat `--echo`, `--double` and `--stop` for additional windows, using the fixture
manifest's actual boundaries. Optional `--ns` and `--agc2` enable those processors (AGC2
uses adaptive digital gain); all reported measurements leave them off. The CLI has no
network or device APIs; the `phase` launcher supplies its load/voice guard.

## Pins and licences

| Artifact | Version | SHA-256 |
| --- | --- | --- |
| webrtc-audio-processing | 2.1 | `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe` |
| abseil-cpp | 20240722.0 | `f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3` |
| Meson abseil wrap overlay | 20240722.0-3 | `12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b` |
| Meson source | 1.8.3 | `f118aa910fc0a137cc2dd0122232dbf82153d9a12fb5b0f5bb64896f6a157abf` |
| Ninja source | 1.13.1 | `f0055ad0369bf2e372955ba55128d000cfcc21777057806015b45e4accbebf23` |

Source URLs are recorded literally in `build.sh`. The inherited survey selected 2.1 as
the latest known freedesktop 2.x release. No release-index query was made in this run
because network access is restricted to pinned downloads; latest-at-run-time status is
therefore unverified.

webrtc-audio-processing uses BSD-3-Clause (`COPYING`), with WebRTC's additional patent
grant (`webrtc/PATENTS`, including its patent-litigation termination clause). Abseil
uses Apache-2.0. Meson uses Apache-2.0; Ninja uses Apache-2.0. Retain upstream notices
and review redistribution obligations before shipping any dependency. No third-party
sources or generated audio are committed here.

## Measurement method

Speech is synthesized at **16 kHz**. The 48 kHz fixtures use **3× linear interpolation
of the same verified 16 kHz speech**, followed by room/noise construction at 48 kHz.
They exercise actual 48 kHz APM frames but do **not** validate native wideband speech
quality. Native 48 kHz `say` generation stalled twice on “Cancel” for 120 seconds,
including after moving all synthesis ahead of CPU work; its own client was bounded and
the shared speech service was left untouched. A 16 kHz suffix also exceeded the original
45-second limit; it subsequently completed within the 120-second bound. Cached completed
16 kHz phrases avoid further service retries for this run.

The fixtures use Samantha for two 26-second replies and Daniel for near-end “stop” at 8
s and a short request at 17 s. Both replies also contain their own isolated “stop” at 13
s and “cancel” at 20 s, allowing a known word window without a speech recognizer.
Completed TTS phrases are cached by text, voice, rate and speech speed, with validated
WAV format and SHA-256; failed/partial synthesis is not cached. Each new `say` call has
a 120-second timeout within the overall phase deadline. A failed call stops the phase
rather than retrying or resetting the speech service. Re-running generation reuses
completed phrases. All synthesis/cache warming precedes room convolution and mixing,
keeping speech-service requests close to the quiet gap rather than interleaving them
with long CPU work. Voice assets are host-provided, so regenerating on a different OS
can change speech; the input hashes bind both measurement passes to exactly the same
fixtures. The manifest records actual synthesized lengths, speech slots, metric
boundaries, room taps and fixture hashes. Generation checks overlap between near-end
speech and delayed render speech.

At both 16 and 48 kHz, capture is render convolved with a deterministic direct path plus
20 signed taps with a 55 ms exponential amplitude envelope (cut off by 243 ms), passed
through mild `tanh(1.15*x)/1.15`, scaled by 0.55, bulk-delayed 40/120/250 ms, then mixed
with half-scale clean near-end (gain 0.5, preserving PCM headroom) and uniform noise of
peak 0.0005. The near-end ground truth is saved separately. Generation rejects capture
clipping before PCM conversion. All fixture audio, JSON and results stay under the
gitignored `.work/`. This is synthetic speech and a synthetic room, not owner audio.

AEC3 uses its internal delay estimator; no ground-truth delay hint is passed. NS, AGC1/2
and high-pass are disabled. Per-frame thread CPU time brackets both reverse and capture
processing, including their first-frame initialization; file I/O, statistics and metric
analysis are excluded. Processing is unpaced and offline, rather than driven by real
audio callbacks. RTF is mean CPU time / 10 ms. Percentiles are nearest-rank over all
frames, including silence.

ERLE here is the measured full-output energy ratio `10 log10(sum(capture²) /
sum(output²))` in echo-only windows, after 3 seconds of initial adaptation and outside
near-end speech. It includes residual echo suppression and the noise floor, not just the
linear filter's internal ERLE. The self-stop metric uses the isolated render word's
delayed arrival through its room tail, capped before the next render speech slot.
Near-end SNR is `10 log10(sum(clean²) / sum((out-clean)²))`; correlation is Pearson
correlation. Both unaligned and alignment-compensated metrics are reported, with no gain
fitting. Alignment searches 0–20 ms for maximum correlation across the known double-talk
windows, so it is an optimistic timing correction, not a separately measured device
latency.

## Results

Machine: the owner's main Apple M4 Max host, arm64, macOS 15.8.1 (24H32), Xcode 26.3
(17C529), macOS and iPhoneOS SDKs 26.2, Python 3.14.7, system Bash 3.2.57. Work began on
2026-11-12. CPU measurements use `taskpolicy -b` on this host as a conservative desktop
proxy; they are **not phone CPU numbers**. No VM, simulator or physical device was used.

Build/link feasibility is demonstrated on both Apple targets. The baseline has strong
echo-energy suppression and a small linked delta, but **poor near-end preservation at
this one synthetic mix level**. Even after timing alignment, aggregate double-talk
correlation is 0.5569–0.7857 and SNR is 1.53–4.11 dB. The isolated near-end stop loses
7.41–39.60 dB of energy, with only 0.02–1.54 dB SNR against clean speech. Echo
suppression alone therefore does not establish usable stop/barge-in behavior. No
near-to-echo level or AEC3 tuning sweep was performed.

All 12 output WAVs matched bit-for-bit between the two passes. CPU means varied by up to
15.36%; use the measured range rather than claiming tightly repeatable timing. The worst
observed frame was 2.348 ms on this host. These are desktop proxy results, not phone
performance or callback-deadline proof.

### Binary size

All values are bytes; link columns are independent pass 1 / pass 2. Static sizes were
read twice from one compile per target, and matched. The inventory includes Meson
convenience archives; its sum is an artifact inventory, not an application size. Only
the linked delta measures reachable linked code.

| Target | Main APM archive | All archive files | Baseline dylib | AEC3 dylib | Linked delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| macos arm64 | 3,321,240 | 5,729,456 | 16,784 / 16,784 | 421,904 / 421,904 | 405,120 / 405,120 |
| ios arm64 | 3,233,024 | 5,553,960 | 32,888 / 32,888 | 434,536 / 434,536 | 401,648 / 401,648 |

Each static archive (bytes):

| Archive | macOS | iOS |
| --- | ---: | ---: |
| `libabsl_base.a` | 76,576 | 77,112 |
| `libabsl_container.a` | 23,304 | 23,448 |
| `libabsl_crc.a` | 142,048 | 48,080 |
| `libabsl_debugging.a` | 90,192 | 92,384 |
| `libabsl_flags.a` | 360,104 | 360,976 |
| `libabsl_hash.a` | 8,040 | 8,048 |
| `libabsl_log.a` | 174,632 | 175,896 |
| `libabsl_numeric.a` | 15,456 | 15,456 |
| `libabsl_profiling.a` | 5,008 | 5,024 |
| `libabsl_random.a` | 52,520 | 52,736 |
| `libabsl_status.a` | 60,680 | 60,808 |
| `libabsl_strings.a` | 443,496 | 444,424 |
| `libabsl_synchronization.a` | 99,016 | 99,880 |
| `libabsl_time.a` | 261,096 | 261,096 |
| `libabsl_types.a` | 2,320 | 2,320 |
| `libcommon_audio.a` | 185,328 | 185,320 |
| `liblibapi.a` | 97,472 | 97,560 |
| `liblibbase.a` | 225,576 | 225,008 |
| `liblibfft.a` | 6,128 | 6,128 |
| `liblibpffft.a` | 19,880 | 19,880 |
| `liblibrnnoise.a` | 5,864 | 5,864 |
| `libsystem_wrappers.a` | 53,480 | 53,488 |
| `libwebrtc-audio-processing-2.a` | 3,321,240 | 3,233,024 |

### CPU per 10 ms frame

Microseconds of thread CPU for both render and capture processing. Each case has 2,600
frames. Case names identify reply, sample rate, and bulk delay. Means, maxima and RTF
show pass 1 / pass 2; p50/p95 are ranges across those passes. These are
background-scheduled **desktop proxy** measurements.

| Case | Mean µs (1 / 2) | p50 µs | p95 µs | Max µs (1 / 2) | RTF (1 / 2) |
| --- | ---: | ---: | ---: | ---: | ---: |
| r1-16000-d40 | 417.92 / 406.50 | 358.71–381.42 | 805.96–809.21 | 997.54 / 1003.88 | 0.04179 / 0.04065 |
| r1-16000-d120 | 371.70 / 433.53 | 327.79–398.58 | 742.58–832.62 | 977.71 / 1089.08 | 0.03717 / 0.04335 |
| r1-16000-d250 | 410.66 / 465.16 | 374.96–434.67 | 795.46–843.46 | 979.83 / 1053.50 | 0.04107 / 0.04652 |
| r2-16000-d40 | 433.00 / 440.99 | 395.67–407.79 | 816.17–832.08 | 1037.25 / 1016.58 | 0.04330 / 0.04410 |
| r2-16000-d120 | 426.37 / 418.28 | 380.62–394.71 | 818.62–822.58 | 1011.54 / 1026.08 | 0.04264 / 0.04183 |
| r2-16000-d250 | 430.84 / 446.44 | 397.21–410.71 | 821.38–834.79 | 1016.75 / 1006.46 | 0.04308 / 0.04464 |
| r1-48000-d40 | 473.25 / 477.89 | 442.67–447.08 | 886.67–898.79 | 1104.00 / 1074.62 | 0.04732 / 0.04779 |
| r1-48000-d120 | 481.74 / 512.16 | 450.50–481.54 | 889.17–915.17 | 1155.83 / 1066.88 | 0.04817 / 0.05122 |
| r1-48000-d250 | 476.60 / 464.12 | 415.33–443.92 | 882.92–886.38 | 1073.83 / 1246.83 | 0.04766 / 0.04641 |
| r2-48000-d40 | 478.51 / 512.07 | 448.79–480.42 | 884.92–921.29 | 1082.67 / 1097.12 | 0.04785 / 0.05121 |
| r2-48000-d120 | 480.83 / 490.74 | 447.58–454.12 | 898.08–898.12 | 1103.21 / 1171.62 | 0.04808 / 0.04907 |
| r2-48000-d250 | 515.40 / 499.64 | 465.17–487.21 | 910.92–921.29 | 1093.33 / 2347.54 | 0.05154 / 0.04996 |

Case-by-case mean CPU changed by 0.98–15.36% between passes. Output WAV hashes matched
in all 12 cases across the two passes.

### Echo and near-end preservation

ERLE columns repeat pass 1 / pass 2. Near-end metrics below show pass 1; their pass-2
differences are checked below. Correlation and SNR use the clean half-scale near-end,
without output gain fitting. The compensated columns use the best 0–20 ms alignment; raw
columns keep the original clock.

| Case | ERLE dB (1 / 2) | Raw corr | Raw SNR dB | Aligned corr | Aligned SNR dB | Alignment ms | API delay ms (1 / 2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| r1-16000-d40 | 48.60 / 48.60 | 0.0367 | -1.72 | 0.7832 | 4.10 | 8.000 | 36 / 36 |
| r1-16000-d120 | 49.61 / 49.61 | 0.0515 | -1.53 | 0.7401 | 3.43 | 8.000 | 116 / 116 |
| r1-16000-d250 | 49.40 / 49.40 | 0.0725 | -0.53 | 0.5569 | 1.53 | 8.000 | 244 / 244 |
| r2-16000-d40 | 48.66 / 48.66 | 0.0026 | -1.80 | 0.7789 | 4.01 | 8.000 | 36 / 36 |
| r2-16000-d120 | 49.48 / 49.48 | 0.0378 | -1.66 | 0.7621 | 3.76 | 8.000 | 116 / 116 |
| r2-16000-d250 | 46.66 / 46.66 | 0.1251 | -0.53 | 0.5820 | 1.76 | 8.000 | 244 / 244 |
| r1-48000-d40 | 52.48 / 52.48 | -0.0760 | -1.89 | 0.7408 | 3.40 | 9.000 | 36 / 36 |
| r1-48000-d120 | 52.42 / 52.42 | -0.0280 | -1.75 | 0.7406 | 3.41 | 9.000 | 116 / 116 |
| r1-48000-d250 | 52.50 / 52.50 | -0.1195 | -1.15 | 0.5716 | 1.61 | 9.021 | 244 / 244 |
| r2-48000-d40 | 52.62 / 52.62 | -0.1341 | -2.29 | 0.7857 | 4.11 | 9.000 | 36 / 36 |
| r2-48000-d120 | 52.82 / 52.82 | -0.0798 | -2.10 | 0.7828 | 4.06 | 9.021 | 116 / 116 |
| r2-48000-d250 | 52.17 / 52.17 | -0.1059 | -1.23 | 0.5593 | 1.58 | 9.000 | 244 / 244 |
Pass-to-pass maximum aligned correlation difference: 0. Pass-to-pass maximum aligned
snr_db difference: 0. Pass-to-pass maximum aligned output_to_clean_db difference: 0.

Near-end stop, across all cases/passes: aligned correlation 0.2238–0.5628, SNR 0.02–1.54
dB, output-to-clean energy -39.60–-7.41 dB.

Short request, across all cases/passes: aligned correlation 0.5724–0.8129, SNR 1.63–4.67
dB, output-to-clean energy -6.85–-2.33 dB.

### Reply stop self-trigger proxy

These isolated-word windows contain no near-end speech. The table spans both rates, both
replies and both passes for each bulk delay. Energy is measured in the delayed word
window, including its room tail where isolated.

| Bulk delay ms | Capture dBFS | Residual output dBFS | Energy reduction dB |
| --- | ---: | ---: | ---: |
| 40 | -25.92–-25.82 | -75.31–-72.39 | 46.57–49.39 |
| 120 | -25.92–-25.82 | -75.33–-71.85 | 46.03–49.40 |
| 250 | -25.92–-25.82 | -75.18–-72.55 | 46.73–49.26 |

This observes remaining acoustic energy during the reply's own “stop”. It does not
establish whether a recognizer or stop detector would self-trigger.

## Verification and recovery record

All builds, fixture construction and both processing passes ran on the main Mac
described above, through the supplied voice gate and own-command `taskpolicy -b`
launcher. There was one phase at a time. All source downloads were already cached and
all five pinned hashes verified; Meson used `--wrap-mode=nodownload`. No other GitHub
command followed the single owner-authorized issue/comment read. No VM, app, device or
installation work was done.

Initial host/build issues were resolved: taskpolicy lives at `/usr/sbin/taskpolicy`;
system Bash 3.2 needed a nonempty command array; the initial monolithic macOS build
reached its 840-second deadline and was split into bounded object batches; manual Apple
links required CoreFoundation. The same verified library sources and `-Os` release flags
were retained for resumed objects. No upstream library-source patch was needed. The
termination helper now sends TERM before KILL so Ninja can terminate its own compiler
groups, as established by inspection of the pinned Ninja subprocess code.

Actual command/result record (repository root, with `VOICE_QUIET` set to the
owner-supplied gate):

| Command | Observed result |
| --- | --- |
| `spikes/1225-aec3/build.sh macos` | Tool bootstrap completed; the later monolithic library attempt hit the 840-second guard. Replaced by staged driver. |
| `spikes/1225-aec3/build.sh macos --resume` | Remaining 53 objects completed; probe link identified missing CoreFoundation. |
| `spikes/1225-aec3/build.sh macos --link-only` | Passed after framework fix, then passed again with finalized CLI; each invocation linked both probe variants twice. |
| `spikes/1225-aec3/build.sh ios` | Passed; cold cross-build batches were 150 / 150 / 102 objects, then archives and two link pairs. |
| `python3 spikes/1225-aec3/make_fixtures.py generate` | Final cached 16 kHz / interpolated 48 kHz generation passed: 12 cases, 18 input-file hashes. Earlier native synthesis timeouts are documented above. |
| `python3 spikes/1225-aec3/make_fixtures.py measure --label run1` | Passed all 12 cases, 31,200 frames. |
| `python3 spikes/1225-aec3/make_fixtures.py measure --label run2` | Passed all 12 cases, 31,200 frames; all output hashes matched pass 1. |
| `bash -n spikes/1225-aec3/build.sh` | Passed. |
| Python `ast.parse` of `make_fixtures.py` | Passed. |
| `git diff --check` | Passed. |

Input hashes are checked before each pass. Each output is checked for mono PCM16,
expected rate and exact frame count; NS/AGC must remain off for the baseline. Raw
measurements are `.work/fixtures/results-run{1,2}.json`; per-case JSON/WAV files and all
build/recovery logs remain under `.work/`. These are synthetic tests and cross-links,
with no simulator or physical validation. Repository application checks were outside the
authorized lab scope.

The Mach-O checks used:

```sh
otool -l spikes/1225-aec3/.work/artifacts/macos/aec3-1.dylib
nm -gU spikes/1225-aec3/.work/artifacts/macos/aec3-1.dylib
otool -l spikes/1225-aec3/.work/artifacts/ios/aec3-1.dylib
nm -gU spikes/1225-aec3/.work/artifacts/ios/aec3-1.dylib
```

They showed macOS platform 1 / minimum 13.0 and iOS device platform 2 / minimum 16.0,
both SDK 26.2, with only `_aec3_probe` exported. API delay snapshots settled to 36 / 116
/ 244 ms for the 40 / 120 / 250 ms fixtures; these internal block-based estimates are
not physical route-latency proof.

Scope check: five added files, all under `spikes/1225-aec3/`; four non-Markdown files.
The PR-shape checker's exact exclusions leave three production files (`.md` and
`.gitignore` excluded). There are no renames, third-party sources, audio or generated
build products in the commit. Local commit only; no push or PR was requested.

## Limits and proposed next steps

This lab does not prove barge-in detection, recognition accuracy, a stop self-trigger
rate, battery cost or a live captured-output round trip. Residual energy during a known
word is only an acoustic proxy for self-trigger risk; no detector is present. Synthetic
rooms omit real speaker/microphone response, changing routes, clock drift, jitter,
Bluetooth latency and lost frames. Neither iPad/Catalyst execution nor physical device
performance is validated. Native wideband 48 kHz speech quality remains untested; those
speech sources are interpolated from 16 kHz, and the synthetic non-linearity/noise are
then applied at the target rate. The sparse exponentially decaying room is deliberately
repeatable rather than a calibrated room model. CPU under background scheduling on this
Mac is a conservative desktop proxy, never a phone estimate.

First sweep calibrated near-to-echo levels and onset timing, and evaluate AEC3
parameters against the observed near-end loss. This baseline is not a validated
replacement for the current masking behavior. Once preservation is satisfactory and
after #1213, propose in-app integration behind an explicit switch, feeding the exact
played PCM as render reference and preserving existing route and privacy policy. A phone
CPU run needs the owner's OK. Then validate real speaker routes, AirPods/Bluetooth and
the issue's physical stop matrix before making any production decision. AECMOS, battery,
added device latency and real recognition outcomes remain deferred, outside this
lab-only scope.
