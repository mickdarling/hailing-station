# Native Listening and attention Settings (#1115)

This slice adds **Settings > Listening and attention** inside the existing default-on
`station.redesign.shell` launch gate. The [settings design](design/settings-design.md) supplies the group;
the page exposes only the current ambient owner's reading and the existing local echo-mask preference.
Native Form/navigation, system safe areas, wrapping and Dynamic Type replace illustrative frame geometry.

`ListeningSettingsOverview` receives the root's existing `HostConnectionStore` and a binding to the exact
`ambient.masksDuringReplies` key, default false. Its root wrapper is one `AppStorage` field above navigation.
The page creates no controller, capture view, resource owner or preference cache. Opening, updating and leaving
have no permission, network, capture, refresh, start/stop, observer-registration or preference-write effect.

The requested-on switch state and actual reported activity stay separate. No ambient owner means **Not reported**;
an owner off means **Ambient listening off**. Requested-on without streaming does not become a live microphone.
Pending reconnect, paused reason, moved-away handoff and streaming are distinguished; reconnect wording does not
confirm delivery during a transport gap. Existing handoff/stop descriptions are displayed without gaining their
actions. This page reports ambient listening only, and never claims every microphone is off. The separate local
capture-engine/Talk owner snapshot remains unavailable; route names and desired `isOn` do not replace it.

**Manage ambient listening in Station** asks only `navigation.apply(.select(.station))`. It does not open a
popover beneath a hidden page or change the destination. Start/resume and Stop remain with the current Station
controls; this page adds no audio command and offers no misleading “stop all microphones” action. Station retains
its foreground, permission, binding, capability and generation checks, notification behavior and owner lifetime.

The explicit mask intent writes only the supplied existing-key binding. The unchanged
`AmbientListeningCardContent` remains the application path: `onAppear` reads its shared `AppStorage` value and
`onChange` updates `echoGuard.masksDuringReplies`. This page neither duplicates that setter nor mounts the card.
When those controls are absent, the saved choice is applied when they are mounted, as before. It is a preference
for sending silence during replies, not confirmation of current masking or microphone shutdown. Headphone routes
may mask independently. All old non-shell controls and audio semantics remain unchanged.

RightyO attention presets, cue/follow-up rules, speaker thresholds, profiles, models and host configuration are
not readable/editable here. The page says so without presenting synthetic defaults or pretend live controls.
There are four production files; no HailCore/protocol/backend changes are part of this slice.

## Verification contract and execution record

The issue-linked PR's **Verification** record is the authoritative pointer for actual commands, results,
artifacts and exact-head independent review records. This document describes the stable contract and authored
coverage; it is not a mutable review/run-status ledger. Source authoring performed no build, test, lint,
app/simulator/service launch, real audio/microphone, network, review-service or push action.

- `NativeListeningSettingsTests` installs the actual adapter/Form with isolated `AppStorage` using the existing
  key/default. Mount/cover/return preserves both saved values and an absent key, creates no ambient owner and
  opens no scripted connector. Explicit preference/navigation intents persist only that binding and request
  Station without capture. A real ambient controller with synthetic permission/capture collaborators proves a
  requested start is not streaming, and mounting/removing the page preserves an already-streaming synthetic
  owner without permission, streamer, release, capture-stop, preference or navigation effects.
- `ListeningSettingsUITests` is read-only on an owned, unconfigured simulator: unreported request/activity,
  unchanged saved preference across Station management navigation, named Back, AX5/landscape width and reachability.
  It never taps listening, mask, playback, route or permission controls. Captures are retained when executed.
- `RedesignShellUITests` retains its complete hidden-Station identifier sweep. Its sensitive-word sweep excludes
  only the exact legitimate Listening index row ID/label in addition to the exact existing Privacy row; it does
  not broadly exempt listening/microphone wording or any hidden Station identifier.
- Qualification requires both app builds, focused native/UI cases, existing ambient pause/reconnect/handoff and
  echo-mask regressions, shell regression, lint/repository gates, and independent exact-final-head reviews.
  Synthetic collaborators and simulator UI do not establish physical VoiceOver or hardware audio continuity.
- `trace: partial`: the broader #1115 native adoption and proposed #1239 remote settings catalog remain separate.
  No deployment/TestFlight or new configuration authority is implied by this owner-backed page.
