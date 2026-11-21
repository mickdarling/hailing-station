# Native Notifications and Updates Settings (#1115)

This slice adds **Settings > Notifications and updates** under the existing default-off
`station.redesign.shell` launch gate. Its four production files are `NotificationsSettingsView.swift`,
`RootView+NotificationSettings.swift`, `RootView+Navigation.swift` and `StationSceneState.swift`. The last file
defines the existing `StationResources`; one stored model there keeps the reading above every navigation branch.
No line is added to `RootView.swift` or the shared `RootView+Settings.swift`.

The page starts **Not checked**. Construction, opening, closing, rotation and returning perform no system query.
Only an explicit **Check access** intent invokes the reader. The adapter calls
`UNUserNotificationCenter.getNotificationSettings` and reads `authorizationStatus`. It does not request permission,
register remote notifications, change a delegate/settings, post notifications, play sound or touch capture.
The existing listening-stop notifier and its permission/lifecycle path are unchanged.

The SDK's completion objects stay inside that callback; only an app-owned Sendable status crosses to the main-actor
model. Not determined, denied, authorized, provisional, temporary App Clip access and unknown future raw statuses
remain distinct. The inspected SDK marks ephemeral authorization unavailable on Mac, so that case is mapped only
on iOS; unknown available-platform values remain Unknown. No live OS settings were queried while inspecting the SDK.

One read may be in flight at a time; repeated taps cannot start overlapping queries. A completed reading remains a
**last-check snapshot**, including while another explicit read is pending. The page does not poll or refresh on
return. Cancellation discards its result after the callback settles; the next explicit check can then proceed.
The task holds the owner weakly, so an old window's late completion cannot update a replacement owner. Hiding the
page preserves the same model and does not cancel an already explicit read. Reading access is not alert-delivery,
host-update configuration or proof that a spoken update was heard.

Host update cadence, source policy, enrollment and queue/expiry configuration remain Mac-host settings, unavailable
to edit here. The [#1239 design](design/settings-design.md) still requires an authorized host settings contract.
No synthetic Enable updates/Task progress controls, quiet-hours defaults or remote configuration are added.
The native Form uses system safe areas, inline iOS navigation, wrapping and Dynamic Type.

## Acceptance and traceability

- `NotificationAccessModelTests` uses a held fake reader: inert initialization, one explicit read/duplicate guard,
  subsequent checks, cancelled-result rejection, released-owner/stale completion isolation, known SDK-enum mapping
  without an OS read, and every app status including ephemeral/unknown. Query tasks provide deterministic completion;
  no timeout/polling mechanism is added to production code.
- `NativeNotificationsSettingsTests` mounts the actual root-supplied model adapter through source symlinks. It checks
  zero reads on mount/cover/return, an explicit intent and duplicate guard, completion while hidden, stable owner
  identity and unqueried construction through real `StationResources`. Native static-label publication is not assumed.
- `NotificationsSettingsUITests` covers the real entry, Not checked before a tap, an explicit settings read without
  assuming simulator authorization defaults, retained snapshot after navigation, AX5/landscape and reachable Check,
  Back and host-scope help. Screenshot attachments qualify layout only; they are not physical-device evidence.
  UI queries are typed, wait for hittability and use bounded directional drags/MainActor geometry reads.
- Verification includes iOS/Mac compilation, lint, these focused suites, existing native-root/shell checks and required
  repository checks/reviews. The PR's **Verification** section records actual commands, outcomes, captures and
  exact-head reviews. Initial source authoring ran no builds, tests, lint, simulator, OS queries, review services,
  network, microphone, audio or deployment actions.
- `trace: partial`: #1115's remaining native adoption, authorized host notification/update controls, physical
  VoiceOver and physical audio/listening continuity require separate work. This slice defines no TestFlight stage,
  delivery, permission request or automatic flag change.
