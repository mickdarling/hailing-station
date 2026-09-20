# Contributing to Hailing Station

Hailing Station is public while still early and security-sensitive. Issues, design discussion, and reproducible test reports are welcome.

## Code contributions

External code contributions are not yet being accepted. The project is intended to remain available under AGPL-3.0-only while also supporting separately licensed official distributions. A contributor agreement that grants the necessary relicensing rights will be published before outside code is merged.

Please do not submit code copied from another project or a pull request containing substantive implementation until that agreement is in place.

## Reports and proposals

When opening an issue:

- describe the behavior and supported Apple platform involved;
- provide the smallest reproducible example possible;
- remove device names, network addresses, account identifiers, transcripts, recordings, and signing information; and
- use GitHub's private vulnerability reporting flow for security defects.

## Maintainer workflow

Changes are developed from issue specifications and kept small enough to review. Pull requests should identify the issue they close or advance, name the tests that cover their acceptance criteria, and pass the repository verification scripts.

Run before pushing:

```sh
scripts/verify.sh all
```

Simulator verification additionally requires the full Xcode toolchain:

```sh
scripts/verify.sh sim
```

Never commit credentials, Apple signing material, device identifiers, private network information, captured media, transcripts, generated Xcode projects, or local configuration.
