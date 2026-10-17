# Owned coaching child control prerequisite (#269 / #268 / #225)

Source-only, default-off. `RightyoCoachingLaunch` opts the existing RightyoChildProcess into listen
coaching while preserving its owned group/raw PCM stdin/JSONL stdout behavior. The ordinary ambient
and reply-control defaults do not change. Coaching and ordinary reply control cannot share fd3.
Canonical nonzero session UUID is required; mock suggestions require declared synthetic provenance.
No process, capture, model or output route starts merely by linking these types.

The coaching fd has a separate writer: serialized nonblocking partial writes, one ASCII object per
line, <=8192 bytes, <=32768 queued bytes / 128 lines, <=4096 accepted records per child. Each record
has an original monotonic validity deadline and <=250ms total queue/pipe budget. Overflow, expiry,
closed peer and write error revoke the channel and stdout stream rather than splice/drop controls.
The exact control/profile/activity schema remains validated by Rightyo's coaching-only receiver.
Queue admission is not receipt or authorization. The host's original private advice ticket remains
authoritative after any queue delay. Only trusted local host controls can call this API.

An idle writer checks its owned pipe for POLLHUP/POLLERR/POLLNVAL every 25ms; output admission also
checks that pipe synchronously before and after suspension. Probe and close share the descriptor lock,
so a queued old probe cannot inspect a reused descriptor. Closing or dropping the writer cancels the
weakly captured watcher. Authored idle-close and closed-peer/buffered-stdout cases fail on the prior
source; the watcher-release control verifies that explicit close cannot report a later channel failure.

Coaching revocation abandons queued PCM immediately; ordinary graceful PCM EOF remains unchanged.
Explicit graceful coaching EOF also preserves already-buffered terminal output, including owned-group
stream completion. Local graceful close and peer/write failure are distinguished under the descriptor
lock; a rejected send after local EOF cannot convert that EOF into a failure. Explicit revocation or
abandonment before or after graceful close always wins. The existing output fence/sequence is located
beside child control; no second stream, producer or capture backend is introduced.
The foreground adapter must consume stream failure as off, cancel capture/TTS/private playback,
and join its owned child through the existing group supervisor. No hook bypass or unrelated PID
signalling is added. stderr remains discarded with only a byte count. There is no transcript/audio
archive, action dispatcher or ordinary reply publication in this prerequisite.

Tests use synthetic local pipes and the existing owned FakeRightyo harness. The actual Rightyo
executable/coordinator/command integration and independent full exact-head review remain required.
No live device query, audio, provider inference, public change, installation or deployment is proof here.

This slice preserves history and integrates the corrected foreground coordinator at
8bc59c08644db987a3d3d16a8ba97869ad5d7545, independently approved by two full Round3 reviews.
The child-control diff requires its own completed exact-head review and full verification; coordinator
approvals do not approve this fd/process change or establish executable end-to-end operation.

Independent full child-control Round1 rejected 8256e72a9f5c5dc7146a7e73c8b299a7ddb74897:
the inherited PCM writer could write after a POLLOUT wake without rechecking abandonment. A red-before
filled-pipe regression reproduced old queued bytes after coaching control failure returned. Each
nonblocking write now shares the abandonment/close ownership lock; graceful ordinary EOF still drains
queued PCM. Historical diagnostics are preserved. Fresh exact-head full review remains required.

The same review also reproduced buffered advice delivered after stream failure: finishing an
AsyncThrowingStream preserves buffered values. Coaching output now has a separate shared revocation
fence checked before and after each suspended delivery. Control failure, explicit abandonment and
owned group loss revoke it; ordinary graceful EOF still delivers buffered terminal output. A red-before
buffered-output regression failed before this correction. No old diagnostics were removed.

Local EOF polls the still-owned control descriptor under its close lock before granting graceful
output semantics. A peer loss already present at that boundary revokes instead, even if the idle
watcher has not run. RightyoCoachingGracefulRaceTests withholds the actual writer queue, closes the
peer first, and asserts that buffered output remains refused after local close and group completion.
The regression fails before the synchronous close probe; healthy graceful EOF controls remain covered.

A close with a partly written control record revokes output instead of granting graceful EOF after
truncated JSON. An authored real-pipe regression fills/backpressures the pipe, observes a partial
record, withholds the writer retry, then closes and verifies that buffered output is refused.
Hard stdin write failures now use the same coaching revocation/stream-failure fence. The existing
RightyoStdinWriter is moved unchanged into its own file except for that failure propagation, keeping
both files within the repository length rule. An authored child closes stdin while keeping control
and stdout open: coaching refuses its later output; ordinary non-coaching output remains unchanged.

Coaching also observes the existing owned-leader exit latch directly. Output admission checks that
same latch before and after awaiting a line; a delayed group-abandon callback or inherited control
fd cannot preserve output from a lost producer. The observation task retains only the latch/fence/
continuation and finishes revoked streams promptly; graceful EOF remains allowed to drain terminal
lines. An authored leader-exit/descendant-retained-fd regression fails before this correction.
