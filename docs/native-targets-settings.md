# Native Targets Settings overview (#1115)

This slice adds **Settings > Targets** inside the existing default-off `station.redesign.shell` launch gate.
It uses three production files: `TargetsSettingsView.swift`, `RootView+Settings.swift` and
`RootView+Navigation.swift`. There is no new flag, HailCore change, selection owner or connection/persistence task.

The root supplies its current `destination`, availability, saved selection and the same `HostConnectionStore`.
The root's `destination` already validates the connection generation. The immutable projection uses
`DestinationControlState` and checks the exact saved host identity/URL and target ID/name against the current
ready target list. Its supplied generation comes from that current snapshot, not an independent authority.
Only a live matching target can be displayed as current. A saved identity remains **Saved · not confirmed**
through an unavailable/connecting/restoring state. An edited/removed Mac address does not borrow the new Mac's
name or adopt its targets. A friendly host-name change does not change the stored endpoint identity.

Configured Macs are local device entries. Their status and target list are observations, not permissions or proof
of delivery. Target names/liveness appear only when that Mac is ready and its target list has arrived. Offline
or pending lists stay unconfirmed. The page neither refreshes hosts nor opens a connection when visited.

**Choose destination in Station** emits only `StationNavigationIntent.select(.station)`. It does not set the
destination, alter remembered identity, present a browser or touch the hidden Station's popover binding. The user
then taps the visible Station destination control, which retains its existing acknowledgement and identity gates.
**Mac Setup** explicitly pushes the unchanged `ConnectivityLabView`, with the same store and root `persist`
callback. Its existing Add/Edit/Connect/Disconnect actions remain explicit. Devices and non-shell links are unchanged.

This adopts the [#1239 Targets design](design/settings-design.md) only where current owners support it. The
synthetic frame's host file editors, tiers, policy grants/guards, route aliases, administrative credentials and
secure pairing are not implemented here. No illustrative defaults, editable JSON or authorization channel is added.
The native Form uses system safe areas, inline iOS title, wrapping text and Dynamic Type, with short helper copy.

## Acceptance and traceability

- `TargetsSettingsStateTests` covers an actual confirmed identity versus saved-only state, missing saved identity,
  stale connection generation, changed endpoint URL, reused target ID with a different name, stopped/unlisted
  targets, friendly Mac rename, identical names on another Mac, and unavailable/restoring summaries. These are
  synthetic snapshot/projection tests; they never select targets or rewrite saved state.
- `NativeTargetsSettingsTests` hosts the actual owner-to-Form adapter through a test-only symlink. With a scripted
  connector and an already configured disconnected Mac, it checks mount/cover/return without connecting, changing
  snapshots, opening Setup or emitting navigation. A separate test exercises the production intent mapper: exactly
  one Station-navigation request, no connection or store mutation. Native static-label publication is not assumed.
- `TargetsSettingsUITests` authors read-only navigation on an owned, unconfigured simulator: current/unconfigured
  labels, explicit Mac Setup and return, Station navigation without opening its browser, AX5, landscape, reachable
  setup/Back controls and planned synthetic screenshot attachments. It saves no Mac and taps no connection,
  target, permission or audio action. Directory-based XcodeGen source entries discover the app and UI-test files.
- Pending host gates: iOS/Mac compile, source lint, the focused suites above, `DestinationControlStateTests`,
  `DestinationSelectionTests`, existing root destination/ambient-selection and shell tests, then required repository
  verification and exact-head independent reviews. The production root wiring and real Setup destination require
  app compilation; package tests exercise the actual shared renderer/projection without those peripheral app types.
- No build, test, lint, simulator, audio, service, network, deployment or review service was executed while authoring.
  Runtime passes and screenshots remain pending. `trace: partial`: #1115's remaining native adoption, authorized
  settings service and host/target policy catalog, physical VoiceOver and capture/listening continuity are deferred.
  This source-only slice performs no TestFlight delivery, stage definition or automatic flag change.
