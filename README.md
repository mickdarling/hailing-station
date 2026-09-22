# Hailing Station

Hailing Station is an audio-first interface between personal Apple devices and applications running on one or more Macs.

The iPhone or iPad owns capture, playback, routing, replay, and attention management. Mac hosts own application-specific processing. Speech is the primary path; transcripts, text, images, and other media can travel beside it.

## Why it exists

Remote tools normally bring their own mobile client, audio behavior, and interaction model. Hailing Station provides a small, application-independent boundary instead:

- connect an iPhone or iPad to one or more Mac hosts;
- select any target exposed by a host adapter;
- capture from the active or selected microphone;
- receive and manage concurrent spoken responses without sources talking over one another;
- pause, mute, replay, and inspect the transcript of each response; and
- survive ordinary audio-route and network changes.

AI tools are useful targets, but they are not the definition of the project. The transport and interface are intended to work with any application or service that can implement an adapter.

## Status

Hailing Station is experimental and under active development. The current code establishes the shared protocol, host-daemon boundaries, security controls, audio routing probes, and an iOS/iPadOS transcription surface. It is not ready for unattended or security-sensitive deployment.

The first supported environment is:

- iOS and iPadOS terminals;
- macOS hosts;
- direct, authenticated connections over a private network; and
- tmux as the first host adapter.

Windows, Linux, Android, and browser terminals are outside the initial scope.

## How work is managed

[GitHub Issues](https://github.com/mickdarling/hailing-station/issues) are the project's source of truth for feature and process management. They serve the same role as tickets, stories, bugs, spikes, and decision records in systems such as Jira, without requiring ritualized wording such as “As a user…” or “As a developer…”.

A useful issue states the intent and boundaries of the work, adds testable acceptance criteria, and records dependencies or evidence when those matter. Pull requests link the issue they advance and say accurately whether they close the whole issue or only deliver one part of it. Small implementation details may stay in a pull request, but planned behavior and follow-up work belong in issues so they remain visible after the pull request is merged.

## Build and verify

Requirements include a current Xcode toolchain, Swift 6, and XcodeGen for generating the application project.

```sh
swift test
scripts/verify.sh all
xcodegen generate
```

Generated Xcode projects, signing material, local configuration, recordings, captures, and build products are intentionally excluded from version control.

Physical-device signing, installation, audio-route checks, and privacy-safe diagnostics are covered by the [iPhone and iPad device-testing runbook](docs/device-testing.md).
Remote beta installation and guarded App Store Connect upload are covered by the [TestFlight delivery runbook](docs/testflight.md).
The first one-Mac physical proof is summarized in the [single-device vertical-slice test record](docs/vertical-slice-test-record.md).
The current adaptive layout and sanitized interaction record are documented in the [mobile interface notes](docs/mobile-interface.md).

## Naming

**Hailing Station** is the project and application. **Haley** is the default persona presented by the interface; persona names and behavior are intended to be configurable and are not part of the transport protocol.

The Swift package and module names currently retain the shorter `Hail` prefix. They are implementation identifiers, not a separate product.

## Security and privacy

Hailing Station can deliver text to applications on a Mac, so a compromised terminal or connection can have the same impact as typing into those applications locally. Treat every remote-delivery path as privileged.

The public repository intentionally contains no device identifiers, private network addresses, signing identities, captured audio, transcripts, credentials, or deployment configuration. See [SECURITY.md](SECURITY.md) for reporting instructions and [docs/security.md](docs/security.md) for the public security boundary.

## License

The public project is licensed under the [GNU Affero General Public License v3.0 only](LICENSE).

Alternative commercial licensing may be made available by the copyright holder. The commercial option permits distributions that cannot or do not wish to comply with the AGPL; it does not change the availability of this public source tree.

External code contributions are not yet being accepted because the contributor agreement needed to preserve dual licensing has not been finalized. Bug reports, design discussion, and reproducible test reports are welcome.
