# Native Appearance settings (#1115)

Part of the native settings design in #1239. The first bounded slice adds a Settings entry to Station tools and a native Mac Settings window (Command-comma). Both use the same app-owned preference store and existing #1166 text-size state/actions. The settings sheet is presented above the station layout, so replacing or resizing its branches cannot dismiss Settings. Opening the sheet keeps the station mounted. No station, connection, capture or playback owner is created by the settings screen.

## Current scope

- Smaller, Larger and Reset store the app-only conversation-size preference on this device. The #1166 platform steps and defaults are preserved: touch 17 points, Mac 14 points; Dynamic Type scales the preview.
- The live authored conversation preview follows the selected size. Surrounding controls and OS text settings do not change. Values survive closing settings and relaunching the app. Invalid stored data falls back to the platform default.
- This slice does **not** apply the preference to the current conversation renderer. The screen labels it a preview preference and says live conversation sizing is unavailable. Wiring the existing transcript styles is separate work under #1115; no reply/card or reserved TestFlight source files are changed here.
- No remote setting, host or target authority, audio-route operation, microphone test or playback test is added. This does not activate the pending navigation-shell adoption PRs.

## Isolated verification

The Debug-only `-appearance-preview` launch argument opens just this screen instead of constructing the station. Its isolated preference suite is separate from the real app settings; `-reset-appearance-preview` clears only that preview suite. `-appearance-entry-preview` additionally exercises the actual Settings button, its sheet and dismissal under an adaptive tools example, without constructing the station. Its Debug-only layout control replaces the outer example branch while Settings is open to exercise presentation lifetime. Release builds ignore these arguments.

The screen contains only authored example text. Simulator captures and a direct native Mac settings render are UI evidence, not physical-device, live-conversation or audio qualification.

Focused tests cover persistence through preference-owner recreation, malformed saved data, isolated preference suites, the shared controls and accessibility-size reachability. The pure #1166 math remains covered by ConversationTextSizeTests and ConversationTextSizeSweepTests.

The complete configuration catalog, Favorites, remote authorization and the other #1239 settings groups remain design proposals.
