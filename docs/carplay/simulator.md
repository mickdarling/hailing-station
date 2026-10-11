# CarPlay simulator spike (#72)

Simulator only. The voice-based conversational entitlement has not been granted (see `entitlement-request.md`).

## How it is gated

- `project.yml` is **unchanged**. The default build, `scripts/verify.sh sim` and TestFlight carry no CarPlay
  entitlement, declare no CarPlay scene and do not link CarPlay.framework.
- All CarPlay code in `Apps/Hail-iOS/CarPlayVoiceScene.swift` and the delegate adaptor in `HailApp.swift` compile only
  under the `HAIL_CARPLAY` Swift condition. Without it, the one RootView line is a no-op modifier.
- The entitlement for the simulator build lives in `Apps/CarPlaySim/CarPlaySimEntitlements.plist` (a `.plist`, because
  `*.entitlements` is gitignored for XcodeGen output). Only the command below passes it.
- The CarPlay scene is declared at runtime (`application(_:configurationForConnecting:options:)`), so the generated
  Info.plist does not change either.

## Build and run

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --quiet
xcodebuild build -project HailingStation.xcodeproj -scheme Hail-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/hail-carplay \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG HAIL_CARPLAY' \
  CODE_SIGN_ENTITLEMENTS=Apps/CarPlaySim/CarPlaySimEntitlements.plist
xcrun simctl boot "iPhone 17 Pro"   # or any iPhone simulator
xcrun simctl install booted /tmp/hail-carplay/Build/Products/Debug-iphonesimulator/Hail-iOS.app
xcrun simctl launch booted com.mickdarling.Hail-iOS
```

Then in Simulator: **I/O > External Displays > CarPlay**. Hailing Station should appear on the CarPlay home screen.

## What it does

- Root: a one-row list ("Talk to Haili"), with the voice control template presented over it at once (voice first).
- The voice control template has three states, idle ("Haili is ready"), listening and speaking, driven by the phone's
  existing state: `connections.ambientStreaming` and `playback.isReplyAudioOutputBusy`, the same signals as the
  station card's Listening/Speaking badges. CarPlay owns no audio, connection or queue of its own.

## Known limits (follow-ups, not in this spike)

- **SDK:** local Xcode is 26.3 with the iOS 26.2 SDK/runtime. The category, its entitlement key and the voice template's
  action and navigation-bar buttons are iOS 26.4. So: no start/stop button yet, and the 26.2 simulator may not
  recognise the category (the app might not show on the CarPlay screen, or the template might be refused). Retest on
  Xcode with the iOS 26.4+ (or 27) SDK, then add a start/stop action wired to the ambient controller.
- State flows through a SwiftUI `onChange`, so it only updates while the phone UI is alive. A real version needs the
  state published from the controllers, as `onReplyFrame` already is, so it works with the phone locked and in the
  background.
- Audio: ambient listening holds the session open; the category rules want it open only while voice is in use. The
  session is `.playAndRecord` without mixing/ducking, so navigation prompts interrupt rather than mix (field data in
  #72: Waze prompts and replies shared the car speakers). Decide push-to-talk vs bounded session and how to yield to
  navigation before any device test.
