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

Coaching revocation abandons queued PCM immediately; ordinary graceful PCM EOF remains unchanged.
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
