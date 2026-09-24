# Host bootstrap and capability catalog (proposal)

This document makes the intended ownership boundary explicit. It is a design proposal tracked by [#105](https://github.com/mickdarling/hailing-station/issues/105), not a claim that launch/configuration support already ships. Today, tmux is the first host adapter and the terminal can browse allowed targets. The proposal extends that arrangement without making the phone an AI-tool launcher or baking tmux into the product contract.

## Product thesis

The Mac host knows which local applications and services exist, how they are configured, and which sessions it is permitted to expose. Hailing Station on iPhone or iPad is the audio-first terminal: it selects an offered destination, sends typed input, presents replies, and arbitrates audio across hosts. It does not need tool-specific binaries, credentials, working directories, or process-management rules.

One host may expose several tools and sessions, and one terminal may connect to several hosts. Neither the host catalog nor the mobile interface assumes a single Mac, a single tmux server, or an AI-only target.

## Baseline voice service without an agent

The first useful host profile can expose a few safe, programmatic intents before Claude, Codex, or another general agent is installed. For example, a spoken connection check can read observed host state and return a fixed response. The terminal captures speech and plays the answer; the host classifies the request among configured intents, authorizes the selected action, runs it, and returns an observed result. The response may be templated text spoken by the existing audio path or an approved clip. No LLM needs to generate the wording.

Speech recognition and semantic routing are different stages. A transcript is evidence of what the recognizer heard, not proof of what the user intended. Start with a small, explicit intent set and a clarification/unsupported path. A later fast decision model, such as the typed-choice approach considered in [#96](https://github.com/mickdarling/hailing-station/issues/96), may help choose among bounded intents; it is optional and does not authorize execution. A validly typed but wrong choice is still a wrong action. Consequential voice actions require separate confirmation before execution ([#89](https://github.com/mickdarling/hailing-station/issues/89)). The initial bounded voice service and its physical-device proof are tracked in [#108](https://github.com/mickdarling/hailing-station/issues/108).

The stages are: terminal audio capture → speech recognition → host intent selection → host policy check → adapter/action execution → observed outcome → deterministic reply text → terminal speech output. Each stage should expose a meaningful pending, failed, or completed state to the conversation UI, without claiming success merely because a message was sent.

## Proposed bootstrap path

1. **Prepare the host.** Install/start the macOS service, inspect health, and configure a local adapter profile. An initial host-side setup command can list supported adapters, check prerequisites, create or edit a profile, grant permitted actions, and run a safe connection test; a macOS settings UI can follow. The profile identifies a supported integration, its local working context, and its permitted actions. Tool availability and configuration errors are visible locally before the phone connects.
2. **Discover or create sessions.** An adapter lists existing sessions and, only if it supports and is permitted to do so, starts or resumes one. Existing, startable, and resumable are different states; a missing or detached session must not be shown as ready merely because a process-launch command exited successfully.
3. **Publish a bounded catalog.** The host sends authenticated clients only authorized, host-scoped descriptors: stable target/session identity, a display name, availability, supported input/output modes, and available typed actions. It does not publish private paths, environment variables, credentials, or raw adapter configuration.
4. **Select and act.** The terminal presents the host, tool, session, and available actions. Selection is confirmed for the current connection generation before the app claims Ready. Each action is separately checked against host policy; catalog visibility alone grants no execution rights.
5. **Return results.** Adapters provide typed output and lifecycle events with host, target, session, and reply identity. The terminal owns transcript presentation, pause/mute/replay, queueing, and arbitration when several hosts respond together.

The same flow can serve a pre-existing tmux session, a future Claude or Codex adapter, or another utility. An adapter should expose only operations it can actually confirm. If a tool has no reliable resume API, the host must not advertise resume as a capability.

The operator manages tool configuration on the Mac. The phone may select or invoke capabilities that the host offers, but it cannot install an adapter, choose an executable, set credentials, or silently change the host's working context. A future remote-admin feature would require its own authorization and confirmation design; it is not implied by this catalog.

## Contract boundary

The initial catalog should be data, not downloaded executable code or a tool-defined mobile UI. A versioned descriptor can carry:

- host and stable target/session identifiers, with user-facing names kept separate from identity;
- observed availability and a bounded reason when unavailable;
- supported input and output modalities (for example, text in and text/audio out);
- typed action flags such as select, send, interrupt, start, attach, or resume; and
- a policy-filtered readiness state tied to the current authenticated connection.

This is a proposed shape, not a committed wire schema. Adapter-specific launch arguments, shell commands, prompts, secrets, and arbitrary UI instructions must not cross the catalog boundary. The mobile app can render known generic actions and decline unknown versions or actions safely.

## Where the intelligence lives

Adapters own tool-specific detection, process or API lifecycle, session discovery, submission, interrupt semantics, and output capture. The host owns authentication, policy, catalog filtering, routing, and audit outcomes. The terminal owns audio hardware, capture/transcription, reply playback, attention management, and the visible selection state. A future host automation workflow may compose adapters, but it should not turn the daemon into one all-knowing agent object.

## Risks and decisions before implementation

- **Privilege:** launching a local agent may grant it access to the Mac user's files and network. Use explicit host-local profiles and per-action allowlists. Never accept an arbitrary client-supplied command, executable path, working directory, or environment. Consequential voice-origin actions also need the separate confirmation boundary in #89.
- **Session truth:** process creation is not proof that a TUI accepted a request or that a reply belongs to that request. Detached-session submission (#83), target selection (#75), and reply correlation (#94) need observable outcomes rather than optimistic status.
- **Credentials and privacy:** tool credentials stay in host-controlled facilities. Only safe descriptors and bounded diagnostic codes travel to the client; public issues and logs must not include private paths, endpoints, transcripts, or secrets.
- **Lifecycle:** decide how profiles survive host restarts, how duplicate launch is prevented, when idle sessions are stopped, and what the client sees during tool upgrades or crashes. A reconnect must revalidate the selected session rather than resurrect stale authorization.
- **Extensibility:** decide the smallest generic action set and versioning rules before adding vendor-specific adapters. Some tools may support an API, others only a PTY; the catalog must state the difference without forcing them into false parity.

QR pairing (#46) is separate: it helps a terminal discover and authenticate a Mac, but it does not configure that Mac's tools. Background reachability (#76) is also separate from tool bootstrap. Both can be added without changing which side owns tool integration.
