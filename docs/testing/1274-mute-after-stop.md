# Mute after a two-host playback stop (#1274)

When a host's `stop_playback` promotes another host's queued reply, the controller records
that reply's key and a deadline 100 ms after promotion on its injected clock. The interval
matches the PCM player's silent lead-in. If frame 0 arrives later, it uses the original deadline.

A voice mute before the deadline mutes the player and retires the promoted stream, whether
frame 0 is still missing or already buffered. It cancels scheduled audio and rejects late
frames even after unmute. The reply's text stays in receipt order.

Playback of frame 0 closes the window early. A route change or capture-engine restart advances
the PCM renderer's generation, so a flushed nonfinal frame 0 cannot report that it played.
A final-frame completion still advances the FIFO. Changing the active reply or starting a new
controller playback generation also ends the window. Once it closes, voice mute waits for the
active reply to finish as usual.

## Synthetic evidence pending

`ReplyMuteAfterStopTests` uses the existing in-memory player, explicit playback completions, and
an injected clock. With frame 1 queued at promotion, it covers mute before frame 0, mute after
frame 0 is scheduled, and deferral at the original 100 ms deadline. An engine-free PCM renderer
drives the generation change and completion for two flush cases. A flushed nonfinal frame leaves
B subject to immediate mute, and a flushed final frame releases the next reply.

The suite also covers mute at 99 ms, deferral after a played frame or an expired deadline,
a fresh single-host confirmation, and explicit stop with a second host queued. Assertions cover
pending buffers, late audio after unmute, displayed text, and player and controller mute state.
`ReplyPlaybackStopTests` covers A stopping its queued reply while B awaits frame 0 at the head. Mute 10 ms later applies immediately and B's complete audio remains available for Replay.

The new tests and the existing mute, stop, and paused-queue suites await the owner's host slot.

## Physical two-host check deferred

On one device, play a reply from host A, queue a reply from host B, and speak mute to A.
Verify that B falls silent when mute arrives, the device shows mute on, and B's text and cards
remain visible in receipt order.
