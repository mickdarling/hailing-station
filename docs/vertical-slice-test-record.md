# Single-device vertical-slice test record

This is the sanitized public record for Hailing Station's first audio-first mobile-to-Mac proof. Local result bundles contain device metadata and remain private.

## Scope

- Date: 2026-09-22
- Terminals: one physical iPhone and one physical iPad
- Host: one Mac on a private network
- Target: one synthetic tmux test target
- Distribution: direct Xcode development installs
- Deferred: second Mac, multi-host arbitration, background operation, and broader distribution

## Automated evidence

| Check | Device | Result |
| --- | --- | --- |
| Install, launch, and select the configured host-scoped target | iPhone | Pass |
| Open the station microphone menu, choose Automatic, activate audio, and confirm a live input | iPhone | Pass |
| Adaptive compact and expanded station chrome | Simulator matrix | Pass |
| Input preference, fallback, failure, retry, lifecycle, and route-change races | Injected backends | Pass |
| Host negotiation, allowed-target delivery, Escape, reply identity, playback queue, and controls | Injected and integration tests | Pass |
| Full repository verification | macOS | 354 tests passed; audit, lint, protocol, and script checks passed |

The physical tests retain no microphone recording and assert no private transcript contents.

## Manual observations

The iPad proof completed these route changes while the app remained usable:

1. The built-in microphone and speaker were reported at 48,000 Hz.
2. Connecting an external USB receiver changed input to the receiver; disconnecting it returned immediately to the built-in microphone, and reconnecting restored the receiver within roughly two seconds.
3. Selecting AirPods through the system route workflow changed the reported output to AirPods without selecting Bluetooth HFP input.
4. When a nearby Mac took the AirPods route, the app truthfully reflected the iOS output change; returning AirPods to the iPad restored the displayed output.
5. Two consecutive tap-to-talk cycles produced final on-device transcripts.
6. A host-injected tone and spoken reply were heard from the iPad.

The iPhone proof completed target selection, microphone activation through the station control, and audible host-reply playback. Playback was quiet in that room but intelligible.

## End-to-end product proof

The following one-host loop has been exercised on physical hardware:

1. Connect the terminal to an authenticated private Mac host.
2. Select an allowed, host-scoped target and keep that destination visible.
3. Tap once to start talking and tap again to finish.
4. Finalize the on-device transcript and send it immediately without a review gate.
5. Use the prominent Escape action to cancel target work independently of capture.
6. Receive associated reply text and PCM audio from the host.
7. Play, pause or resume, mute or unmute, replay, and inspect the reply transcript without changing its identity.

Automated coverage proves that delivery stays bound to the selected allowed target, is audited, and does not cross-associate overlapping reply streams. Route, lifecycle, connection, cancellation, and playback-queue tests cover duplicate-prevention and stale-operation races.

## Repeat the proof

Follow [the device-testing runbook](device-testing.md), using synthetic speech and target data. Run both physical UI tests:

```sh
xcodebuild test \
  -project HailingStation.xcodeproj \
  -scheme Hail-iOS \
  -destination 'platform=iOS,id=<local-device-id>' \
  DEVELOPMENT_TEAM=<local-team-id> \
  CODE_SIGN_STYLE=Automatic \
  -only-testing:Hail-iOSUITests/PhysicalTargetSelectionTests/testSelectsConfiguredPhysicalTarget \
  -only-testing:Hail-iOSUITests/PhysicalTargetSelectionTests/testActivatesAutomaticMicrophoneFromStationControl
```

Then repeat the manual route matrix in the runbook and submit one synthetic spoken request to the selected target. Inject one synthetic text-and-audio reply through the local host endpoint and exercise every playback control before disconnecting.

## Remaining limits

- iOS ultimately owns playback-route selection. The app presents the native route picker and reports the resulting route; it cannot guarantee AirPods retention when another Apple device takes them.
- This record proves one active Mac. Multi-Mac behavior remains separate work.
- The current proof uses foreground operation and direct development installation.
