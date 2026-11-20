# Native Audio Settings overview (#1115)

This slice adopts a read-only **Settings > Audio** page from the [settings design](design/settings-design.md).
It is reachable only inside the existing `station.redesign.shell` launch gate, which remains off by default.
The Labs toggle takes effect after relaunch. No new flag, remote settings channel or route authority is added.
Turning the shell off also hides this overview; there is no independent Audio-group toggle in this slice.

`StationResources` still owns the one `AudioRouteModel` above navigation. The new root adapter observes that
reference, projects it through `AudioRoutesSheetState.resolve`, and supplies the same reference to the existing
`AudioDiagnosticsView`. Neither the overview nor its adapter queries a controller, subscribes, refreshes,
activates, retries, chooses a route or performs cleanup when opened or closed.

The native `Form` separates active microphone, saved preference, observed output, state and failures. A matching
preference remains visible even though the shared resolver omits its redundant preferred-detail string. Inactive
audio never presents a stale microphone or output as live. **System output** identifies no confirmed speaker;
**Automatic · no preference reported** does not claim that a named preference was successfully loaded or applied.
The page preserves the owner's session-update wording when it differs from the current route-state summary.

**Audio session tools** is an explicit navigation link to the existing tool. Its refresh and activation-ownership
cleanup behavior is unchanged. Route/input selection, Bluetooth HFP options, system output selection and explicit
Activate/Deactivate controls remain there. On Mac the existing output destination opens system Sound settings.
The old non-shell station tool, Labs and Turn-taking destinations are unchanged. Appearance remains a separate
slice; this page adds no Appearance entry or live conversation sizing.

The corrected design frames are synthetic planning references, not native captures or a shipped 28-field editor.
The native page uses the system safe areas, inline iOS navigation title, wrapping text and system Dynamic Type.
It does not draw a status bar, cutout or home indicator. Host configuration, capture parameters, remote editing,
reset/apply/undo and the rest of the catalog remain deferred under #1115 and the settings design.

## Acceptance and traceability

- `NativeAudioSettingsOverviewTests` hosts the actual model-to-view adapter and Form with a synthetic owner spy.
  It checks inactive/stale routes, a distinct unavailable preference and retained apply failure, an owner update to
  confirmed input, a matching preference, an active session without reported routes, and zero controller
  reads/subscriptions/mutations on mounting, updates
  or removal. Large and AX3 text categories exercise the inactive reading. No hardware backend is used.
  Its bounded, deduplicated accessibility walk follows the native Appearance fixture's typed getters and
  navigation-order/backing/contents children. Static Form-label publication still needs runtime qualification;
  unavailable rendered values must fail the assertions, not become a model-only substitute.
- `AudioSettingsOverviewUITests` follows the existing Labs opt-in/relaunch path on an unconfigured simulator,
  reads the real overview, visits and leaves the unchanged Audio session tool, and returns to Settings/Station.
  It also checks AX5 text, landscape width and reachable navigation/tools. It taps no audio or permission action.
  Sidebar sections use their tappable static-text titles, phone tabs use buttons, and both wait to be hittable.
  Future runs retain synthetic screenshots in their test results. The existing `RedesignShellUITests` remains the
  default-off/launch-only/hidden-Station regression gate.
- Pending host checks: compile both app targets; run these focused native and simulator suites plus the existing
  shell and `AudioDiagnosticsLifetimeTests`; check source lint and the repository verification/traceability gates.
  The directory-based XcodeGen app/UI-test source entries and test-only Swift-package symlinks include these files.
- Runtime results, screenshots and independent exact-head reviews are **pending**. No build, test, lint, simulator,
  microphone, service, deployment or review service was executed while authoring this slice.
- `trace: partial`: #1115 still includes native component adoption beyond this overview, capture/listening survival
  on physical devices, physical VoiceOver and remaining settings catalog/authorization/activation work. Synthetic
  or simulator coverage does not establish hardware audio continuity. TestFlight stages and delivery authorization
  are separate rollout decisions; this slice defines no A/B/C stages or automatic flag changes.
