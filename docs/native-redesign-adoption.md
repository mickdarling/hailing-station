# Native redesign: adoption plan (#1115)

**Status:** approved by Mick on 2026-11-09 ("Sure, let's go with your recommendations. We'll see what that's like. If we don't like it, we can always make adjustments."). Nothing goes to TestFlight until Mick says so.
**Base:** main `7b064cbd`, where the file and line references below were taken. All eight Revision B components are merged and unwired, the text-size control (#1166) included.

## The rules every step follows
- **One small PR per step, each revertible on its own.** Each step goes behind a launch flag, `station.redesign.<step>`. Rolling back means turning the flag off or reverting the PR. No step depends on a later one.
- **How Mick flips a flag.** Step 1 adds a "Redesign" section to Labs, with one toggle per merged step. Each toggle writes its `station.redesign.<step>` default. Flags are read once at the app root, so a change takes effect after the app is relaunched; the toggle says so.
- **Every flag is OFF by default in every build.** A TestFlight with step N merged looks and behaves exactly like today until Mick turns that step on.
- **Listening and capture never drop across a change.** Where a step touches the station's structure (steps 1, 2, 6b and 7), the device check is: flip the flag and relaunch, then start ambient listening and a talk capture. While they run, switch tabs and open and close the step's sheets or popovers; neither ends. (A relaunch itself ends any capture, so the check starts after it.)
- **Owners stay where they are.** `StationSceneState`, `HostConnectionStore`, `AudioRouteModel`, the ambient controller and `TranscriptionLabView` keep living above every navigation branch (`RootView.swift:14`, `:48`). Components get values and closures passed down. No controller factory or `@State` owner moves into a sheet, tab, popover or view builder.
- **Views keep no authority.** Every intent calls a method the owner already has. Nothing new can start or stop capture, change privacy, a target or a route, or resend.
- **Old identifiers stay until the new ones pass UI tests.** Six UI-test references use `station.talk`, `station.paste` and `transcription.status` (`Tests/Hail-iOSUITests`). They're removed only in the cleanup step.

## Owner mapping: where each component's inputs come from today

| Component input | Today's owner (main `7b064cbd`) |
|---|---|
| `TalkActivity.phase` | `TranscriptionLabView`: `isStarting` :48, `isRecording` :44, `isFinalizing` :49, `finishTask` :73 |
| `TalkActivity.sendPending` / `.interrupting` | `pendingSendID` :56; `isInterrupting` :52 or `interruptTask` :53 |
| `DockAccessories` | `onEscape` :39, `pasteOffer` :38 and `onFinalized` :36; `HostConnectionStore.showsPrivacySwitch` (`HostConnectionStore.swift:625`) |
| `TurnOutcome` (strings today; typed in step 6a) | `+Interface.swift`: "Sending…" :137, "Sent — reply turn unverified" :155, "Waiting for reply…" :158, a send failure :172 (`.sentUnverified`, or `.refused` for a `PastedDraft.Problem`). `+Lifecycle.swift:120` "Destination changed — request not sent" (`.notSent`). `+Progress.swift:68` "No reply yet" (`.noReplyYet`). `+ReplyArrival.swift:9,16` (`.replyReceived`) |
| `RailHost.privacy` | `HostConnectionStore.privacySwitch` (`:631`); `.unsupported` when `showsPrivacySwitch` is false |
| `RailHost.handoff` / `.connection` | `AmbientListeningController.handoff` (set at `HostConnectionStore.swift:1029`); `controller.reconnect` (`isPending`, `notice`; read at `RootView.swift:186`, `StationCard.swift:180`) |
| `StationMenuStatus.Listening` | `StationMenuPublishers.phase` (`StationMenuPublishers.swift:68-74`) |
| `StationAvailability` | `RootView.stationAvailability` (`RootView+Interface.swift:133-141`) |
| `DestinationControlState` | `.resolve(availability:, confirmed: destination, remembered: rememberedSelection)` in `RootView` |
| `MicLiveSources.engine` | The capture engine's running flag (`Capture.swift:140`) isn't published. Step 2 adds a read-only accessor on that flag, published on the main actor. It adds no audio authority: it can't start or stop anything. Until then it's nil, which fails safe to "may be on" |
| Audio routes | `RootView.audioRoutes` (`RootView.swift:17`). The headset preference moves from the view's `@AppStorage` into an owner method |

## Sequence: what changes, and who sees it

| # | PR | What it replaces | First visible change | How it's tested on device | Rollback |
|---|---|---|---|---|---|
| 1 | Navigation shell, plus the Labs "Redesign" toggles | Nothing: today the station is one page, `NavigationStack { content }` (`RootView.swift:54`), with no routing. With the flag on, `StationNavigationShell` (#1148) becomes the root instead, with today's station unchanged as its Station section | Native tabs on iPhone and a sidebar on iPad and Mac. The station unchanged | UI tests on iPhone and iPad sims. On Mick's iPad: switch tabs while listening and mid-capture; listening and capture never drop | flag `shell` |
| 2 | Mic indicator and listening/privacy rail, plus the read-only engine accessor | The listening line in `StationCard` | **The rail: the first change Mick sees on the station** | Rail state for each of: talk, ambient, private, paused, moved to iPad, reconnect. VoiceOver reads it, and Dynamic Type at XXXL. Listening and capture never drop when the rail appears | flag `rail` |
| 3 | Destination control | `destinationMenu` popover (`RootView+DestinationMenu.swift:5,21`) | Toolbar destination with the Mac named | Switch Macs and targets, take one offline. Talk is disabled until confirmed. The toolbar item hides with the station (`stationAccessibilityScope()`, or `stationRemovedWhileHidden()` if the scope doesn't reach it there), and #1183's tree sweep must pass (see Step 1 as built) | flag `destination` |
| 4 | Conversation viewport | The 340 pt chat cap (`StationLayout.swift:19,91`), insets and the 48 pt gutter | **More conversation lines visible** | Count lines on iPhone 15 Pro Max and iPad Pro 13" before and after, at Large and at AX3; check the reading anchor holds on a new reply | flag `viewport` |
| 5 | Text size (Aa) | `stationTypeSize` for transcript text only (`StationLayout.swift:50,102`) | The Aa control | Each step and Reset, at Large and AX3; the controls don't change size; relaunch keeps the choice. A UI test on a compact iPhone at AX5 checks Smaller, Larger and Reset stay reachable (Codex review of #1166) | flag `textSize`; the key stays harmless if unread |
| 6a | Typed `TurnOutcome` inside `TranscriptionLabView` | Nothing visible: the status strings keep showing, and the owner also publishes the typed outcome | None | Unit tests show every status string maps to its case as in the table above, including a send failure to `.sentUnverified` and a refused paste to `.refused` | revert (no UI) |
| 6b | Voice dock | The talk card's button row (`TranscriptionLabView+Interface.swift`), with `TranscriptionLabView` still the owner | The dock above the tab bar | Full talk loop, Escape mid-capture, paste, a timeout ("No reply yet"), a destination change mid-capture. Listening and capture never drop when the dock replaces the row. The station page's dock already applies `stationAccessibilityScope()` (#1184); the tree sweep must pass with the dock filled, and if the scope doesn't reach it, the fix must keep the dock mounted | flag `dock`; `station.talk` kept |
| 7 | Audio routes and recovery sheets | Labs' audio session screen (kept in Labs) and the stall notice | Two sheets reached from the dock's More menu | Switch the mic mid-capture; toggle the headset; drop the Mac and watch "Restoring…" then "Restored". Opening and closing either sheet mid-capture never ends listening or capture | flag `sheets` |
| 8 | Cleanup | The flags and old identifiers, once Mick has confirmed each step on his devices | None | Full UI test suite with the new identifiers | revert |

## Mick's decisions (2026-11-09)
Mick took both recommendations: option A with the accessibility split, and the order below.

1. **Default conversation text size: option A, with the accessibility split.**
   - **The facts:** today's station shrinks all text one step on iPhone and two on the one-screen iPad (#288). At the default Large setting, chat text is about 16 pt on iPhone and 15 pt on iPad. The spec's default is 17 pt.
   - **Option A (recommended): seed today's size.** On first launch with step 5, existing installs store 16 on iPhone or 15 on iPad. Nothing gets bigger the day it ships, and Reset still goes to 17.
   - **Option B: use the spec's 17.** The extra lines from step 4 offset the larger text.
   - **The edge case (accessibility text sizes):** the seed is a step, not a fixed size. Rendered size = Dynamic Type's body scale × the step. Today `stationTypeSize` does nothing at accessibility sizes, so an AX user's chat text is the full 17 × scale. Seeding them 16 would make their text about 6% smaller than today. So seed 16 or 15 only when the OS setting is below the accessibility sizes, and seed 17 (no change) at AX sizes. **Chosen.**
   - **Still open:** the Mac (spec default 14). Today's Mac chat size is measured and a default proposed before step 5.
2. **Order: as proposed.** The rail (step 2) as the first visible change, because it's safety-relevant, and the viewport (step 4) as the first "more text" win. The shell (step 1) goes first but looks nearly the same.

## Step 1 as built
- **Flags are read once per launch.** `StationRedesignLaunch.flags` is a `static let`, not a read in `RootView`'s init or body. SwiftUI can create the root view's value again at any time, and a fresh read after a Labs toggle would swap the whole station mid-session, which ends a capture. A step is on only when its stored value is a Boolean `true`.
- **Sections.** Station is today's page, kept mounted across tab and sidebar switches (#1148). Devices and Settings list the tools (Mac Setup; Audio, Labs and Turn-taking), each pushed onto that visible section, so each keeps its own back navigation. Sessions is a placeholder until step 3, so there's still one place to choose a destination. The inspector and dock are empty until their steps.
- **The station's tool links open their section in the shell (#1189).** With the shell on, the station's Mac Setup, Set up a Mac and Mac Setup (beside "Check Mac connection") links open Devices, and its Audio, Labs and Turn-taking links open Settings. Nothing is pushed under a station that hides while another section shows. With the shell off, every link pushes exactly as today.
- **The hidden station stays out of the accessibility tree (#1184).** The shell sets `stationAccessibilityHidden` on the station page. Every part of the page that SwiftUI hosts on its own applies `stationAccessibilityScope()`: the root and, from step 3 on, each toolbar item. That modifier doesn't reach a `.safeAreaInset`: the sweep found the build footer in the tree with it applied, on iPhone and iPad. So the footer, which holds no state, leaves the view tree while the station is hidden (`stationRemovedWhileHidden()`). **Any later step that adds a toolbar item, an inset or a pushed view under the station must apply one of the two, and the sweep must pass. Only a part with no state may be removed; nothing that captures, plays or sends.** `RedesignShellUITests` sweeps the whole tree on Devices and Settings for any `station.*` identifier beyond the shell's own and for sensitive wording (microphone, destination, talk, privacy, private, listening, recording), on iPhone and iPad. The VoiceOver device check on iPhone, iPad and Mac is a merge blocker for step 1.
- **Follow-up (#1188):** move talk capture ownership above navigation, so the station can unmount like any other section and none of this is needed.
- **Full conversation** doesn't hide the tab bar or sidebar yet. Mirroring today's stored expansion (#819) into the shell would need a second writer of that preference, or would leave the iPad's sidebar control unable to show the sidebar while expanded. It comes with the viewport or dock step.

## Not in scope
- No TestFlight, deploy or `haild` restart without Mick's OK.
- No change to daemon or host files, which belong to the security series.
- Recovery actions stay with #1002. The recovery sheet only observes.
