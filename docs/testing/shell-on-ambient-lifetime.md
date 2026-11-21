# Flag-on native shell ambient lifetime qualification (#1115)

This is a separate qualification candidate based on adoption `a82b827b`. It does not rewrite approved shell or
Settings heads. The issue-linked PR's Verification record owns actual commands, results, evidence and exact-head
reviews. Source authoring ran no build, test, lint, simulator, OS/hardware/audio query or playback, network or push.

## Real code under test

The SwiftPM native fixture previously replaced `stationRoot` with a legacy NavigationStack and supplied a no-op
`stationCollapsed`. Those substitutes cannot establish flag-on shell lifetime. This candidate removes both and
compiles the actual app sources through test-only symlinks: `RootView+Navigation`, `StationNavigationShell`,
`StationAccessibilityScope`, `StationToolLink`, and the real collapsed modifier, alongside the already-symlinked
native root, resources and ambient card. The surrounding station layout remains the existing scene fixture, which
conditionally mounts the real ambient surface and an inert tool; it does not render all of RootView+Interface or
StationLayout. The Mac tool screens are inert peripheral UI stubs. The Mac navigation-bar
cosmetic helper returns self, as its actual Mac platform branch does; no UIKit toolbar behavior is simulated.

There are three production files, with no audio/transport/ambient/playback logic changes:

- Move the existing `stationCollapsed` extension byte for byte from `StationExpandedControls.swift` into
  `StationCollapsed.swift`. Directory-based app targets include it automatically; the package symlinks the real file.
- Spell RootNav's extension target `StationRootView`. In the real iOS and Mac app, `RootView` is an exact alias for
  that type. Under SwiftPM the alias is deliberately excluded because an existing legacy selection-test class has
  the name `RootView`. This changes no app branch or behavior and avoids a test-only rewrite of navigation logic.

No protected `HailApp`, `RootView`, `StationCard` or `StationPlatform` behavior is changed. No HailCore file or build
manifest is changed, and no new production test hook, controller, owner or launch path is introduced.

## Process isolation and defaults

Only the dedicated opt-in path of `NativeShellLaunchContext` installs one literal true Boolean in the process's
volatile `NSArgumentDomain` before the actual production static launch snapshot is first read. The previous
volatile domain is restored synchronously, before any suspension; it never calls a persistent defaults writer.
The actual launch snapshot is then held for the process, just as in the app; no flags are re-read to swap a branch.

Without `HAIL_NATIVE_SHELL_LIFETIME=1`, existing native-root fixtures only read the genuine production snapshot;
no defaults domain is changed and no saved value is masked. CI's missing preference must remain default-off,
which a named native fixture test asserts explicitly. The new suite is disabled. With the explicit environment
opt-in, run ONLY the dedicated filtered suite in a NEW process, serially. Do not set the opt-in on
`verify.sh all`, an unfiltered test process, a parallel CI lane or an installed app. A wrong/stale snapshot fails
the new suite's explicit flag-on requirement rather than silently testing the legacy branch.

The existing scene host reads/configures that context before constructing its root; direct-root lifetime tests do
the same in their test-suite initializer. It occurs once on the main actor without yielding. Normal parallel CI
does not receive a temporary override that could race the real-UserDefaults flag tests. Restoring the opt-in
input does not mutate the cached snapshot. Synthetic diagnostics use a unique suite, assert collection is off,
and make no preference writes. No live-app reset or disk preference write is used for either path.

## Assertions and honest limits

`NativeShellAmbientLifetimeTests` uses the existing `AmbientReconnectRig` and `NativeSceneAmbientHost`. It first
mounts the actual root/card around a confirmed scripted destination and the existing fake controller, then starts
that synthetic owner. Waiting for the real card's activity callback ensures the real ambient content initialized.
Visibility observations come from the actual shell's `stationAccessibilityHidden` environment, so selecting
Devices/Settings/Sessions and returning to Station must exercise the real flag-on branch and hide/show the station.

The existing fixture's layout branch also removes and remounts the actual ambient surface/card while pushing and
popping an inert tool. Real surface appear/disappear counters witness that removal. The shipped card's own
`onDisappear` and root destination reconciliation run unchanged; the fixture contains no replacement stop logic.
Every section/removal/remount step checks the same store/controller/binding, requested-on and streaming state,
`startCount == 1`, `stopCount == 0`, no release or new permission/streamer, and additional fake PCM frames delivered
through the same scripted socket. Cleanup intentionally turns the fake owner off only after the continuity checks.

Mac sidebar visibility changes exercise native Mac split-view presentation. Compact-column intents additionally
exercise the actual state model while synthetic delivery continues. They DO NOT prove that AppKit displayed an
iPad compact stack. The existing `RedesignShellUITests` on iPad separately checks native section/tree visibility
with shell enabled, without active capture. Actual iPad collapsed-window/navigation continuity, physical VoiceOver,
mid-Talk capture, hardware routes and live audio remain explicit manual/device qualification. No synthetic fixture
or simulator UI result establishes those claims.

## Exact execution sequence after a separate granted UI window

All steps remain serialized behind the current hostslot/load/GO rules and background QoS. The following are
declared commands, not completed execution evidence. Build once, then use two separate test processes:

```sh
taskpolicy -b swift build --build-tests --jobs 2 -Xswiftc -warnings-as-errors

env -u HAIL_NATIVE_SHELL_LIFETIME taskpolicy -b swift test --skip-build --no-parallel --jobs 2 \
  --filter '^HailCoreTests[.](StationSceneLifetimeTests|NativeSceneAmbientObserverTests|NativeSceneAmbientSelectionTests|StationToolAmbientLifetimeTests|StationRedesignFlagsTests)([./]|$)'

HAIL_NATIVE_SHELL_LIFETIME=1 taskpolicy -b swift test --skip-build --no-parallel --jobs 2 \
  --filter '^HailCoreTests[.]NativeShellAmbientLifetimeTests([./]|$)'
```

The opt-in suite has two serialized tests and a one-minute per-test framework limit. Preserve event streams and
fail empty selections. Run strict lint and both app builds for the three-file mechanical production change when
the authorized window permits. The iPad tree check's selector remains:
`-only-testing:Hail-iOSUITests/RedesignShellUITests/testShellAppliesOnlyAfterRelaunchAndKeepsTheStationMounted`.

`trace: partial`: these authored cases target shell-on synthetic ambient lifetime. They do not close the physical
device/VoiceOver/Talk/real-audio or actual iPad compact-stack requirements, and authorize no flag flip or deployment.
