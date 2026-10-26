# TestFlight delivery

TestFlight is Hailing Station's remote beta-install path. A TestFlight build can be installed on an enrolled iPhone or iPad without a cable or local Xcode connection. Direct Xcode installation remains the fastest local development loop.

The initial path is deliberately **Internal Only**. An uploaded build cannot later be used for external TestFlight or App Store distribution. That narrower setting is appropriate while the only tester is the developer and avoids accidentally treating an experimental build as a public-release candidate.

## One-time Apple setup

1. Confirm that the app identifier used by the generated project exists for the intended Apple developer team.
2. Create the matching app record in App Store Connect if it does not already exist.
3. Accept any pending developer or App Store Connect agreements.
4. Add the intended Apple account as an internal tester and install Apple's TestFlight app on each test device.
5. Configure a local App Store Connect API key as described below, or sign in to an Apple account in Xcode for the account-based fallback.

Do not add account names, team identifiers, API-key identifiers, issuer identifiers, private keys, provisioning profiles, or device identifiers to the repository or public issue comments.

## Archive without uploading

Every distinct TestFlight release has three identities:

- `MARKETING_VERSION` is the tester-visible release number. Increment it in `project.yml` for every release that contains a new commit or functional change, even while the app remains in internal testing.
- `CFBundleVersion` is the upload build number. It must be unique and increasing for every upload attempt, including a retry of the same release.
- The Git commit SHA is the exact source identity. Archive only a clean, reviewed commit.

The normal sequence is therefore: make the functional change, increment the marketing version in the same reviewed release commit, merge it, and archive that commit from `main`. The guarded archive and release commands reject a commit that does not advance the version in `project.yml` relative to its parent. `--version` cannot bypass the tracked value.

From that clean, reviewed checkout:

```sh
scripts/testflight.sh archive
```

The script runs the standard verification and Simulator build, generates the Xcode project, chooses a high-resolution time-based build number, and writes a signed Release archive below the ignored `artifacts/` directory. It removes the generated entitlements before each cleanliness check, rejects every other ignored file beneath application and package source roots, and regenerates the entitlements from the reviewed manifest immediately before archiving. Set the team for the invocation when more than one Apple team is installed:

```sh
HAIL_DEVELOPMENT_TEAM=<local-team-id> scripts/testflight.sh archive
```

Use `--build` or `--archive-path` only when a release needs an explicit value. `--version` is accepted only when it matches `project.yml`; change and review the tracked version instead of overriding it at release time. Build numbers must increase for each upload of the same marketing version.

The script preserves an explicitly set `DEVELOPER_DIR`. Otherwise it uses the active Xcode developer directory; when the active directory is CommandLineTools or unavailable, it selects `/Applications/Xcode.app/Contents/Developer` if installed. If neither is available, it fails before verification or archiving with an instruction to install Xcode or set `DEVELOPER_DIR`. This selection applies only to the script process and does not change the system selection.

To check the release commit without archiving:

```sh
scripts/testflight.sh check-version
```

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

For API-key upload, set `HAIL_ASC_KEY_DIR` privately in the local shell or pass `--api-key-dir "$HAIL_ASC_KEY_DIR"`. The option takes precedence over the environment variable. The directory must live outside the repository, be owned by the current user, and have owner-only permissions (for example, mode `700`). It must contain exactly one `AuthKey_*.p8`, plus non-empty single-line `key_id` and `issuer_id` files. All three files must be readable, non-empty regular files owned by the current user with owner-only permissions (for example, mode `600`); symlinked directories and credential files are rejected. Provision credentials locally; never copy their values or paths into repository files, logs, diagnostics, or public comments.

```sh
scripts/testflight.sh release --confirm-upload --api-key-dir "$HAIL_ASC_KEY_DIR"
```

With an API key, the script first exports a local IPA using `xcodebuild -exportArchive` with API authentication and provisioning updates allowed. Export options use `app-store-connect`, destination `export`, automatic signing, version/build management disabled, Internal Only enabled, and symbol upload enabled. It then invokes `xcrun altool --upload-app` with API authentication and `API_PRIVATE_KEYS_DIR` pointing at the private directory. The existing exit trap removes the temporary export directory on success or failure.

Upload succeeds only when altool exits successfully **and** reports `UPLOAD SUCCEEDED`. A `CREATE BUILD` request that times out is a failure even with exit status zero or a success marker elsewhere in the output. There is no automatic retry: check the delivery state before deliberately retrying. Shell tracing is disabled before reading credentials. Export diagnostics are suppressed, and altool output is filtered to fixed status messages; identifiers and raw diagnostics are never printed.

Without a key directory, Xcode uses its configured Apple account with destination `upload`, preserving the existing fallback. The private key and all associated identifiers are deployment credentials; they must never be committed, printed in logs, or included in diagnostics.

Use `--dry-run` to validate arguments, select the toolchain, validate any key directory, and print a redacted plan without running verification, signing, archiving, exporting, or uploading:

```sh
scripts/testflight.sh release --confirm-upload --dry-run --api-key-dir "$HAIL_ASC_KEY_DIR"
```

Dry-run upload/release still requires `--confirm-upload`; it does not require an existing archive or a clean version-advancing release commit. Those guards apply when executing the plan. Paths and authentication values in the plan are placeholders. Offline coverage lives in `scripts/tests/test_testflight_api_key.py`, also run by `scripts/tests/test-testflight.sh`. These shim tests validate script behavior; they are not a physical-device, signed archive, or live App Store Connect delivery proof.

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
- If Apple rejects a duplicate build number, create a new archive of the same reviewed release commit with a larger `--build` value. An archive's embedded build number cannot be changed safely after signing.
- If a build is bad because its source changed, stop assigning it to testers, increment the marketing version, review and merge the correction, and upload that new release. Existing direct Xcode builds can still be used for local recovery.
