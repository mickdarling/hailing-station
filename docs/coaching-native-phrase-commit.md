# Native complete-phrase commit prerequisite (#538)

The existing private consumer/audio port now has a complete-phrase batch operation.
It validates contiguous mono24kHz PCM16, one final payload, the existing chunk/count
limits and twelve-second aggregate budget before native effects. It reuses the existing
player.replaceQueue operation, which queues every buffer before its first play.

The Apple authorization gate carries the full PCM duration through readiness/route
callbacks. Its final callback-free time/route/ticket-revision/consumer-ledger check must
still fit that duration before actual native play. If readiness or queueing consumes
the remaining completion budget, the gate revokes the cue before returning its veto,
clears unplayed PCM, and preserves capture. The fixed durationExceeded reason is retained.
Each effect still needs the original current route/generation and immutable host permit.
No byte, provider or deadline authority comes from received text.

CoachingCompletePhraseCommitTests uses the real private consumer and existing native
renderer with authored operations: all buffers precede play; slow readiness and slow
last-buffer queueing veto before play; cue revocation inside readiness suppresses old
batches; malformed/oversized arrays cause no effects. These are source simulations,
not actual device playback or exact Superwhisper behavior. Foreground activation and
combined delivery remain dependent work; no intermediate stage is installed.
