# Bounded speech completion (#538)

Advice still enters through its original, at-most-two-second wire/qualification deadline.
The initial core plumbing adds a separate host-only, single-promotion completion deadline.
It does not yet promote received advice or change foreground/render behavior.

The completion policy reserves four seconds for complete synthesis and owned cleanup,
twelve seconds of mono24kHz PCM16 (576,000bytes), and two seconds of scheduling margin.
A promoted ticket retains its original qualification and request identifiers. Its fixed
completion deadline is not renewed by device heartbeats. Every effect still requires a
live current private-route generation, including after the original admission expiry.
Queued audio uses the ticket's effect deadline; route loss, Stop and capture failure still
cancel it. Ordinary, unpromoted tickets retain their original deadline exactly.

`CoachingSpeechCompletionTicketTests` covers late/double promotion, unchanged original
correlation, long speech under current renewals, the immutable eighteen-second limit,
queued expiry, route loss/Stop and cue-only queue cancellation without closing capture.
These are authored routes/players/clocks, not live microphone or acoustic proof.

Dependent changes must connect consumer-ledger promotion and revocation, revoke speech on
new microphone activity/finals, then activate complete-phrase renderer validation. Until
those changes are reviewed and composed, this plumbing is inert in the application.

The consumer now exposes an explicit `prepareSpeech` host step, still unused by the
foreground coordinator in this stage. It validates its exact owned fresh admission,
promotes once, and retains only the original qualification needed by that bounded
admission. Old handles and foreign consumers cannot reuse the promoted request.
`interruptSpeech` revokes admitted handles before player cancellation, fences admissions
which were inside callbacks, preserves request replay protection and keeps capture open.
The foreground audio port and existing Apple composition delegate these operations.

`CoachingSpeechConsumerTests` covers cross-renewal scheduling, immutable completion,
late/double/foreign promotion, cue revocation/replay and interruption during admission
or promotion. The native player effect revision additionally clears work that commits
after cue cancellation returns, while holding successor admission until it unwinds
(`PrivateCoachingPlayerEffectTests.cueCancellationFencesLateWorkWithoutClosingCapture`).
