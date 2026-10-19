# Speech-stop test entry prerequisite

Part of #269. This test-only prerequisite addresses a full-verifier failure encountered during native
private-coaching integration. It changes no recognizer, capture, deadline, timeout or runtime behavior.

`startIsBlockedWhileStopBeginsFinalization` created concurrent stop tasks without proving actor entry
before releasing blocked backend cleanup. The failed log records a concurrent-stop result mismatch,
not entry ordering. A controlled authored-backend probe demonstrates the permitted failure class:
a task created before cleanup but entering `stop` afterward legitimately receives an empty terminal
result. This does not prove the exact historical scheduler interleaving.

The test-only actor-isolated wrapper signals entry and directly calls `stop` on that same actor.
Both concurrent callers now establish entry before the blocked backend phase is released. All three
original `finished` assertions remain unchanged. A separate gated late-entry regression proves that
task creation is not entry and expects the legitimate empty terminal result. No production seam,
sleep, relaxed expectation, finalization timeout change or unchanged broad retry was introduced.

All backend events and text are authored synthetic fixtures. No real speech recognizer, microphone,
device selection, audio IO, recordings, provider call or deployment was used.
