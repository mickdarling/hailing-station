# Reply frame cap and detached job endings (#1241)

Part of #1241. Host implementation; synthetic verification results are recorded below. No installed daemon,
application, TestFlight build, physical device, or live captured-output round trip is changed or validated here.

Queued audio publication uses `FrameCoding.encoder()`, including `withoutEscapingSlashes`, for the entire
local queue envelope. Canonical base64 has a content-independent encoded length. The sender encodes an empty
audio envelope with its actual ticket and reply identity, the longest sequence and timestamp, and the optional
segment-end flag. It fills the remaining frame budget with whole base64 quads and whole PCM16 samples, capped
by `maxAudioBytes`. The 24,000/36,000/60,000-byte ramp and 48 KiB file chunks are bounded by that capacity.
This single conservative calculation avoids splitting already-sequenced frames. The final encoded-size guard
remains in place.

A detached job sends one content-free `reply-job-ended` local request after cleanup. Its stderr relay is gone
after ready, so the owner-only reply socket delivers the record to the daemon, which writes exactly:

```text
reply_job_ended reason=done|refused|bound|signal|publication_failed frames=<n> audio_ms=<n>
```

The record contains no target, host, reply identity, text, or PCM. Frames count acknowledged publications,
including text and terminal frames; audio duration excludes the two-byte terminal marker. The first failure
is recorded before terminal recovery and renderer cleanup, so a secondary failure cannot replace it.
Explicit host refusals and the daemon's existing `publicationFailed` response are distinguished. Telemetry
uses a separate bounded socket budget and one transaction, without an ambiguous-acknowledgement retry.
If the daemon/socket is unavailable, this best-effort local report cannot reach its log.

The caller forwards cancellation to the job PID; the job retains ownership of renderer cancellation.
After ready, SIGTERM, SIGINT and SIGHUP are ignored by the job. Before ready, SIGTERM/caller loss still cancels
cooperatively; direct SIGINT/SIGHUP retain their original pre-ready dispositions. Host refusal, supersession,
publication failure and the existing wall-clock bound still stop the job.

There is no existing ordinary reply-stream abort marker that old devices understand. The normal terminal
marker remains unchanged. Device-visible failure needs a follow-up capability-gated failed/aborted terminal
flag; the new telemetry is local to the host and never forwarded to a device.

Production files: **3**, using `scripts/pr-shape.py` exclusions:

- `Sources/haild/ReplyCommand.swift`
- `Sources/haild/ReplyBackground.swift`
- `Sources/HailDaemonKit/PushEndpoint/LocalReplyEndpoint+Submission.swift`

Test and fixture files:

- `Tests/HailCoachingCommandTests/QueuedAudioEncodingTests.swift`
- `Tests/HailDaemonKitTests/ReplyJobEndTests.swift`
- `Tests/ReplyCLITests/test_reply_job_end.py`
- `Tests/ReplyCLITests/test_reply_cli.py`
- `Tests/ReplyCLITests/test_reply_segments.py`
- `Tests/ReplyCLITests/test_reply_ticket_release.py`
- `Tests/ReplyCLITests/fixtures/vbsay`

Verification uses both host gates (`hostslot-wait.sh`, then `voice-quiet.sh`) before each phase, background
policy, two Swift build jobs, serial tests, and an 810-second work watchdog per phase.

Results on implementation commit `cf5612f4c0852b79f5180c6c687a57bd98981f4a`:

- The expanded Swift filter passed **153 tests in 55 suites** with no parallel test execution
  (184.731 s; the incremental build completed in 141.50 s).
- The four full Reply CLI modules passed **76 tests** (273.300 s), after the implementation commit.
- Strict host lint passed on all five changed Swift files. Python syntax and whitespace checks passed.
- Earlier checks passed 31 queued CLI tests (91.235 s) and 31 selected streaming/signal/failure CLI tests
  (92.178 s); the `haild` product and command-test target also built successfully.

The cold build was continued in bounded phases. Native compiler caching and disabled IDE indexing preserved
progress without changing source or test semantics. The first expanded run exposed an overlong synthetic
Unix-socket path in the new endpoint test; shortening its UUID suffix fixed the fixture. The passing rerun
covers that correction, which was already included in the implementation commit.

`LocalReplyEndpoint+Submission.swift` is a security-critical path. Its change is limited to a closed-vocabulary,
nonnegative-counter telemetry model, a separate bounded admission bucket, and consuming the existing owner-only
socket request into the daemon's stderr log. It never invokes publication routing, changes reply authority,
or forwards telemetry to a device. A future PR must retain `security:critical` and complete the repository's
independent review requirements; no such review is claimed here.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build -j 2 --product haild
taskpolicy -b swift build -j 2 --target HailCoachingCommandTests
taskpolicy -b swift test -j 2 --no-parallel --disable-index-store \
  -Xswiftc -explicit-module-build -Xswiftc -cache-compile-job \
  -Xswiftc -cas-path -Xswiftc "$PWD/.build/verification-1241/cas" -Xswiftc -Rcache-compile-job \
  --filter 'QueuedAudioEncodingTests|ReplyJobEnd|LocalReplyEndpoint|ReplyQueuedAudio|ReplyBackground|Reply.*Stream'
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests -k queue
PYTHONPATH=Tests/ReplyCLITests taskpolicy -b python3 -m unittest \
  test_reply_job_end.ReplyJobEndTests.test_publication_failure_logs_primary_reason_after_terminal_recovery \
  test_reply_job_end.ReplyJobEndTests.test_signals_after_ready_preserve_both_chunks_and_terminal \
  test_reply_job_end.ReplyJobEndTests.test_sigterm_before_ready_still_cancels \
  test_reply_job_end.ReplyJobEndTests.test_static_publication_failure_stays_primary_when_terminal_is_refused \
  test_reply_ticket_release test_reply_segments \
  test_reply_cli.ReplyCLITests.test_interrupting_the_caller_cancels_a_stalled_renderer_and_cleans_up \
  test_reply_cli.ReplyCLITests.test_vbsay_stdout_is_relayed_in_ramped_frames \
  test_reply_cli.ReplyCLITests.test_request_identity_is_shared_by_text_and_static_pcm_segments \
  test_reply_cli.ReplyCLITests.test_request_identity_is_shared_by_vbsay_text_pcm_and_final_marker \
  test_reply_cli.ReplyCLITests.test_accepted_text_then_refused_audio_preserves_fixed_primary_publication_failure \
  test_reply_cli.ReplyCLITests.test_accepted_text_then_lost_audio_ack_preserves_primary_failure_without_whole_command_retry
taskpolicy -b swiftlint lint --strict --quiet \
  Sources/haild/ReplyCommand.swift Sources/haild/ReplyBackground.swift \
  Sources/HailDaemonKit/PushEndpoint/LocalReplyEndpoint+Submission.swift \
  Tests/HailCoachingCommandTests/QueuedAudioEncodingTests.swift Tests/HailDaemonKitTests/ReplyJobEndTests.swift
```

`QueuedAudioEncodingTests` checks all-0xff PCM and a synthetic quiet/varied mix against the old escaping encoder,
then checks canonical acceptance across worst-envelope, random and worst-case PCM, ramped sizes and calculated
capacities. The socket test accepts slash-heavy queued audio and consumes end telemetry without device output.
CLI tests check the entire slash-heavy stream and terminal, publication failure and recovery, a lost static-audio
ack followed by a refused terminal, signal immunity between two renderer chunks, and cancellation before ready.
Existing segment cancellation expectations now use pre-ready cancellation or host refusal, matching #1241.

Post-commit full CLI verification (a separate gated phase):

```sh
cd Tests/ReplyCLITests
taskpolicy -b python3 -m unittest test_reply_job_end test_reply_cli test_reply_segments test_reply_ticket_release
```
