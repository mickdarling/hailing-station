# iPhone and iPad device testing

This runbook builds and exercises Hailing Station on a paired physical device without committing Apple account, signing, device, network, or captured-content details.

## Local prerequisites

- A current Xcode installation and XcodeGen.
- An Apple development team available to Xcode.
- An iPhone or iPad registered for development, paired with the Mac, unlocked for installation, and in Developer Mode.
- A private test network when host connectivity is being exercised.

Keep team identifiers, device identifiers, host addresses, signing certificates, provisioning profiles, recordings, transcripts, and diagnostic archives out of the repository and public issue comments.

## Generate and verify

Generate the project from the tracked specification. Do not edit the generated project:

```sh
xcodegen generate
scripts/verify.sh all
```

Use Xcode's full developer directory if the Mac defaults to Command Line Tools:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

List destinations and identify the locally connected device without recording its identifier:

```sh
xcodebuild -project HailingStation.xcodeproj -scheme Hail-iOS -showdestinations
```

## Build and install

Supply local values at invocation time. The project deliberately leaves `DEVELOPMENT_TEAM` empty:

```sh
umask 077
HAIL_DEVICE_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hailing-station-build.XXXXXX")"
xcodebuild build \
  -project HailingStation.xcodeproj \
  -scheme Hail-iOS \
  -destination 'platform=iOS,id=<local-device-id>' \
  -derivedDataPath "$HAIL_DEVICE_BUILD_DIR/DerivedData" \
  DEVELOPMENT_TEAM=<local-team-id> \
  CODE_SIGN_STYLE=Automatic
```

Installing through Xcode or `devicectl` is acceptable. A build with the existing bundle identifier updates the installed development app in place and normally preserves its data and permission decisions.

## Automated physical smoke test

The UI smoke test is skipped on Simulator because it proves the physical audio-capture callback path. Run it against an unlocked paired device:

```sh
umask 077
HAIL_DEVICE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hailing-station-tests.XXXXXX")"
xcodebuild test \
  -project HailingStation.xcodeproj \
  -scheme Hail-iOS \
  -destination 'platform=iOS,id=<local-device-id>' \
  -derivedDataPath "$HAIL_DEVICE_TEST_DIR/DerivedData" \
  -resultBundlePath "$HAIL_DEVICE_TEST_DIR/Results.xcresult" \
  DEVELOPMENT_TEAM=<local-team-id> \
  CODE_SIGN_STYLE=Automatic \
  -only-testing:Hail-iOSUITests/PhysicalTranscriptionSmokeTests
```

The test accepts only microphone and speech-recognition prompts when iOS presents them, starts capture, waits for an input-tap buffer, stops capture, and verifies that the app remains in the foreground. It intentionally does not retain audio or assert transcript contents. Its DerivedData and result bundle remain in the private directory printed by `mktemp`; delete that directory after retaining any diagnostics you need.

The first completed, privacy-safe device and vertical-slice results are in the [single-device test record](vertical-slice-test-record.md).

## Test the installed TestFlight app without replacing it

Never run an installed-beta UI test from the main application project. Xcode can install a development `Hail-iOS` build from the same project's build products even when the selected UI-test target has no declared app dependency. This occurred during device testing and replaced a TestFlight install. Use the isolated `Tests/InstalledAppHarness/project.yml`, which contains no application target, only after checking the installed version and build with `devicectl device info apps --device <local-device-id> --bundle-id com.mickdarling.Hail-iOS --include-default-apps`.

The device must be unlocked and shown as Connected in Xcode's Devices window for physical UI automation, even when it is paired over Wi-Fi. The smoke test expects exactly one configured Mac and one live allowed target. It connects the Mac if needed and selects that target; it does not capture speech or record transcripts. Generate the isolated project:

```sh
xcodegen generate --spec Tests/InstalledAppHarness/project.yml
```

Open the generated project in Xcode, select the UI-test target's local signing team, choose the paired device, then run Product > Test. Xcode's Devices window may need the device selected to move it from Disconnected to Connected; the command-line runner has reported a passcode error despite a CoreDevice-unlocked device, so prefer the Xcode UI until that is resolved. Check that the installed build number is unchanged afterward. If it changes, stop and restore the beta through TestFlight before further testing. Keep Xcode result bundles private because they may include device or connection metadata.

To update the installed beta without replacing it with a development build, the same isolated
project includes `InstalledTestFlightUpdateTests`. First confirm the intended build is available
to the internal tester group in App Store Connect. Set the expected marketing version explicitly
when running the test (for example, `HAIL_EXPECTED_TESTFLIGHT_VERSION=0.1.3`) and select
only `InstalledTestFlightUpdateTests/testInstallExpectedHailingStationUpdate`. The test opens the
official TestFlight app, checks that its Hailing Station detail page shows the expected version,
and taps Update. It skips without changing the device when no expected version was supplied, and
fails without tapping when TestFlight shows another version. Run separately on each paired,
unlocked physical device using the local UI-test signing team. After each run, verify the exact
installed version and build with `devicectl device info apps`; an `Open` button alone is not
proof of which build was installed. Never run the update test from the main application project.

## Manual route and connection matrix

Run these checks on each currently supported iPhone and iPad form factor:

1. Launch the app and grant microphone and speech access.
2. Activate the audio session and confirm a 48,000 Hz sample rate when the current route supports it.
3. Confirm built-in input and output names.
4. Connect and disconnect each supported external microphone; confirm that the input display follows the route and any explicit preference remains understandable.
5. Select an available output through the system route picker; confirm that route changes initiated elsewhere are reflected in the app.
6. Start and finish a short transcription, checking only synthetic or non-sensitive speech.
7. Add a test Mac endpoint using a redacted private-network address, negotiate the protocol, list allowed synthetic targets, disconnect, and reconnect.
8. Repeat the connection check on Wi-Fi and, when in scope, cellular through the approved private-network overlay.

Output-route ownership is ultimately controlled by iOS. AirPods may move to another nearby Apple device; record that as a route-change observation rather than publishing nearby device information.

## Diagnostics and redaction

Before collecting diagnostics, reproduce with synthetic target names and speech. Record the app version, operating-system version, broad device class, route type, and ordered steps. Do not publish device names or identifiers, account and team data, private addresses, real target names, transcripts, or recordings.

Use Xcode's device logs or `devicectl` system crash-log access when a termination occurs. Extract only the exception, termination reason, and relevant symbolicated frames into a report. Keep the original archive private unless it has been reviewed and deliberately sanitized.
