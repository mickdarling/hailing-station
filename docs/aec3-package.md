# Standalone AEC3 package (#1225, S1a)

S1a produces the static C library, public header, module map and redistribution notices in
`HailAEC3.xcframework.zip`. S1b will publish that zip as a release asset on the Hailing Station
GitHub repository and pin its URL and SHA-256 in a SwiftPM binary target. S2b will adapt
the fixed 10 ms C calls to HailCore’s canceller-neutral `FrameEchoCanceller` timeline.

## Reproduce

Requires macOS, full Xcode at `/Applications/Xcode.app`, its system-selected Python 3.8+ (stdlib only),
curl and tar. No package manager, sudo, signing or VM.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b scripts/build-aec3-xcframework.sh
(cd build/aec3/out && shasum -a 256 HailAEC3.xcframework.zip HailAEC3.xcframework/*/libHailAEC3.a */libHailAEC3.a) > build/aec3/first.sha256
taskpolicy -b scripts/tests/test-aec3-shim.sh
taskpolicy -b scripts/build-aec3-xcframework.sh --clean
(cd build/aec3/out && shasum -a 256 -c ../first.sha256)
taskpolicy -b shellcheck scripts/build-aec3-xcframework.sh scripts/tests/test-aec3-shim.sh
```

The build and standalone smoke test share one phase driver. Contributors and CI
can leave `AEC3_GATE_DIR` unset to build without host gates. When set, it names a
directory of trusted owner-local scheduling hooks. Before each phase the driver
runs `hostslot-wait.sh`, then `voice-quiet.sh`, from that directory with the login
home. A missing hook or nonzero exit stops the build. The hooks run outside the
allowlisted build environment and are excluded from the verified inputs.
Work runs under `taskpolicy -b`, Ninja uses `-j 2`, and each
phase has a 14-minute work deadline after the gates. Only processes started by
the driver can be stopped; unrelated processes are never reprioritized/signalled.

Each work phase starts with an allowlisted environment. System commands use
`/usr/bin:/bin:/usr/sbin:/sbin`, and `xcrun` selects the SDK and compilers from
`/Applications/Xcode.app/Contents/Developer`. Home, temporary files, XDG and compiler/Python
caches live under the ignored `build/aec3/`. The driver sets the archive epoch, timezone
and locale. Compiler, package-discovery and Python settings from the caller are excluded.

The five pinned fetches follow HTTPS redirects one hop at a time, checking the host
before each request. A download enters the cache only after its SHA-256 matches.
The driver copies each cache entry into the build's private `inputs/` directory
and verifies that copy against its pin. A mismatch stops the build before extraction
and reports the exact cache path to remove. Extraction, the Abseil overlay and tool
bootstrap all use the verified private copies, so later cache refreshes cannot change
the build inputs. Pre-populate `build/aec3/downloads/` for offline builds.
Every package build extracts verified
Meson and Ninja sources and bootstraps Ninja anew. The driver invokes both by
absolute path. Meson uses `--wrap-mode=nodownload` and forced Abseil fallback.
The default command and `--clean` both build a release package from fresh target
trees. Each starts with an empty private work directory. Only the verified downloads
are shared between release builds.

For trusted local iteration, `scripts/build-aec3-xcframework.sh --resume-local`
can reuse matching Meson state and objects under `build/aec3/local-targets/`.
It produces thin libraries and size probes in `build/aec3/local-out/`.
Those outputs are **ineligible for release**. Packaging rejects local mode and
the driver reserves `build/aec3/out/` for fresh release builds.

Packaging recreates the header staging directory and checks for exactly
`hail_aec3.h` and `module.modulemap` before invoking Xcode. Before zipping, the
driver checks staging again and verifies the full bundle inventory, including
both headers in each slice. Unexpected entries and symlinks fail packaging.
The driver rejects symlinks in the output path and anywhere in the existing
published tree. Once all slices and the ZIP are ready, it publishes the staged
directory in a single rename. Replacing an existing `out/` uses macOS
`renamex_np(RENAME_SWAP)` on the same volume. A failure before or during publication
exits nonzero and leaves the previous package in place. Once the rename succeeds,
the driver reports the published path and ZIP SHA-256 before removing the old
generation. If cleanup fails, it warns on stderr with the retained path and exits
zero. The same exit-code contract applies to local publication, which reports the
thin-archive hashes.

## Build contents and pins

All libraries are static, release, `-Os`. Each slice includes the shim and all
APM/Abseil objects, each once in sorted path order. The generated module map links libc++ and CoreFoundation. Runtime-configurable disabled processors can
remain linked: “AEC3 only” describes configuration, not source-code removal.

| Slice | Architectures | Minimum OS |
| --- | --- | --- |
| macOS | arm64 + x86_64 (universal) | 13.0 |
| iOS device | arm64 | 16.0 |
| iOS simulator | arm64 + x86_64 (universal) | 16.0 |

Unchanged [spike pins](../spikes/1225-aec3/README.md); literal URLs are in the script:

| Artifact | Version | SHA-256 |
| --- | --- | --- |
| webrtc-audio-processing | 2.1 | `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe` |
| abseil-cpp | 20240722.0 | `f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3` |
| Meson Abseil overlay | 20240722.0-3 | `12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b` |
| Meson | 1.8.3 | `f118aa910fc0a137cc2dd0122232dbf82153d9a12fb5b0f5bb64896f6a157abf` |
| Ninja | 1.13.1 | `f0055ad0369bf2e372955ba55128d000cfcc21777057806015b45e4accbebf23` |

If GitHub regenerates the Ninja archive with different bytes, its SHA-256 check stops the build before extraction.

[NOTICE.txt](../Native/HailAEC3/NOTICE.txt) contains verbatim BSD-3-Clause,
WebRTC patent grant, embedded third-party notices and Abseil Apache-2.0 from
verified tarballs. The script also copies these into the generated xcframework.
No third-party sources, binaries or audio are committed.

## C API

See [hail_aec3.h](../Native/HailAEC3/include/hail_aec3.h) for the complete contract:
`create(rate, channels, config)` returns a handle or NULL; `process_render` takes
read-only PCM; `process_capture` replaces PCM on success; `delay_ms` returns the
latest internal estimate. Pass the sole owning handle by address to
`hail_aec3_destroy(&handle)`. It clears the handle to NULL, so repeated destruction
through that owner is safe. A NULL address is also accepted. Processing returns zero or
negative errors, with no exceptions/C++ types crossing the boundary. Callers
serialize all calls per handle; allocation/real-time behavior is unvalidated.

Frames are exactly 10 ms of interleaved PCM16 at 16/32/48 kHz, one or two channels:
`samples = rate / 100 * channels` (total count). Feed actually played render
before capture. Delay is not physical route latency; unavailable is a negative
status. Statistics are drained after each capture so rare queries stay current.

NULL config selects upstream suppressor defaults, NS off, HPF off. Explicit
configs use `HAIL_AEC3_CONFIG_INIT`, preset 0/1 and boolean NS/HPF fields. Preset 1
(conservative) doubles `enr_transparent` and `enr_suppress` in both LF/HF masking
thresholds of **both** `normal_tuning` and `nearend_tuning`, reducing suppression.
This is an experimental S0 input, not a validated tuning result. NS uses its
upstream default level when on. Both AGCs, mobile AEC and forced HPF remain off;
delay/filter behavior otherwise uses upstream defaults.

## Verification and size method

The script prints static slice sizes and per-architecture stripped dylib deltas:
same install name, one `_aec3_probe` export, `-dead_strip`, `strip -x`, with/without
the C shim/APM dependency. This follows the spike's reachable-linked-code proxy;
it is not app download size. iOS/simulator outputs are cross-built/linked only.

The printed SHA-256 hashes `out/HailAEC3.xcframework.zip`, the future SwiftPM
artifact (a directory has no SwiftPM checksum). Zip order/timestamps/permissions
and archive dates are normalized; source paths are remapped. Compiler/SDK and
Python/zlib remain build inputs, so cross-toolchain byte equality is not promised.

The build smoke-tests the native macOS thin archive before continuing cross-builds;
the standalone C11 consumer always compiles against the header and links the
universal library **inside the published XCFramework**. It accepts no archive
override. Each smoke invocation uses a fresh temporary directory and includes
`<hail_aec3.h>` from the selected include directory.
The C11 smoke consumer uses fixed-seed broadband render, an 80 ms half-amplitude
echo and a distinct 997 Hz near-end burst during continuing render. For both
presets at 16/48 kHz it requires ERLE >20 dB over seconds 6–9 and near-tone
amplitude >25% of input (about -12 dB) over 10.25–11.75. Frequency projection
tolerates block delay without counting unrelated echo as near-end. API checks
cover invalid arguments/configs, frame sizes, unchanged render/error capture,
all supported rates/channels, NS/HPF and delay convergence. These synthetic
checks do not validate speech, recognition, device CPU or real barge-in.

Round d static checks passed for both scripts (`shellcheck` and `bash -n`), the
public C11 header and the C++17 shim (`clang -fsyntax-only` using the existing
macOS arm64 dependency headers).

## Verification at `ecfb2a97a4c6e962043c6b7fc13d4d9ba93168e3`

The sizes, checksums and smoke results below were produced at `ecfb2a97`. This revision
differs from that commit only in gate-directory handling and documentation.
A confirming clean release build at `bfce04ddc78cfd349fd2af6796e6cf865a56ba44`, the first revision with the
current gate handling, ran on the same Mac and checkout path with the owner-local host-slot and
voice-quiet hooks configured. It matched all 22 SHA-256 entries recorded below (`shasum -a 256 -c`),
its ZIP was byte-identical to the first run's (`cmp`), and the packaged smoke test reproduced the
ERLE, near-tone and delay values in the smoke table exactly.

Two clean release builds and the standalone packaged smoke test passed on one Apple silicon Mac. Both builds used the same checkout path, Xcode 26.3 (17C529), Apple Clang 17.0.0 (clang-1700.6.4.2), macOS/iOS/simulator SDKs 26.2, Python 3.9.6 and zlib 1.2.12. Each run verified fresh private copies of the five pinned inputs, bootstrapped Ninja and rebuilt all five architecture targets.

| Packaged artifact | Bytes | SHA-256 in both builds |
| --- | ---: | --- |
| macOS arm64 + x86_64 | 7,354,816 | `97c1ec4a09342e0831b897e5aaca78d87209773752a04863d5a8d66400c6e28c` |
| iOS arm64 | 3,534,752 | `c4346757e78efdbb04e03ec9e86174915f170861a5cf77e324ed760c9806f814` |
| iOS simulator arm64 + x86_64 | 7,040,384 | `bed62299b6363e47c68262e8c6bca2c7ef51ab7aec88d4f4ed3f16d47e895299` |
| XCFramework ZIP | 5,475,306 | `daa2350fbe527534cd13a6215fbe40e68b654e09c99010daefd3c43cad716920` |

| Thin target | Static archive bytes | Baseline dylib bytes | Linked dylib bytes | Linked delta bytes | Static archive SHA-256 |
| --- | ---: | ---: | ---: | ---: | --- |
| macos-arm64 | 3,621,360 | 16,784 | 421,960 | 405,176 | `4e7801892711c4d8ba1ee102d71d7772f20f5e54f6a676b536f0273b06b5b6c4` |
| macos-x86_64 | 3,733,408 | 4,208 | 430,952 | 426,744 | `b58173a54190cea142e5a687805d6508f4a7b4396d5e14428117c517600d63ec` |
| ios-arm64 | 3,534,752 | 32,888 | 434,608 | 401,720 | `c4346757e78efdbb04e03ec9e86174915f170861a5cf77e324ed760c9806f814` |
| sim-arm64 | 3,623,080 | 16,784 | 421,576 | 404,792 | `d78e4010ae41c1a207324e1d23bcf55f698936f4d47a3cbab538f11c7b0828b7` |
| sim-x86_64 | 3,417,256 | 4,208 | 430,728 | 426,520 | `d7dd6f2e966b36eb7204121d87a4a56a4b7ea28693263dad5a22d03d8ab7e8b0` |

The C11 smoke consumer linked the packaged universal macOS archive and ran its arm64 slice. The C ABI checks passed, including repeated destruction through the same owner. The synthetic test required echo-only ERLE above 20 dB and a double-talk near-tone amplitude ratio between 0.25 and 1.5. The distinct near-end tone overlapped active render and echo in all four cases.

| Rate | Preset | Echo-only ERLE (dB) | Double-talk near-tone amplitude ratio | Internal delay (ms) |
| ---: | --- | ---: | ---: | ---: |
| 16 kHz | Default | 22.43 | 0.9582 | 76 |
| 48 kHz | Default | 21.68 | 0.9598 | 76 |
| 16 kHz | Conservative | 22.43 | 0.9636 | 76 |
| 48 kHz | Conservative | 21.68 | 0.9621 | 76 |

During double-talk, render/echo RMS was 3,929.7/1,966.0 at 16 kHz and 3,909.1/1,953.1 at 48 kHz (PCM16 units). The test requires each RMS to exceed 100. The iOS device and simulator results cover cross-compilation and linking.

All 22 SHA-256 entries matched across builds. The comparison covered the ZIP, five thin archives, three merged or copied slice archives, their three packaged copies, and ten stripped probe dylibs. The ZIPs also matched byte for byte with `cmp`. This establishes repeatability on this host at this path. Cross-host reproducibility would require independent clean builds on different Macs and checkout paths with recorded toolchain versions.

### Commands used for this verification

An owner-local host-slot gate ran before each phase.

```sh
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
evidence=$(taskpolicy -b /usr/bin/mktemp -d "$PWD/build/aec3/verify-ecfb2a97.XXXXXX")

manifest() {
  (cd build/aec3/out && taskpolicy -b /usr/bin/shasum -a 256 \
    HailAEC3.xcframework.zip HailAEC3.xcframework/*/libHailAEC3.a \
    */libHailAEC3.a */*.dylib)
}
taskpolicy -b scripts/build-aec3-xcframework.sh --clean >"$evidence/build1.log" 2>&1
manifest >"$evidence/run1.sha256"
taskpolicy -b /bin/cp build/aec3/out/HailAEC3.xcframework.zip "$evidence/run1.zip"
taskpolicy -b scripts/tests/test-aec3-shim.sh >"$evidence/smoke.log" 2>&1
taskpolicy -b scripts/build-aec3-xcframework.sh --clean >"$evidence/build2.log" 2>&1
manifest >"$evidence/run2.sha256"
(cd build/aec3/out && taskpolicy -b /usr/bin/shasum -a 256 -c "$evidence/run1.sha256")
taskpolicy -b /usr/bin/cmp "$evidence/run1.sha256" "$evidence/run2.sha256"
taskpolicy -b /usr/bin/cmp "$evidence/run1.zip" build/aec3/out/HailAEC3.xcframework.zip
```
