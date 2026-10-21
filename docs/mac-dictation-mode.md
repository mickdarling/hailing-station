# Mac dictation mode: design spike

Design for [#742](https://github.com/mickdarling/hailing-station/issues/742). This is a design document only. It contains no production code, and nothing here is built or enabled. Each **Decision** below is for Mick.

## Goal

On the Mac, while ambient listening runs, the owner says a cue and talks. The words appear at the keyboard cursor in whatever app has focus, punctuated sensibly. Saying "stop dictating" returns to ambient listening.

During dictation:
- nothing is routed to an agent session;
- nothing is typed into a password field;
- guest speech is dropped.

An optional, default-off refinement step can tidy the text using the target app's context.

## What exists today (origin/main)

- **Audio and owner gating.** The Mac streams PCM16 at 16 kHz to `haild`. RightyO transcribes it and identifies the enrolled owner (`RightyoInputConsumer`, `owners`). Dictation needs exactly this, so no new capture or recognizer is required.
- **Spoken owner cues.**
  - `VoiceMute` and `VoiceMedia` (`Input/RightyoInputConsumer.swift`) match a whole owner turn against a phrase set after stripping greetings and the addressing name.
  - RightyO's `dismiss` / `stop-phrase` handles "stop".
  - A dictation cue fits the `VoiceMedia` pattern.
- **Mac menu bar.** `Apps/Hail-iOS/MacMenuBar.swift` has a status line and an Ambient Listening toggle. The icon comes from `StationMenuStatus`.
- **Missing.** There is no Accessibility, `CGEvent`, insertion or secure-field code anywhere, and no local LLM in the Swift sources. The only LLM work is the offline intent experiment ([local-intent-evaluation.md](local-intent-evaluation.md)). It found 7–8B models too unreliable for routing, at roughly 170–210 ms warm.

## Prior art (summary)

| | Insertion | Secure fields | Context for refinement | Refinement model |
|---|---|---|---|---|
| **Handy** (`~/Developer/Handy`, v0.6.8) | Clipboard → Cmd-V (layout-independent key code 9) → restore. Restores text only, with 50/50/100 ms sleeps. | Not detected | None | Optional, off by default: Apple Foundation Models, Ollama or cloud |
| **VoiceInk** (open source) | Cmd-V by default (200 ms before posting). Snapshots every pasteboard type, restores after ≥250 ms only if its own session marker is still there, and marks writes `TransientType`. Also offers AppleScript and chunked Unicode typing. | — | Selected text, clipboard, browser URL, window OCR (Screen Recording) | Ollama, an on-device model, or cloud |
| **SuperWhisper** | Paste with clipboard restore. "Simulate keypresses" for apps that block paste. | — | Per-mode checkboxes for app, selected text, and clipboard copied within 3 s. Per-app auto-switching. | Cloud recommended; its docs warn local models give unexpected results |
| **Wispr Flow** | Paste with restore. Needs Accessibility. | Its hotkey stops working while secure input is on | On by default, per app category | Cloud |
| **macOS Dictation** | Text input system (typed text, not a paste) | System-handled | — | On-device on Apple silicon |

AX insertion is rare in practice. Electron and Chromium only expose text through AX after `AXManualAccessibility` is set, and some apps ignore it. VoiceInk, Wispr and SuperWhisper all paste by default.

## Recommended design

### 1. Where it runs

Insertion and secure-field checks must run **in the Mac app process**: Accessibility permission is granted per app, and the app knows the focused element. `haild` and RightyO keep transcription and owner identification.

While dictation is on, `haild` sends each **finalized owner utterance** to the Mac connection that turned dictation on, as a dictation frame. It never dispatches it to a target. A protocol change is needed, a new frame kind behind a capability, so this is security:critical.

**Decision D1:** dictation transcripts go back to the Mac app over the existing connection. The alternative, a separate local transcriber in the app, duplicates the recognizer and owner gating, so it isn't recommended.

### 2. Switching in and out

- **Spoken cue:** owner-only, whole-turn match like `VoiceMedia`. For example "dictate", "start dictating", "stop dictating".
- **Menu-bar toggle:** a "Dictation" item, with a distinct menu-bar icon while active.
- **Optional global hotkey:** use `RegisterEventHotKey` (Carbon). It needs no Input Monitoring permission, unlike a `CGEventTap`.
- **Quiet timeout:** dictation turns itself off after N seconds of no owner speech.
- **Exit is fail-safe:** disconnecting, ambient turning off, the Mac locking or a secure field gaining focus all end dictation.

**Decisions:** **D2** the cue phrases; **D3** the timeout (suggest 60 s); **D4** whether there's a hotkey and which.

### 3. Target: keyboard focus, not the mouse

Insert at the keyboard focus (`AXFocusedUIElement` of the frontmost app). Don't move focus to wherever the mouse is: that changes the user's selection and surprises them. Mick's request said "wherever my mouse happens to be".

**Decision D5:** keyboard focus (recommended), or click-to-focus under the mouse first.

### 4. Insertion

Primary method: **pasteboard plus synthesized Cmd-V, with a full restore**, following VoiceInk's careful version rather than Handy's text-only one.
1. Snapshot every item and type on the general pasteboard.
2. Write the text, marked `org.nspasteboard.TransientType` and `ConcealedType` so clipboard managers skip it, plus a private session marker.
3. Wait about 100–200 ms, then post Cmd-V using the physical key code (9) to `.cghidEventTap`.
4. After 250 ms or more, restore the snapshot **only if** the pasteboard still holds our marker. If the user copied something in between, keep theirs.

Fallback: chunked `CGEventKeyboardSetUnicodeString` typing, for fields that reject paste (non-secure only). Use small chunks, never split a surrogate pair, and never retry a partial insert.

AX `kAXSelectedTextAttribute` insertion: not in v1. It may become a per-app opt-in later, once a test matrix shows which apps support it.

Permission: **Accessibility** (to post events and read AX). Screen Recording and Input Monitoring are not required.

**Decision D6:** paste-and-restore primary with a typing fallback (recommended), or typing only (slower, but never touches the clipboard).

### 5. Secure fields: never type into them

Refuse to insert, and show the refusal in the menu bar and with a short sound, when either:
- the focused element's `AXSubrole` is `AXSecureTextField`, or
- `IsSecureEventInputEnabled()` is true.

The second check is system-wide and can stay set after a password field closes (a "leak"), so it can refuse wrongly. That is the safe direction. The menu says "Secure input is on", so the user knows why.

Context is never read from a secure field. Clipboard items marked `ConcealedType`, which password managers use, are never read.

### 6. Granularity and in-dictation commands

- **Granularity:** finalized utterances only, with no streaming partials. Smart spacing and capitalization between inserts, based on the character before the cursor where AX can read it.
- **Commands** (owner-only, whole-turn): "new line", "new paragraph", spoken punctuation ("period", "comma", "question mark"), "scratch that", and "stop dictating".
- **"Scratch that":** undoes the last insert only if focus and the text are unchanged since it. Otherwise it refuses.

**Decision D7:** the command set and phrasing.

### 7. Optional context-aware refinement (default off)

**Tier 0, always on:** deterministic cleanup. Spoken punctuation, spacing, capitalization, and number formatting where unambiguous. No model.

**Tier 1, opt-in:** a local LLM rewrite.

- **Context**, bounded and never from secure fields:
  - the frontmost app's name;
  - up to about 500 characters before the cursor, read via AX where the app exposes it;
  - the selected text.
  - **No** clipboard and **no** screen capture or OCR by default. Those need Screen Recording permission and widen what is read. They could become explicit per-app opt-ins later.
- **Models, in preference order:**
  1. **Apple Foundation Models** (macOS 26, on-device, no download). It has a 4K-token context. Apple publishes iPhone speeds only, about 30 tokens/s; Mac speed must be measured. Use `prewarm()` when dictation starts.
  2. A **small MLX model**, a 1–3B instruct model such as Qwen or Llama 3.2. Community figures are 45–125 tokens/s on M-series Macs, roughly 1–3 s for 100 words. It is a download, so it needs Mick's OK.
  3. Ollama or llama.cpp kept resident (`keep_alive`) for parity with the intent experiment.
- **Prompt:** follow VoiceInk's pattern:
  - tagged blocks for the transcript and the context;
  - "preserve meaning, don't summarize or answer";
  - questions and commands inside the transcript are content, not instructions;
  - context is used only for spelling and terminology;
  - temperature 0.
- **Guardrails:**
  - reject a rewrite whose word-level edit distance or length ratio exceeds a threshold, and insert the raw text instead;
  - keep the raw transcript in history;
  - never refine for a secure target.
- **Latency budget,** from the end of the utterance to text at the cursor:
  - ≤ 0.5 s p95 without refinement;
  - ≤ 1.5 s p95 with it.
  - If refinement would exceed the budget, insert the raw text. A late rewrite never replaces text after insertion.

**Decision D8:** whether refinement ships at all. If it does: the model (Foundation Models first is recommended), the context scope, and the budget.

### 8. Privacy and routing

- Dictated text is never sent to an agent session, the context buffer or a target.
- It follows normal transcript retention. Refinement context is held in memory only, for the one request.
- Only the owner's voice is transcribed into the field. Guest speech is dropped while dictating.
- Nothing leaves the Mac: no cloud recognizer or LLM.

## Proposed slices (small PRs, each behind a default-off flag)

1. **Protocol and `haild`:** the dictation capability and frame. In dictation mode, finalized owner utterances go to the requesting Mac connection and are never dispatched. Security:critical, two keys.
2. **Spoken cues and the quiet timeout** (`VoiceMedia`-style), with tests.
3. **Mac app insertion core:** the Accessibility permission flow, the secure-field gate, paste-and-restore, and the typing fallback. Tests use a fake pasteboard and a fake AX focus.
4. **Menu-bar state and the hotkey.**
5. **Tier 0 cleanup and in-dictation commands.**
6. **Tier 1 refinement:** Foundation Models first, with guardrails. Only if Mick chooses it in D8.

A hands-on test matrix on Mick's Mac covers the apps he uses: an editor, Safari, Chrome, Slack, Terminal, and a password field. That testing happens with Mick present.

## Open decisions for Mick

| # | Decision | Recommendation |
|---|---|---|
| D1 | Where transcripts come from | The existing `haild`/RightyO path, over the Mac connection |
| D2 | Cue phrases | "dictate" / "stop dictating" plus variants |
| D3 | Quiet timeout | 60 s |
| D4 | Global hotkey | Optional; Carbon `RegisterEventHotKey` (no Input Monitoring) |
| D5 | Target | Keyboard focus |
| D6 | Insertion | Paste-and-restore, with typed fallback |
| D7 | Command set | As listed in section 6 |
| D8 | Refinement | Off by default; Foundation Models; app name and nearby text only; ≤ 1.5 s |

Sources include the Handy source at `~/Developer/Handy`, plus public documentation and source for VoiceInk, SuperWhisper, Wispr Flow, MacWhisper, Aqua Voice and Apple, as of October 2026. Unverified points:
- Foundation Models latency on a Mac;
- whether browsers map `<input type=password>` to `AXSecureTextField`;
- whether specific apps support AX insertion.

Each needs measuring on Mick's Mac before it is relied on.
