# Architecture overview

Hailing Station separates personal-device concerns from host application concerns.

```text
microphone -> Apple-device terminal -> network transport -> Mac host -> target adapter
speaker   <- playback arbitration   <- media and events       <-          <-
```

## Terminal

The iOS or iPadOS application owns the audio session, input and output selection, speech capture, playback, per-source queues, interruptions, mute, pause, replay, and transcript presentation. It may connect to multiple hosts concurrently.

## Host

Each Mac runs a small daemon. Today its personal-testing listener negotiates the protocol, applies target policy, lists permitted targets, and routes accepted input through a tmux adapter. It does **not** authenticate terminal identities or provide TLS. The intended design adds those controls and returns provider-neutral typed output events; adapters are not limited to terminals or AI tools.

The intended host-owned capture and rendering contract is detailed in [host-owned session I/O](host-owned-session-pipeline.md). Today, ordinary tmux output is **not** automatically captured and returned: the working spoken path depends on the target invoking `haild reply`. The proposal replaces that dependency with observed, normalized provider events while retaining the explicit reply command for manual announcements.

The Mac is also the proposed bootstrap and configuration authority for its local tools. An operator configures adapters and permitted session actions on that Mac; after terminal authentication is implemented, the host can advertise a bounded, host-scoped capability catalog to authenticated terminals. The client can discover and select what the host offers, but does not know how to launch Claude, Codex, tmux, or any other local tool. Advertisement is not authorization: starting, attaching to, sending to, and interrupting a session each remain policy-controlled actions. See [host bootstrap and capability catalog](host-bootstrap.md) for the proposed flow and open design questions (#105).

## Protocol

`HailProtocol` defines the shared frame model. Payload types remain explicit so that text, audio, control events, and future media channels can be authorized and handled independently. The transport must not infer privileges from a target's display name or from network reachability.

## Trust boundary

Possession of a private-network address is not identity. Terminal and host identities, mutual authentication, replay resistance, target policy, size limits, sanitization, and audit events are separate controls. A network overlay may reduce exposure but is not the application security model.

In the current personal-testing mode, a peer that can reach the listener can attempt protocol negotiation. The client-supplied device name is not verified identity, and frame-type authorization plus a target allowlist do not authenticate the peer. Keep the listener constrained to a trusted test environment; per-terminal authentication and transport confidentiality remain open requirements in [#7](https://github.com/mickdarling/hailing-station/issues/7) and [#21](https://github.com/mickdarling/hailing-station/issues/21).

## Naming

The package currently uses `Hail`-prefixed Swift modules and a `haild` daemon executable. These stable implementation names may outlive the project rename and do not affect the user-facing Hailing Station identity.
