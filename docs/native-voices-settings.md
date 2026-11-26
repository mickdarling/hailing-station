# Native Voices and replies Settings (#1115)

This slice adds **Settings > Voices and replies** inside the existing default-on
`station.redesign.shell` launch gate. It is a native, read-only Form using system safe areas, an inline iOS
navigation title and wrapping Dynamic Type. It implements the existing local portion of the
[settings design](design/settings-design.md); it does not implement the proposed host voice map.

`VoicesSettingsOverview` observes the root's existing `ReplyPlaybackController.segmentSettings`. It projects
the current pause after a played segment marker, sustained sound duration and sound-level threshold with
seconds/dBFS units. These are current controller values, not a second saved-state cache. There are no playback,
microphone, preference, opening/closing, refresh or subscription actions in either new view. Observing a value
does not save it or replace the controller. Sustained sound duration remains read-only here and in the current
Turn-taking tool; any sustained sound can qualify, so it is not a speaker-recognition threshold.

The explicit Turn-taking link receives the same root-owned playback controller and
`echoGuard.segmentOnsetGate` as the existing Settings/Station tool. That existing tool remains the only editor
for its supported pause and sound-level settings. This slice changes neither segment semantics, persistence
format, pending timers nor owner lifetime. The old non-shell and Settings Turn-taking destinations are unchanged.

Reply voice generation belongs to the Mac. The app cannot read or edit a host default, per-target or update-type voice
assignment and confirms none. The proposed #1124 mapping/allowlist/fallback contract remains unimplemented;
this page shows concise explanatory text rather than a pretend editable assignment, named default, profile
preview, generation speed, EQ or local playback-rate control. No live reply identity or playback buttons are
shown, avoiding an unrelated/uncorrelated reply-control authority path.

## Verification and traceability

- `NativeVoicesSettingsTests` hosts the actual owner-to-view adapter with a real playback controller and a
  synthetic player spy, using default and custom settings including the 0.05-second onset boundary. Mounting,
  an owner update and navigation away must preserve the same owner, settings, playback generation/status and
  idle control state. Every player action is recorded and must remain absent; the persisted settings reading
  must not change. This does not schedule audio or instantiate a real player/backend.
- `VoicesSettingsUITests` uses the real shell opt-in/relaunch path on an unconfigured simulator. It reads the
  three unit-labelled values, checks the unavailable host map explanation, visits and returns from the existing
  Turn-taking tool and compares the unchanged readings. It also visits the original Settings tool path and
  checks AX5/landscape width and Back reachability. No playback, microphone, route or preference control is tapped.
  Typed link/section queries, named Back buttons, hittable waits, main-actor geometry polling and bounded
  directional drags follow the current Audio test conventions. Screenshots are retained when tests run.
- Both app builds, focused native/UI suites, existing reply-segment/settings/shell regressions, lint and
  repository checks, and independent exact-head Codex then Claude reviews remain pending.
- No build, test, lint, app/simulator/service launch, audio, microphone, network, review service or push was
  performed while authoring. Test declarations are planned coverage, not execution or hardware evidence.
- `trace: partial`: broader #1115 adoption, #1239 settings catalog and #1124 voice assignments remain separate
  work. Physical VoiceOver/audio continuity and deployment authorization are not established by this slice.
