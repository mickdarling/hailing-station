# Public security boundary

Hailing Station transports input to applications running on a Mac. A delivered text frame may be interpreted as a command, so remote delivery is privileged even when the initial target is only a terminal session.

## Assumptions

- The surrounding network is untrusted.
- A reachable peer is not necessarily an authorized terminal or host.
- Target names and application output are untrusted data.
- A stolen or unlocked terminal can be used to impersonate its operator unless local authorization gates intervene.
- Software already running with the operator's account privileges may bypass Hailing Station and interact with local applications directly.

## Required controls

These are requirements, not a statement that the current personal-testing WebSocket implements them. Its listener has no TLS or terminal identity verification; a client-supplied device name is not authentication. Limit that mode to a trusted test environment while [#7](https://github.com/mickdarling/hailing-station/issues/7) and [#21](https://github.com/mickdarling/hailing-station/issues/21) remain open.

- mutually authenticated terminal and host identities;
- replay-resistant, confidential frames;
- explicit target allowlists and delivery policy;
- strict payload typing, size limits, and sanitization;
- local authorization before consequential delivery;
- safe handling of audio-route, connection, and application lifecycle changes; and
- privacy-preserving audit events that exclude payload contents and credentials.

## Repository boundary

This repository must not contain deployment addresses, private network topology, device identifiers, signing material, credentials, captured audio, transcripts, or real application output. Examples and fixtures use synthetic data.

Operational threat models, deployment-specific test evidence, and incident data belong in private systems unless they have been deliberately anonymized for publication.
