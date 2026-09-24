# Architecture overview

Hailing Station separates personal-device concerns from host application concerns.

```text
microphone -> Apple-device terminal -> authenticated transport -> Mac host -> target adapter
speaker   <- playback arbitration   <- media and events       <-          <-
```

## Terminal

The iOS or iPadOS application owns the audio session, input and output selection, speech capture, playback, per-source queues, interruptions, mute, pause, replay, and transcript presentation. It may connect to multiple hosts concurrently.

## Host

Each Mac runs a small daemon. The daemon authenticates terminals, applies policy, lists permitted targets, routes accepted input through target adapters, and returns typed output events. The first adapter addresses tmux sessions; adapters are not limited to terminals or AI tools.

The Mac is also the proposed bootstrap and configuration authority for its local tools. An operator configures adapters and permitted session actions on that Mac; the host then advertises a bounded, host-scoped capability catalog to authenticated terminals. The client can discover and select what the host offers, but does not know how to launch Claude, Codex, tmux, or any other local tool. Advertisement is not authorization: starting, attaching to, sending to, and interrupting a session each remain policy-controlled actions. See [host bootstrap and capability catalog](host-bootstrap.md) for the proposed flow and open design questions (#105).

## Protocol

`HailProtocol` defines the shared frame model. Payload types remain explicit so that text, audio, control events, and future media channels can be authorized and handled independently. The transport must not infer privileges from a target's display name or from network reachability.

## Trust boundary

Possession of a private-network address is not identity. Terminal and host identities, mutual authentication, replay resistance, target policy, size limits, sanitization, and audit events are separate controls. A network overlay may reduce exposure but is not the application security model.

## Naming

The package currently uses `Hail`-prefixed Swift modules and a `haild` daemon executable. These stable implementation names may outlive the project rename and do not affect the user-facing Hailing Station identity.
