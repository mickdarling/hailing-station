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
