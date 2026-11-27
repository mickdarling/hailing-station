# Privacy and Mute: canonical definitions

These definitions come from the owner (2026-11-26) and are the single source for UI copy, tests and storage rules.

> "Privacy means everything coming into Hailing Station from my side is cut off. Nothing gets through. Mute means
> nothing comes from you as audio to me, but I can still see text."

The owner then clarified what Privacy stops (2026-11-26):

> "For privacy, we still have the mic on, but we're not recording any of it. You still keep Talk, Paste, Interrupt
> and the few other paths that still travel. Those are fine. I meant about audio being recorded. That's what privacy
> stops. It stops your audio."

## Privacy

Privacy stops **ambient audio**. While Privacy is on:

- ambient audio and its words are not recorded, kept, logged or forwarded to any agent;
- the microphone stays on only for the voice exit, the voiceprint-gated "I'm back" command, which listens
  transiently and keeps nothing. The exit detector runs in RightyO on the Mac, so the raw microphone audio still
  streams from the device to the Mac while private, for that purpose only; no words or transcripts leave the
  device, and nothing reaches an agent;
- the device's local quiet meter (used to time proactive speech) still reads the microphone while private; it keeps
  only timing and activity state, never words or audio;
- deliberate owner actions still work: Talk, Paste and Send Paste, Interrupt and Escape, plain-text send, and the
  other explicit paths.

Nothing from ambient audio during a privacy period is ever saved (#1423), whatever any save setting says.

## Mute

Mute is an **outbound, audio-only** cut-off. Replies still arrive and render as text, cards still render, and no
reply audio plays. Muted replies are saved as text like any other.

## Using these definitions

- **UI copy:** the Privacy and Mute controls, their tooltips and accessibility labels, the Settings Privacy section
  (#1406) and "Go private" (#1415) describe these behaviours and nothing narrower or broader.
- **Tests:** Privacy tests assert that no ambient audio or words are recorded, kept, logged or forwarded while
  private, and that deliberate actions (Talk, Paste, Interrupt, text send) still work. Mute tests assert that
  playback is suppressed while reply text still renders.

## Known gaps

#1430 tracks verifying and enforcing that no ambient audio or words are recorded, kept, logged or forwarded while
private, beyond what the voice-exit detector needs transiently. Mute matches its definition.
