# Native scene lifetime verification

Part of #985. Branch `fix/985-scene-once`, cut directly from
`3c4c86829d56178e1a0159ed40119797945268a5` (`main10`). No network, pushes or tool changes.

## Shipped integration

Three production files: `Apps/Hail-iOS/RootView.swift`, `Apps/Hail-iOS/StationSceneState.swift`,
and `Apps/Hail-iOS/TranscriptionLabView.swift`. The generic ObservableObject owner and StationResources live
in the app, with the Labs view and announcement helper moved beside them. No HailCore scene-owner file is added.
RootView is below 200 physical lines, and none of these files contains a file-length lint suppression.

Root's StateObject autoclosure encloses the resource factory. Every window retains independent connection,
audio-session, route, playback, echo-guard, keepalive, diagnostics and banner state. The banner binding still
compiles in the native body. Transcription capture is an escaping autoclosure, evaluated inside its own StateObject
factory; default transcriber construction is deferred there too. Existing capture injection call sites retain their
syntax. No real engine is constructed by a discarded view value.

Compatibility aliases retain the app's existing RootView, TranscriptionLabView and ConversationDestinationID
names. Distinct native nominal names let the symlinked views compile alongside the repository's existing
RootView/TranscriptionLabView test shells without altering their adapters.

## Behavioral proof and mutations

Test adapters are symlinks to all three changed app files and the existing AudioRouteModel. Only peripheral
UI helpers, paste UI types and platform entry points are stubbed. The real view declarations, stored wrappers,
initializers, native bodies, owner and resource construction compile into HailCoreTests. Injected resources use
fake session backends, reply players and keepalive renderers; no real audio engine or network connection is used.
No new test reads or matches source strings, and no new test uses a timing sleep.

Three tests prove zero constructions from 17 discarded native roots, one resource factory across 17 NSHostingView
root re-inits, two factories for two scenes, and the equivalent discarded/hosted counts for transcription capture.

Each mutation was compiled and reached failing runtime assertions, then was restored:

- Root initializer evaluates `makeResources()` before StateObject: 35 assertion issues.
- Owner storage changed from StateObject to eager State: 35 assertion issues.
- Capture parameter changed back to an eagerly evaluated value: 36 assertion issues.

These mutations change shipped files followed by the symlinks, not a duplicated probe implementation.

## Verification

All Swift invocations use `taskpolicy -b`, `-j 4 -Xswiftc -j1 -Xswiftc -warnings-as-errors`,
`--disable-automatic-resolution`, and a 590-second kill bound. Before each command, the runner waits while another
swift-build, swift-test or xcodebuild process exists. CLT-specific compiler flags add
`-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and the testing plugin path
`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`; linker rpaths add that Frameworks directory
and `/Library/Developer/CommandLineTools/Library/Developer/usr/lib`.

Commands (with those common flags):

- `swift build`
- `swift build --build-tests`
- `swift build -c release`
- `swift test --skip-build --disable-xctest --no-parallel --filter StationSceneLifetime --skip DiagnosticReplyComposition`
- `swift test --skip-build --disable-xctest --no-parallel --filter 'Reply|Playback|EchoGuard|AudioSession|AudioRoute|Root' --skip DiagnosticReplyComposition`

Mutations use the same new-test command without `--skip-build`. One initial adapter build failed because two paste
UI shell types were missing; the test-only shell was completed and the retry passed. Final results are recorded below.

Final results: debug build PASS, test build PASS, release build PASS (68.51 seconds), new tests **3/3 PASS**,
and broad filter **696 tests in 172 suites PASS** (146.964 seconds). The five known issues are deliberate existing
handoff timeout/cancellation assertions guarded by withKnownIssue, not new unexpected failures.
Run totals: **11 Swift invocations**: 7 passing commands, 3 expected runtime mutation failures, 1 initial adapter-shell
compile failure; 0 timeouts. All source mutations were restored before final builds/tests.

Test files: `StationSceneLifetimeTests.swift`, `NativeSceneTestSupport.swift`, `StationSceneStateAdapter.swift`,
`NativeRootViewAdapter.swift`, `NativeTranscriptionViewAdapter.swift`, and `NativeAudioRouteAdapter.swift`, all under
`Tests/HailCoreTests/` (the four adapters are symlinks). `git diff --check` and manual changed-code line-length checks
passed. Full Xcode, XcodeGen and SwiftLint remain unavailable; app schemes and physical AirPods behavior still need
host/device validation. The three protected connection/reconnect/capture source files were not changed.
