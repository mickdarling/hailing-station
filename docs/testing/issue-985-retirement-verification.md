# Reply engine retirement verification

Part of #985. Branch `fix/985-engine-retire`, cut directly from
`3c4c86829d56178e1a0159ed40119797945268a5` (`main10`). No network, pushes or tool changes.

## Ownership and route behavior

Two production files: `Sources/HailCore/Replies/PCM16AudioPlayer.swift` and
`Sources/HailCore/MacDefaultAudioSessionBackend.swift`.

The player retains one concrete resource owner. Its plain, nonisolated deinit transfers a rendering resource to
one labelled serial queue, `hailing.reply-engine-retire`. There is no generic OffMainAudioResource or generic
isolated deinit and no new global-queue call. The engine, current engine reference and node belong to the same
rendering resource. The serial queue stops the player's own engine and performs the final release; it does not
stop a borrowed capture engine.

A retained pointer crosses the queue boundary. The owner clears its strong reference in a non-inlined transfer
initializer before enqueueing, so even a queue that executes immediately cannot leave a final main-thread
release. The unchecked Sendable scope covers only this exclusive transfer. Normal access remains with the
main-actor player. The concrete owner avoids the Swift 6.3.3 optimized generic isolated-deinit compiler crash.

The Mac backend preserves confirmed input/sample-rate metadata after a failed input HAL read. It still refreshes
output metadata, clears cached input after a successful no-device read, and never invents an input before the
first successful read. This retains the reviewed throw-versus-nil distinction.

## Behavioral proof and mutation

An engine-free internal ownership seam creates the actual PCM16AudioPlayer with a retirement probe. The test
drops that player on MainActor and awaits a checked continuation from the resource's deinit. It verifies stop
precedes release and both occur off main. It does not instantiate a real engine or use a timing sleep.

Mutation: replace serial enqueueing with immediate disposal in the shipped owner deinit. The player lifetime
test must reach runtime assertion failures, then pass again after restoration. Backend tests inject snapshots
without installing HAL listeners.

## Verification

Every Swift command uses `taskpolicy -b`, `-j 4 -Xswiftc -j1 -Xswiftc -warnings-as-errors`,
`--disable-automatic-resolution`, a process gate for other swift-build/swift-test/xcodebuild processes, and a
590-second kill bound. CLT-specific flags supply the testing framework and plugin from
`/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and
`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`, with framework and developer-library rpaths.

Commands (with those common flags):

- `swift build`
- `swift build --build-tests`
- `swift build -c release`
- `swift test --skip-build --disable-xctest --no-parallel --filter 'PCM16AudioRetirement|MacDefaultAudioSessionBackend' --skip DiagnosticReplyComposition`
- `swift test --skip-build --disable-xctest --no-parallel --filter 'Reply|Playback|EchoGuard|AudioSession|AudioRoute|Root' --skip DiagnosticReplyComposition`

The mutation uses the new-test command without `--skip-build`, restricted to PCM16AudioRetirement. Final results
are recorded below. No physical route-change or AirPods proof is claimed by these synthetic tests.

Final results: debug build PASS, test build PASS, release build PASS (64.03 seconds; no compiler crash),
new/backend tests **6/6 PASS**, and broad filter **696 tests in 171 suites PASS** (146.437 seconds).
Five known issues are deliberate existing handoff timeout/cancellation assertions guarded by withKnownIssue.
The synchronous-disposal mutation reached **2 runtime assertion failures** (stop and final release were both on
main). Restoring serial enqueueing returned the actual-player lifetime test to PASS.

Run totals: **8 Swift invocations**: 7 passing commands and 1 expected runtime mutation failure; 0 timeouts.
Test files: `Tests/HailCoreTests/PCM16AudioRetirementTests.swift` and
`Tests/HailCoreTests/MacDefaultAudioSessionBackendTests.swift`. `git diff --check` and manual changed-code line-length
checks passed. Full Xcode, XcodeGen and SwiftLint remain unavailable. App schemes and physical AirPods behavior
need host/device validation. The three protected connection/reconnect/capture files were not changed.
