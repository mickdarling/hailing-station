# Native Advanced and diagnostics Settings (#1115)

This slice adds **Settings > Advanced and diagnostics** inside the existing default-on
`station.redesign.shell` launch gate. It implements the local diagnostic controls and existing tools from
the [settings design](design/settings-design.md), using a native Form and the system's navigation and safe areas.
It does not implement the proposed remote configuration catalog shown in the design frames.

The page observes the same `StationResources`-owned `DeviceDiagnostics` instance as the existing station switch.
Its toggle sends one explicit `setDiagnosticsEnabled` intent, which calls that owner's existing `setEnabled`.
There is no second preference wrapper, diagnostics owner, observer, event reader, refresh, subscription or
opening/closing action. Logging remains off by default. The existing setter persists the explicit choice;
enabling begins with the build metadata event and disabling clears this device's in-memory buffer and advances
its generation. Disabling does not erase events previously received by a Mac.

The page shows the owner's buffered-event count. Its collecting-Mac label comes from
`HostConnectionStore.diagnosticsCollectingHost`: a ready connection advertising the existing diagnostics
capability. That eligibility is not proof that each event has been delivered or retained. With no eligible Mac,
logging may keep recent events in the existing bounded in-memory buffer. No new host operation is introduced.
The existing closed diagnostic vocabulary excludes audio, transcripts, reply text and request contents.

Labs and Turn-taking links reuse the existing root-owned audio/playback/gate references. Labs retains its
launch-only redesign switches and recognizable development actions; opening Advanced never invokes a probe,
transcription tool, capture action or route action. Public version/build identifiers come from `StationBuildInfo`
with a separate `settings.advanced.build` identifier, leaving the hidden-station footer contract intact.
The old non-shell links, diagnostics card and preferences are unchanged.

Host/CLI/model/import/export editors, diagnostic log export, arbitrary commands and host retention deletion are
not exposed. They require separately scoped owner and authorization contracts. Unsupported host settings have
plain explanatory text, with no fabricated saved/effective values or inactive Apply buttons.

## Verification and traceability

- `NativeAdvancedSettingsTests` mounts the actual owner-to-view adapter with an isolated diagnostics owner in
  both enabled and disabled states, then covers it through native navigation. It asserts owner identity,
  unchanged enable/generation/buffer/preferences, no new system observers and no pending-event callbacks.
  An explicit-intent test verifies the actual existing setter persists enable and clears the same owner's
  buffer on disable. These fixtures use no station root or real audio backend.
- `AdvancedSettingsUITests` uses the real shell opt-in/relaunch path on an unconfigured owned simulator.
  It verifies the new toggle and old station toggle share state, visits existing tools, and checks AX5
  landscape navigation and width. Only the diagnostics opt-in is changed; no microphone, probe or route action
  is tapped. Typed section/link and named Back lookups wait to be hittable; rotation geometry is read on the
  main actor, and bounded directional drags avoid reading nonexistent elements' frames. Synthetic screenshots
  are retained in the UI results when executed.
- Pending: native tests, iPhone/iPad UI tests, both app builds, existing diagnostics/shell regressions,
  lint and repository verification, then independent exact-head Codex and Claude reviews.
- No build, test, lint, simulator, microphone, audio, service, network, push or external review was performed
  while authoring this slice. The test declarations are authored coverage, not execution evidence.
- `trace: partial`: the broader #1115 redesign and proposed #1239 settings catalog remain incomplete. Physical
  VoiceOver and capture/listening continuity are separate qualification; no deployment or TestFlight is implied.
