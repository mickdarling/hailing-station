# TestFlight delivery

TestFlight is Hailing Station's remote beta-install path. A TestFlight build can be installed on an enrolled iPhone or iPad without a cable or local Xcode connection. Direct Xcode installation remains the fastest local development loop.

The initial path is deliberately **Internal Only**. An uploaded build cannot later be used for external TestFlight or App Store distribution. That narrower setting is appropriate while the only tester is the developer and avoids accidentally treating an experimental build as a public-release candidate.

## One-time Apple setup

1. Confirm that the app identifier used by the generated project exists for the intended Apple developer team.
2. Create the matching app record in App Store Connect if it does not already exist.
3. Accept any pending developer or App Store Connect agreements.
4. Add the intended Apple account as an internal tester and install Apple's TestFlight app on each test device.
5. In Xcode, sign in to an Apple account with permission to upload builds.

Do not add account names, team identifiers, API-key identifiers, issuer identifiers, private keys, provisioning profiles, or device identifiers to the repository or public issue comments.

## Archive without uploading

From a clean, reviewed checkout:

```sh
scripts/testflight.sh archive
```

The script runs the standard verification and Simulator build, generates the Xcode project, chooses a high-resolution time-based build number, and writes a signed Release archive below the ignored `artifacts/` directory. It checks the checkout both before verification and immediately before archiving, including ignored files beneath application and package source roots. Set the team for the invocation when more than one Apple team is installed:

```sh
HAIL_DEVELOPMENT_TEAM=<local-team-id> scripts/testflight.sh archive
```

Use `--version`, `--build`, or `--archive-path` only when a release needs an explicit value. Build numbers must increase for each upload of the same marketing version.

## Upload an archive

Uploading is a separate, explicit action:

```sh
scripts/testflight.sh upload \
  --archive-path artifacts/HailingStation-<version>-<build>.xcarchive \
  --confirm-upload
```

Or archive and upload in one guarded operation:

```sh
scripts/testflight.sh release --confirm-upload
```

Xcode uses the Apple account configured on this Mac. A later CI slice can use an App Store Connect API key once the repository secret store and release approval policy are configured. The private key and all associated identifiers are deployment credentials; they must never be committed, printed in logs, or included in diagnostics.

## Install and validate remotely

After App Store Connect finishes processing the build, assign it to the internal tester group if automatic distribution is not configured. Open TestFlight on the remote device, install Hailing Station, and run this minimal proof over Wi-Fi and cellular:

1. Launch the TestFlight build and confirm the displayed product is Hailing Station.
2. Connect to a deliberately configured private Mac host.
3. Confirm the host's startup voice check reaches the device.
4. Tap once to capture a short synthetic request and confirm it is sent without a transcription review step.
5. Confirm the host response appears and plays on the device.
6. Exercise pause, replay, mute, and the emergency escape action.
7. Record only the app version, build number, broad device class, operating-system version, and pass/fail outcome.

TestFlight availability does not replace Hailing Station's private-network or host authentication requirements. A remotely installed app still needs an approved path to the selected Mac host.

## Recovery

- If archive signing fails, select or install the intended Apple team in Xcode, then retry with `HAIL_DEVELOPMENT_TEAM` set only in the local shell.
- If upload reports that the bundle identifier or app record is missing, create or correct the record in App Store Connect; do not change the identifier only to bypass the error.
- If an agreement or role blocks upload, resolve it in the Apple developer account and rerun the upload against the same archive.
- If Apple rejects a duplicate build number, create a new archive with a larger `--build` value. An archive's embedded build number cannot be changed safely after signing.
- If a build is bad, stop assigning it to testers and upload a corrected build with a new number. Existing direct Xcode builds can still be used for local recovery.
