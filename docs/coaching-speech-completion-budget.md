# Complete coaching phrases with bounded completion (#538)

Advice must still arrive through its original, at-most-two-second wire/qualification
deadline. The existing consumer can promote an owned, still-fresh admission exactly
once into a local eighteen-second speech-completion permit. Wire/model output cannot
supply or renew that permit. Its immutable ticket retains the original admission
qualification and request. Heartbeats must continue proving the current private route,
output and generation; they never extend a speech deadline. Replay fencing survives
cue cancellation and expiry.

The existing Jarvis renderer gets four seconds for synthesis and owned cleanup. It
buffers and validates one complete phrase, bounded to576,000bytes (twelve seconds of
mono24kHz PCM16), before emitting contiguous48k chunks. The foreground coordinator
also stages and validates the complete phrase after renderer return, then verifies that
its measured PCM duration fits the remaining completion time before the first player
effect. The existing batch player queues all buffers before play, and the Apple final
native gate repeats whole-duration fit after readiness/queueing callbacks. A budget
veto revokes and clears the unplayed cue while retaining capture. Failed, oversized, odd/empty, incomplete and late phrases cannot publish partial
speech. Text remains bounded to280characters/45words; exceeding the audio/time budget
withholds that cue rather than truncating it. The remaining two seconds are scheduling
margin, not an extension of provider admission.

Duration/renderer-time budget failures retain a fixed `speechFailure` and withhold only
the cue; capture stays open for a later opportunity. Unexpected malformed renderer or
transport output still retires the run. Cleanup is awaited even on failure, while the
initiating failure is retained if artifact retirement also reports an error. A source
which does not settle cancellation retains its one owned slot; no successor can overlap
it. This is bounded resource ownership, not a promise of finite kernel reaping time.

Converted new microphone voice, a validated newer transcript final and the trusted
owner-answering control revoke queued/rendering advice. The transport withholds advice
after new voice until a validated final and while owner activity is busy/unknown. It
never invents speaker identity. The consumer revokes handles before player cancellation;
a cue/effect revision fences already-entered schedule/resume/unmute effects and holds
successor admission until they unwind. New cues supersede pending speech. Capture keeps
its current generation; route loss, capture failure, Stop, Quit and awareness loss still
retire the full run. An old run's callbacks cannot revoke a successor.

`CoachingSpeechCompletionTicketTests` and `CoachingSpeechConsumerTests` cover freshness,
one-time promotion, immutable completion, replay, renewal and revocation/reentry.
`PrivateCoachingPlayerEffectTests.cueCancellationFencesLateWorkWithoutClosingCapture`
reproduced the late-effect race before its fix. `ForegroundCoachingCueRevocationTests`
checks delayed uncooperative rendering, pending playback and admission callbacks.
`ForegroundCoachingSpeechBudgetTests` checks >2s complete speech after admission expiry,
playback-fit rejection before effects and next-cue recovery. `CoachingSpeechRendererTests`
checks >2s/12s PCM, overflow, timeout, ordering, cancellation, failure preservation and
joined cleanup. The existing real foreground/consumer/renderer composition fixture now
includes134,144bytes of authored PCM, over two seconds at its declared format.

These tests use authored clocks, routes, players and PCM. Real configured Jarvis rendering,
actual public-speaker completion, Superwhisper behavior and AirPods loudness must be
reported separately. No replacement microphone/renderer, system default or permission
change is part of this repair.
