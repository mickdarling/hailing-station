# Security policy

Hailing Station is experimental and has no supported production release yet.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for vulnerabilities. Do not open a public issue when a report includes an authentication bypass, command-delivery path, cryptographic weakness, credential exposure, private network information, or a reproducible exploit.

Include the affected revision, platform version, expected behavior, observed behavior, and a minimal reproduction with all personal and infrastructure identifiers removed.

## Sensitive material

Do not attach real credentials, signing certificates, provisioning profiles, device identifiers, private addresses, captured speech, transcripts, or application output. Use synthetic values and redact logs before submission.

## Scope

The security boundary and current assumptions are summarized in [docs/security.md](docs/security.md). Until the project publishes a supported release, running the daemon or connecting it to a command-capable target is at the operator's own risk.
