# CarPlay entitlement request (#72)

Status: **draft for Mick's approval. Nothing has been submitted to Apple.**
Sources checked on **2026-10-11**.

## Findings

### The category exists and fits

Apple has a **voice-based conversational app** category for CarPlay.

| Item | Value | Source |
|---|---|---|
| Entitlement key | `com.apple.developer.carplay-voice-based-conversation` (Boolean) | [Entitlement reference][ent], [CarPlay Developer Guide (June 2026)][guide] p.13 |
| Minimum iOS | iOS 26.4 | Same two sources |
| Templates allowed | Voice control (iOS 26.4+), plus action sheet, alert, grid, list, tab bar, information, point of interest | Guide p.14 |
| Template depth | At most 3, counting the root | Guide p.14 |
| Voice control template additions | From iOS 26.4: up to 2 action buttons, plus leading and trailing navigation bar buttons (at most 2 trailing) | Guide p.26, [CPVoiceControlTemplate][vct] |
| Recording | Allowed for this category, but **only together with the voice control template** | Guide p.29 ("Audio handling") |

The guide's own description of the category matches what Hailing Station does. Apple's entitlement abstract says the app should "respond to questions or requests and perform actions".

### Category rules (Guide p.4 and p.7)

Voice-based conversational apps have three extra rules:

1. Voice must be the primary modality at launch. After launch, the app responds to questions or requests and performs actions.
2. Hold an audio session open only while voice features are in use.
3. Optimize for voice while driving. For example, don't show text or imagery in response to queries.

The rules for all CarPlay apps that matter for us:

- The app must be designed mainly for the stated category.
- Never tell the driver to pick up the iPhone. Every CarPlay flow must work without touching the phone.
- Don't put unrelated features in CarPlay, such as settings, setup or maintenance.
- Never show the content of messages on the CarPlay screen.
- Use each template only for its intended purpose.
- Once the entitlement is in a shipped build, the app shows for every user. It can't be shown to some people and hidden from others.

### How to request it

1. Go to the request form at <https://developer.apple.com/contact/carplay/>. The [CarPlay page][carplay] links to it as "Request CarPlay app entitlement". The form needs an Apple Developer sign-in. On 2026-10-11 it redirected to `idmsa.apple.com` with path `/contact/request/carplay/`.
2. Choose the category, describe the app, and agree to the **CarPlay Entitlement Addendum** ([Requesting CarPlay entitlements][req]; Guide p.12).
3. Apple reviews the request "using predefined criteria". If it's approved, Apple adds the entitlement to the developer account as a managed capability and emails you.
4. After approval: enable the capability on the App ID (Certificates, Identifiers & Profiles > Identifiers > the app's App ID > Additional Capabilities), then create a new provisioning profile. Xcode needs that profile. **This will force changes to manual signing** in `project.yml`, which is security-critical, so it needs its own PR.

**What I couldn't verify:**

- **Exact form fields.** I couldn't see the form without signing in, and I didn't sign in.
- **Who must submit.** A third-party guide and forum reports say the Account Holder has to submit and accept the Addendum. Plan on Mick submitting as Account Holder.
- **Turnaround.** Apple publishes no turnaround time. Forum reports from September 2026 describe requests still pending after 15–20 days, with no escalation path; Developer Support says another team handles them ([thread 848946][f1], [thread 847440][f2]). Plan for weeks.

### Disqualification risks, and how to describe the app honestly

| Risk | Assessment |
|---|---|
| **Primary purpose.** Hailing Station is a voice app for talking to your own assistant, not a general chatbot shell. | Fits. It is voice-first on iPhone today. Describe it as exactly that. |
| **"Perform actions" / arbitrary computer control.** Haili runs on the user's Mac, and some deployments can act there. | Be candid. The app relays speech to the user's own Mac and speaks the replies. Any action happens on the user's own computer, under the user's own assistant, through the same authorization the iPhone app already uses. Nothing in CarPlay controls the vehicle. Don't advertise "control your computer while driving". |
| **Setup flows.** Pairing a Mac, choosing a destination and host settings all happen in the iPhone app. | All of this stays out of CarPlay (rule 4). If no host is configured, CarPlay can only say Haili isn't available. It must not say "open your iPhone" (rule 2). |
| **Generated text on screen.** | Show none. Only the voice state appears ("Listening", "Haili is speaking"). Replies are audio only. |
| **Audio session held open.** Ambient listening keeps the session active continuously. | **This conflicts with rule 2.** The CarPlay mode needs push-to-talk or a bounded session that releases the audio when the turn ends. This is a design item before shipping, not before the request. |
| **Sharing the audio route with navigation.** | The field data in #72 (2026-10-11) shows Waze prompts and our replies sharing the car speakers. Today the app uses `.playAndRecord` without `.mixWithOthers` or `.duckOthers`, so prompts and replies interrupt each other rather than mix. The CarPlay mode should yield to navigation prompts and resume afterwards (#445 already pauses for other apps). |
| **Wrong category.** | Don't request audio, communication, or driving task. The app isn't a media player, isn't SiriKit messaging or VoIP, and doesn't help with the drive itself. |
| **Locked iPhone.** CarPlay usually runs with the phone locked. | Keychain items and files the station needs must be readable after first unlock (Guide p.29). Check this before a device test. |

## Draft form text (for Mick to approve)

The fields are inferred, because I couldn't read the form. Paste each answer into the closest field.

**App name:** Hailing Station

**Bundle ID:** com.mickdarling.Hail-iOS

**App Store status:** In TestFlight beta, not yet on the App Store.

**Category requested:** Voice-based conversational app (`com.apple.developer.carplay-voice-based-conversation`)

**App description:**

> Hailing Station is a voice-first iPhone app. You use it to talk with your own AI assistant, "Haili", which runs on your own Mac. The app listens when you speak, sends your speech securely to the Mac you paired it with, and plays back Haili's spoken answer. Voice is how you use it: you speak, and Haili answers out loud.

**Proposed CarPlay experience:**

> In CarPlay, Hailing Station opens straight into the voice control template. It shows only the conversation state: ready, listening, or Haili speaking. The driver talks and hears the answer through the car's speakers. No text replies, transcripts, or images ever appear on the CarPlay screen. The only controls are start/stop talking and cancel the current reply.
>
> All setup happens on iPhone before driving: pairing a Mac, choosing an assistant, and settings. None of it is available in CarPlay, and CarPlay never asks the driver to use the phone. The app uses its audio session only while a conversation is active, and yields to navigation prompts.

**Why CarPlay:**

> People already use Hailing Station hands-free in the car through CarPlay audio. It works today without a CarPlay screen, with navigation prompts sharing the speakers. A CarPlay voice template would give the driver Apple's standard listening and speaking indicators and a one-tap way to start or stop talking. The driver wouldn't need to reach for the phone.

**Anything else / notes:**

> Haili is the user's own assistant on the user's own computer, not a hosted chatbot. Hailing Station doesn't control the vehicle. Development and testing so far have used the CarPlay Simulator only.

## After approval (not part of this spike)

- Add the managed capability, signing and entitlement in a separate `project.yml` PR. It is security-critical and needs a second-key review.
- Raise the CarPlay path's minimum to iOS 26.4 using `#available`. The app's deployment target stays at iOS 18.
- Test on a device with CarPlay Simulator (Device Hub / Additional Tools) and then in a real car before any release.

[ent]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-voice-based-conversation
[guide]: https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf
[vct]: https://developer.apple.com/documentation/carplay/cpvoicecontroltemplate
[req]: https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements
[carplay]: https://developer.apple.com/carplay/
[f1]: https://developer.apple.com/forums/thread/848946
[f2]: https://developer.apple.com/forums/thread/847440
