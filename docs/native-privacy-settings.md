# Native Privacy Settings group (#1115)

This slice adds **Settings > Privacy** inside the existing default-off `station.redesign.shell` launch gate.
It uses four production files: `PrivacySettingsView.swift`, `RootView+Settings.swift`, `RootView+Navigation.swift`
and `RootView.swift`. The fourth file keeps shared device preferences and request-error state above navigation.
There is no new feature flag or HailCore change. Old station controls remain in place.
The shell's Settings list is a private computed view, preserving all rows/actions while keeping the section
dispatch function bounded. Its title remains the existing Settings section title; no navigation owner moves.

The native Form receives values and explicit intents from the current root. The selected Mac and connection are
identified separately from this device's global Overheard preferences. Privacy reads the existing
`HostConnectionStore.privacySwitch` contract; private requires a current host confirmation. Pending requests,
timeouts, unknown/offline/unsupported states and **Privacy on · listening unavailable** remain distinct. A local
one-second timeline re-evaluates expiry without making requests. When ambient audio is not streaming to this Mac,
the page does not reuse wording that would claim recording or active listening merely from a privacy flag.
The rendered reason collection omits a secondary sentence identical to the primary status detail. Pending still
keeps its original unavailable reason and disables requests; the waiting sentence is published only once.

An explicit privacy intent is rechecked against the displayed host, connection generation, existing capability
and existing switch availability immediately before `setPrivacy`. It never optimistically confirms privacy.
The owner retains request errors across navigation; an older request cannot overwrite a newer request's result.
Privacy callbacks explicitly retain main-actor isolation. A duplicate pending tap leaves the active request ID
intact. Privacy-send errors and Overheard-validation errors are separate: a completed Privacy send clears only
the Privacy error; an accepted Overheard change clears only its validation error. A completed send still waits
for the host's confirmation before the page can claim privacy.
Stop listening delegates only to the existing ambient owner's `turnOff`, when on. It does not imply deletion or
turning off every possible microphone user. No start/resume action is added.

Overheard uses the existing `overheard.show`/`overheard.whose` keys and defaults. Saved preferences are separate
from the scope currently requested by the owner; neither is host-delivery confirmation. An explicit change calls
the existing `setOverheardScope`, which targets **every ready capable Mac**, not only the selected Mac. Its
same-value guard prevents a second scope send when the unchanged station control observes the same preference
change. Invalid scope values cannot silently enable or broaden Overheard. The old `OverheardSettingsView` is not
embedded because its `onAppear` applies scope. The new page has no opening/closing preference, privacy, network,
permission, capture, refresh or cleanup effect. Flag-off startup gains no application task or initial send.

The [#1239 settings design](design/settings-design.md) remains a proposed complete catalog. This slice does not
implement the synthetic frame's 82 settings, host diagnostic acceptance, timers, meeting/media/recording/retention
policy, reset or remote configuration authorization. These are unavailable, not filled from illustrative defaults.
Appearance remains separate. Native safe areas, inline iOS navigation, wrapping and system Dynamic Type are used.

## Acceptance and traceability

- `PrivacySettingsOwnerTests` compiles the actual root adapter through its existing test symlink, with an
  observable synthetic preference fixture and scripted transports. It covers mount/update/removal with no writes
  or sends; explicit scope changes and the real same-value guard; invalid scope rejection; unsupported and stale
  request rejection; confirmation/pending/expiry/unavailable states; and a declined transport request retained as
  an error. No audio backend, permission request or real network socket is used. Native mounting checks effects;
  it does not claim that in-process static Form labels publish accessibility values or prove font scaling.
  The full-frame baseline waits for both the initial Off scope and handshake list-targets command. Strict frame
  equality and zero-write/scope assertions remain intact. Pending projection checks one rendered reason row while
  retaining the raw disabling reason; distinct non-pending availability reasons remain visible.
- `PrivacySettingsErrorTests` covers independent error retention/recovery and a held-send fixture. It checks that
  a retry retains the previous Privacy error until sending succeeds, that Overheard recovery cannot hide a Privacy
  error, and that a duplicate pending tap cannot invalidate the first send's eventual error or enqueue a second send.
- `PrivacySettingsUITests` is read-only navigation on an owned, unconfigured simulator. It checks the real disabled
  unknown privacy control, disabled Stop, unchanged Overheard preference/request scope, return navigation, AX5 and
  landscape reachability. Typed links/sidebar/tab queries, hittability waits, named Back controls and bounded
  directional drags follow the corrected Audio harness. Preference comparisons use the current values on that
  simulator; `-reset-station-state` does not reset Overheard preferences. The in-process fixture proves zero writes
  on initial opening. Simulator screenshots qualify layout only, not physical-device behavior.
- `RedesignShellUITests` retains its full hidden-Station identifier sweep. Its sensitive-word sweep exempts only
  the new exact `station.settings.privacy` row labelled **Privacy**; every other sensitive label remains checked.
- Verification includes iOS/Mac compile, source lint, focused native/UI suites, existing privacy switch/unavailable/
  Overheard suites and shell tests, required repository checks and exact-head independent reviews. The PR's
  **Verification** section records current commands, results, captures and reviews. Initial source authoring and
  source-review repairs ran no builds, tests, lint, simulators, services, microphone, network or deployment actions.
- `trace: partial`: #1115's remaining native adoption, full authorized settings catalog, physical VoiceOver and
  physical capture/listening continuity require separate qualification. This slice defines no TestFlight delivery,
  A/B/C stage or automatic flag change.
