# Privacy and Mute: canonical definitions

These definitions come from the owner (2026-11-26) and are the single source for UI copy, tests and storage rules.

> "Privacy means everything coming into Hailing Station from my side is cut off. Nothing gets through. Mute means
> nothing comes from you as audio to me, but I can still see text."

## Privacy

Privacy is an **inbound** cut-off. While Privacy is on, nothing from the owner's side enters Hailing Station or reaches
any agent:

- ambient microphone input;
- Talk (push-to-talk) capture and its final text;
- paste and Send Paste;
- typed or sent text;
- Interrupt and Escape;
- any other input path.

Because nothing enters, nothing from a privacy period is ever saved (#1423), as text or audio, whatever any save
setting says.

## Mute

Mute is an **outbound, audio-only** cut-off. Replies still arrive and render as text, cards still render, and no
reply audio plays. Muted replies are saved as text like any other.

## Using these definitions

- **UI copy:** the Privacy and Mute controls, their tooltips and accessibility labels, the Settings Privacy section
  (#1406) and "Go private" (#1415) describe these behaviours and nothing narrower or broader.
- **Tests:** Privacy tests assert that every inbound path is blocked. Mute tests assert that playback is suppressed
  while reply text still renders.

## Known gaps

A source audit on 2026-11-26 found that current Privacy behaviour does not yet meet this definition. Ambient audio,
Talk, Paste, Send Paste and Escape are not all cut off. This is tracked in #1430. Mute matches its definition.
