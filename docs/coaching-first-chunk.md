# Coaching speech first-chunk delivery

Current #538 contract: [complete-phrase admission and speech completion](coaching-speech-completion-budget.md)
supersedes the historical streaming/96k-byte/original-deadline playback behavior below.

Part of #268 and #269. The existing PCM-only coaching renderer now emits complete samples from the
first usable read without waiting for a second read, EOF, or renderer cleanup. It retains only the final
sample for the successful-exit final chunk, preserving byte order and the rule that a failed or cancelled
source cannot finalize speech. A source containing only one sample still waits for successful completion.

The existing 96,000-byte, 48,000-byte-per-chunk and 32-chunk bounds, immutable advice admission,
private-output checks and owned-child cleanup remain in force. Earlier nonfinal audio is provisional;
the foreground owner cancels playback if rendering subsequently fails. No route or capture capability
is added, and this source change does not establish physical audio timing or combined coaching readiness.

`CoachingSpeechRendererTests.firstUsablePCMDoesNotWaitForAnotherReadOrSourceExit` checks delivery
before the source returns from its first read. `firstReadRevocationOrFailedExitCannotFinalizeEarlyPCM`
checks cancellation from that first delivery and an unsuccessful source exit. Existing tests retain
odd-byte reconstruction, single-sample finalization, cleanup ownership, payload and chunk bounds.

Physical Jarvis output-only playback and the combined AirPods/room-microphone test remain separate
operator-controlled checks. Software timing at PCM admission or the playback request must be labelled
as such; neither is a measurement of sound reaching a person's ear.
