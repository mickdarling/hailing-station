# Host-owned session I/O and voice pipeline (proposal)

Status: design proposal for [#132](https://github.com/mickdarling/hailing-station/issues/132), not a description of shipped behavior. Related mobile presentation is [#133](https://github.com/mickdarling/hailing-station/issues/133); Codex feasibility is [#134](https://github.com/mickdarling/hailing-station/issues/134).

## Decision and boundary

Hailing Station's Mac host, not Claude Code or another target, must own the round trip. A target may produce text, structured events, audio, images, or no output; it must not need instructions to invoke `haild reply`. The host observes what the target actually emits, applies disclosure and speech policy, and—after per-terminal authentication and confidentiality are implemented—publishes typed events to the authorized iPhone/iPad terminal. The terminal remains responsible for microphone capture, on-device speech recognition, visible conversation, playback, and arbitration across hosts. A generic provider adapter—not a tmux-shaped mobile protocol—connects the host to a local tool.

“Platform-agnostic” here means **target/provider-agnostic**: Claude Code, Codex, Hermes, another CLI, or a non-AI utility may each be integrated by an adapter. The initial host and terminal operating-system scope remains macOS and iOS/iPadOS. A later hosted relay or other operating systems are not implied.

## What exists today

The terminal sends finalized recognition text over the current **unauthenticated, non-TLS personal-testing WebSocket**. `HostSession` routes it through host policy to the selected adapter. `PersonalTerminalAuthorizer` allows certain frame types for every connected peer; the Hello device name is client-supplied and unverified. A private-network address, target allowlist, and frame-type policy are not terminal authentication. The only registered adapter is tmux; it sends literal keys and Enter. Its `capture` operation is a snapshot and is not subscribed to the live reply path. The present spoken round trip relies on the target voluntarily invoking `haild reply`, which uses vbsay and publishes associated text/PCM frames via a private local socket. Thus successful delivery to tmux does **not** prove the TUI accepted the prompt, and arbitrary target output does **not** automatically reach the device. The explicit reply command remains useful for manual/system announcements, but should not be the normal provider response path.

## Codex session boundary

Do not assume `codex resume` exposes every session seen in the Codex desktop app. The [Codex CLI documentation](https://learn.chatgpt.com/docs/codex/cli) describes resume as reopening saved local chats, normally scoped to the current repository or a search across local chats. The [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) offers `thread/list` and non-resuming `thread/read`, but its default list includes only `cli` and `vscode` sources; clients must explicitly request other source kinds such as `appServer` or `exec`. These are documented access mechanisms, not a guarantee that a separate host process can observe every active desktop, cloud, or remote-host task in real time or safely append to one.

On this development Mac, a local desktop Codex task has a local session record; that proves partial shared local storage, **not** universal discovery or safe concurrent ownership. The first Codex pilot should use an isolated, host-owned session via a documented structured interface. [#134](https://github.com/mickdarling/hailing-station/issues/134) must separately test local desktop discovery/read/live events, cloud and remote visibility, and whether any approved bridge can control an already-active app session. No parser of private rollout files and no `resume` takeover of a live user's task should become the product interface. Keep tmux as a fallback for tools whose only supported surface is a terminal.

## Logical flow

```text
iPhone/iPad audio -> on-device STT -> final transcript (authentication/provenance required)
  -> Mac host: select target, authorize action, assign turn, dispatch via adapter
  -> provider/session: observed acceptance, progress, user-visible output, completion
  -> host: normalize, correlate, redact/filter, choose display/spoken rendering
  -> host TTS (vbsay initially) or validated provider audio -> typed WebSocket events
  -> iPhone/iPad: ordered timeline + reply queue + playback/replay/mute
```

The host may answer bounded local intents itself before dispatching to an agent ([#108](https://github.com/mickdarling/hailing-station/issues/108)). Semantic classification is a proposal selector, never an authorization decision. A future local model is optional; provider selection and event transport must work without one. A provider's generated wording must not be treated as evidence that an action occurred.

## Host components and contracts

1. **Local profiles and catalog.** An operator configures adapter profiles, prerequisites, permitted session discovery/start/resume/send/interrupt actions, display names, disclosure policy, and speech policy on the Mac. Once terminal authentication exists, the authorized client receives only policy-filtered descriptors, not commands, paths, environment, prompts, or credentials ([#105](https://github.com/mickdarling/hailing-station/issues/105)). A target capability says whether output is structured, terminal-observed, audio-capable, and correlated; unsupported operations are absent, not simulated.
2. **Input coordinator.** Allocate an opaque turn ID after finalization, bind it to host, selected target binding, paired-device/utterance provenance, and connection generation, then authorize and dispatch. Report *sent*, *accepted if observable*, *running*, *interrupted*, *failed*, and *finished* separately. A successful adapter write is only *sent*. Consequential voice-origin actions require separate confirmation before dispatch ([#88](https://github.com/mickdarling/hailing-station/issues/88), [#89](https://github.com/mickdarling/hailing-station/issues/89)).
3. **Provider adapter.** A versioned interface should offer capability discovery, session listing, authorized lifecycle actions, text delivery, interrupt, and an asynchronous stream of observed events. Structured API events are preferred. A tmux/PTY adapter may instead sample a pane or stream a controlled PTY, but must bound output, strip terminal controls, deduplicate redraws, detect binding changes, and mark ambiguous turn attribution. It must not infer final answer or completion solely from a prompt-looking screen. Preserve the existing tmux adapter while its observer is introduced incrementally.
4. **Event normalizer and reply policy.** Convert provider events into a common envelope. Keep *observed target text*, *Hailing Station-generated summary*, and *spoken rendition* distinct. Default speech to confirmed user-visible assistant/final output or deterministic host responses; do not read every tool log, escape sequence, spinner, secret, or internal reasoning aloud. Optional summarization needs provenance and must never fabricate observed success. Errors and timeouts produce explicit host-owned text rather than a synthetic agent answer.
5. **Media renderer.** vbsay can remain the initial Mac TTS engine behind a replaceable `SpeechRenderer` interface, using the existing PCM/reply stream. The host need not manufacture audio if a provider supplies an approved, validated audio stream; pass it through with identity, format, size, and completion checks. Mobile fallback speech remains an explicit capability, not an implicit duplicate. Measure first/last phoneme fidelity separately ([#126](https://github.com/mickdarling/hailing-station/issues/126)).
6. **Publisher and terminal.** Publish bounded, ordered event batches with backpressure. The mobile app shows a voice-first compact card and an expandable *user-visible session timeline* with actual text, source/provider labels, send/accept/progress/error status, and audio controls. It never receives private adapter configuration or hidden provider reasoning. Playback queueing remains on-device across multiple Macs ([#6](https://github.com/mickdarling/hailing-station/issues/6), [#133](https://github.com/mickdarling/hailing-station/issues/133)).

### Proposed event envelope (not yet a wire schema)

| Field | Purpose |
| --- | --- |
| `host`, `target`, `provider`, `session` | Stable source and selected binding; display names are separate. |
| `turnId`, `utteranceId`, `replyId` | Distinguish captured input, provider work, and one display/audio reply. An event may be explicitly *unassociated*. |
| `eventId`, `sequence`, `observedAt` | Deduplication, ordering, and reconnect replay without implying wall-clock causality. |
| `kind` | `input.sent`, `input.accepted`, `status`, `text.delta`, `text.final`, `tool.activity`, `audio.chunk`, `media`, `completed`, `interrupted`, or `failed`. |
| `visibility`, `speechDisposition` | Whether a safe, user-visible payload may be shown or spoken; unsupported/private events stay host-side. |
| `payload`, `format`, `final` | Bounded typed content and media completion; unknown versions/kinds fail safely. |

The existing reply descriptor and frame identity remain authoritative for audio/text association. This proposed envelope must be reconciled with protocol v1 and [#94](https://github.com/mickdarling/hailing-station/issues/94), not silently added as an incompatible field. A reconnect may replay acknowledged, retained user-visible events, but an old response must never complete a newer turn. Persistence and retention belong to [#99](https://github.com/mickdarling/hailing-station/issues/99).

## Adapter integration profiles

| Profile | First source of truth | Host may claim | Must not claim |
| --- | --- | --- | --- |
| Generic tmux / terminal TUI | Bound pane/PTY observations plus process lifecycle | Text was injected; observed screen changes; explicit completion only with a reliable signal | That Enter was accepted, a redraw is a new reply, or a pane snapshot is a structured agent turn |
| Host-owned Codex session | Documented CLI/App Server structured events, subject to [#134](https://github.com/mickdarling/hailing-station/issues/134) | Capabilities demonstrated in an isolated session | Visibility/control of every desktop, cloud, remote, or concurrent session |
| Claude Code and other agent CLIs | Their documented structured API if available; otherwise a supervised PTY | Only capabilities proven for the configured version/profile | That a provider-specific hook is required for Hailing Station output |
| Hermes, Clawdbot/other tools, and utilities | A separately validated adapter profile | Its explicitly tested action/event subset | Parity with tmux or Codex merely because it has a command line |

Provider names here identify desired coverage, not shipped integrations or claims about their current APIs. Each adapter needs a short capability/permission test matrix and version check. Multiple profiles can coexist on one host; the terminal does not embed provider logic.

## Failure, safety, and privacy invariants

- A **reply-bearing output** frame must carry host/target provenance and a reply identity; its audio segments also share the declared stream identity. The host validates the target binding before publication. Input and control frames retain their own event/utterance/turn identities as applicable, without a fabricated reply. Unassociated ambient output may carry source and event identity but no invented turn or reply association; it can be shown as such if policy allows, never used to authorize or complete a mobile request.
- No automatic shell execution, process launch, or provider command is accepted from mobile as a free-form string. Host profiles and per-action policy authorize each operation. A voice transcript is data, not an instruction to the Hailing Station daemon.
- Output capture is not blanket exfiltration. Apply per-profile disclosure policy, bounded size/rate, secret/path filtering, and explicit user-visible versus internal event distinctions before network publication. Do not store real transcripts or tool output in public fixtures, issue comments, or ordinary diagnostics. Hidden reasoning is not a session transcript feature.
- Host-owned session capture can expose substantially more text than the existing manual-reply path. Do not publish it to a reachable personal-testing listener as though it had verified recipients: per-terminal authentication and transport confidentiality in [#7](https://github.com/mickdarling/hailing-station/issues/7) and [#21](https://github.com/mickdarling/hailing-station/issues/21) are prerequisites for broader session-output delivery.
- Tool crash, parser ambiguity, missing structured events, stale session binding, TTS failure, device disconnect, and output queue overflow produce truthful states with bounded recovery. Do not speak a success statement on mere dispatch.
- Backpressure may coalesce progress/deltas but cannot silently drop final/error/cancellation markers. On reconnect, identify gaps; do not replay audio twice. Keep audit metadata privacy-preserving.

## Sequence and proof

1. **Contract and correlation:** settle [#132](https://github.com/mickdarling/hailing-station/issues/132)'s adapter/event split and [#94](https://github.com/mickdarling/hailing-station/issues/94)'s turn identity. Add synthetic provider fixtures, no private conversation data.
2. **One host-owned output slice:** observe a controlled tmux session, transmit a safe text final and vbsay speech without `haild reply` being invoked by the target. Preserve manual reply injection. Test no output, redraws, duplicate/late output, detached TUI, and physical iPhone/iPad playback. A structured test adapter can prove semantics before the tmux heuristic is trusted.
3. **Inspectable mobile session:** implement [#133](https://github.com/mickdarling/hailing-station/issues/133) with source-labeled timeline, truthful progress, full *user-visible* text, and bounded history. Integrate [#87](https://github.com/mickdarling/hailing-station/issues/87), then [#99](https://github.com/mickdarling/hailing-station/issues/99) for resume.
4. **Codex pilot:** complete [#134](https://github.com/mickdarling/hailing-station/issues/134) and implement only its verified supported subset. Other provider adapters follow the same contract. [#105](https://github.com/mickdarling/hailing-station/issues/105) supplies host setup and catalog, not a vendor-specific mobile workflow.
5. **Then broaden:** local bounded intents [#108](https://github.com/mickdarling/hailing-station/issues/108), additional providers, and eventually more hosts. Multi-host routing is a separate later milestone, but identities and mobile audio arbitration are multi-host-safe now.

Exit evidence for the first slice is a physical-device round trip in which the tool emits ordinary output, the host captures it independently, the phone displays the exact safe user-visible text, and vbsay audio plays with the same reply identity. The record must separately report what was observed, what was inferred, and which steps were not validated.
