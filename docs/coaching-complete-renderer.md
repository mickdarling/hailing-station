# Complete bounded speech rendering prerequisite (#538)

The existing PCM-only renderer now validates a complete phrase before emitting it:
four seconds for synthesis/owned cleanup, twelve seconds of mono24kHz PCM16. Failed,
oversized, incomplete or timed-out speech emits no partial PCM. The original failure
is preserved if cleanup also fails; owned cleanup still must settle before reuse.

This stage changes no foreground advice promotion or native playback authority. The
remaining completion-ticket/batch integration must be reviewed before local delivery
of the combined longer-cue fix. Existing rendering latency and hardware audibility are
separate from authored PCM/source tests in CoachingSpeechRendererTests.
