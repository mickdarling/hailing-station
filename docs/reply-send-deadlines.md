# Host reply send deadlines (#904, PR A)

Part of #904. Host-side source and synthetic verification only; no deployment,
installed-build change, device playback, captured-output round trip or physical
load/backpressure measurement is claimed. The issue specification supplied for
this offline implementation is the work record; no remote issue or PR was changed.

## Confirmed cause at 0e5102ac3b3fac6020a12d714c7e89a396ffb7b3

Each CLI frame is its own local submission. The default submission timeout is ten
seconds (`LocalReplyEndpoint.swift:95`). `startSubmission` arms the deadline
(`LocalReplyEndpoint+Submission.swift:198`); `expireSubmission` retires the local
client (`:157`) and `retire` cancels its submission task (`:316` on that base).
That cancellation reaches `PreparedWebSocketReply.result()`'s cancellation handler
(`WebSocketPeer.swift:379`). `cancelResult` retires the peer transport (`:392`)
and invokes the connection cancel closure (`:393`, defined at `:326`). Both host
reply delivery paths then finish with the generic `host reply send failed`
(`HostReplyDelivery.swift:492`, `:518`). The content-processed callback discarded
NWError at `WebSocketPeer.swift:324`. The code confirms this causal path; it does
not establish which scheduling or device-read delay occurred in the reported event.

## Implemented boundary

`PreparedWebSocketReply.Outcome` distinguishes sent, failed with the NWError
description, abandoned after enqueue, and refused before enqueue. Cancellation
before admission still prevents submission. Cancellation after admission completes
the waiter promptly with abandonment, without retiring transport or reporting
success. Abandonment remains ambiguous: the host publication code returns its
existing non-retryable refusal, never `requestPending`. The existing synchronized
policy, binding and terminal transport gates still order actual enqueue against
closure. Restoring policy cannot restore a retired transport permit.

An abandoned pending send gets one watchdog using the named
`abandonedSendGrace` (30 additional seconds). A completion removes and cancels the
watchdog. A successful late completion preserves the abandoned caller outcome;
an error closes the peer with `host reply send failed: <NWError>`, even after the
waiter has left. Expiry closes it with `host reply send stalled`. Duplicate/late
callbacks cannot resume the waiter twice or close it again. An inline synthetic
error completion schedules retirement off the enqueue stack to avoid reentering
the transport gate. Peer finish retires transport before cancelling the connection.

The local endpoint logs a fixed deadline-expired/ambiguous message only while the
submission is still registered. The peer logs abandonment separately from an
error or stall disconnect. These new diagnostics contain no reply content,
provider identity or endpoint. Each watchdog is released on completion or expiry;
there is no polling loop or repeating timer.

`WebSocketPeer.send(_:)` is unchanged. Its callers are protocol responses and
ambient-failure/mute/stop control messages (`WebSocketPeer.swift:160`,
`WebSocketListener.swift:411`, `:437`, `:453`). Reply data publication uses
`prepareReplyPublication` and `deliverHostReply`/`deliverRoutedReply` instead;
the local reply frame's submission deadline does not cancel the ordinary send path.

## Existing CLI and device behavior (unchanged)

At the local submission deadline the endpoint closes the CLI's Unix connection;
it does not send a successful delivery acknowledgement. The client normally sees
`response ended early` (`Sources/haild/ReplyCommand.swift:827`); its own 15-second
transaction timeout (`:713`) can win if scheduling is sufficiently delayed. Neither
is retry permission. `ReplyClient.submit` only retries typed zero-delivery
`requestPending` (`:600`), and propagates transaction failures (`:597`). Detached
jobs additionally retry explicit pre-publication rate limiting, not this outcome
(`:922`). Rendered speech maps publication failure to its fixed error category
(`:376`), preserving a failed command rather than a success summary.

Remaining data frames are aborted. Both the streamed renderer (`:427`) and static
PCM path (`:316`) attempt a best-effort final marker after earlier acknowledged
audio (subject to the renderer's frame budget). They increment their sequence only
after acknowledgement (`:406`, `:313`), so the recovery marker reuses the timed-out
frame's sequence. For a correlated reply, host media admission already advanced
that sequence at enqueue (`HostReplyDelivery.swift:127`, `:331`), so this marker is
refused. A requestless fallback has no equivalent media pinning (`:380`), so it may
forward the marker, but the device refuses its conflicting payload at that sequence
(`Sources/HailCore/Replies/ReplyPlaybackController.swift:103`). WebSocket ordering
keeps it behind the original enqueued frame.

Thus an abandoned non-final midstream frame may still reach the device, while the
remaining audio and a usable terminal marker never arrive. On the unchanged device,
an unheld head stream expires 20 seconds after its latest frame/scheduled audio
horizon (`ReplyPlaybackController+Idle.swift:11`, `Announcer.swift:187`); abandonment
records audio loss and advances the queue (`ReplyPlaybackController+Idle.swift:125`).
Pause, capture suppression and interruption hold that watch. If the timed-out frame
was itself final and later arrives, the device can finish normally despite the CLI
failure. If the text frame times out, the CLI stops before generating speech. The
preserved connection keeps ambient listening available; it does not complete the
aborted reply or prove that any audio was heard. CLI/device recovery is deferred
beyond this host-only slice.

## Synthetic traceability

- `deadlineAbandonmentPreservesTransportRegression904`: refused waiter, no transport
  cancellation/retirement, and a later frame can enqueue.
- `lateCompletionAfterAbandonmentFailsOnlyForTransportError`: late success/error,
  stable abandoned outcome, duplicate callback protection and watchdog cleanup.
- `abandonedSendGraceClosesOnceAndRefusesLaterEnqueue`: bounded stall, specific
  reason, no publication through a previously prepared permit after closure.
- `inlineTransportErrorIsTypedAndClosesWithoutReenteringPermitGate`: typed real
  error and safe retirement even with synchronous synthetic completion.
- `staleEnqueueResumesAlreadyWaitingCaller`: refused enqueue cannot strand a waiter.
- `submissionDeadlineRefusesAmbiguouslyWithoutDisconnectingSession`: a real
  owner-local Unix endpoint with a 100 ms timeout and held synthetic send; EOF,
  abandoned result, live peer and a later enqueue. This composes the real peer
  outcome handler, not a physical WebSocket or full listener publication round trip.
- `lateFailureOrStallLogsSpecificDisconnect`: actual peer disconnect diagnostics.
- Updated prepared/terminal transport tests retain pre-enqueue refusal, current
  peer independence, pending-waiter ownership and actual closure checks. The
  correlated retirement fixture now holds a real close-frame submission instead
  of using caller cancellation as a surrogate for peer closure.

## Verification on the Dev Work VM

Every Swift command below ran under `taskpolicy -b`, with `--jobs 4` and these
appended toolchain flags (no package installs or remote access):

```sh
flags=(
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
taskpolicy -b swift build -Xswiftc -warnings-as-errors --jobs 4 "${flags[@]}"
taskpolicy -b swift build --build-tests --jobs 4 "${flags[@]}"
# Each of 20 serial runs:
taskpolicy -b swift test --skip-build --no-parallel --filter \
  'PreparedWebSocketReply|ReplySendDeadline904|LocalReplyEndpointSendDeadline904|TerminalReplyTransport' \
  --jobs 4 "${flags[@]}"
taskpolicy -b swift test --skip-build --no-parallel --filter \
  'PreparedWebSocketReply|WebSocketPeer|HostReplyDelivery|LocalReplyEndpoint|ReplyRecipient|LateAnswer|LocalDispatch|CorrelatedReplyPublication|ReplyPlaybackRecipient|OwnedReply' \
  --jobs 4 "${flags[@]}"
```

Each invocation ran in its own process group under a Python guard with INT, TERM,
HUP and 590-second alarm kill handlers (TERM, then KILL after three seconds), plus
finally cleanup. No phase reached the limit. Tests were serial and builds used
at most four jobs. Logs remain in the host's temporary evidence directory.

On base 0e5102a, the compatibility-form regression alone ran one test and failed
three expected assertions: cancel closure called once instead of zero, transport
retired, and no later permit. The baseline filtered run used that same compiled
base plus the regression: 174 tests/32 suites, the same three expected regression
issues and five known issues, with no other unexpected failures.

Final warnings-as-errors build and build-tests passed. An initial build-tests
attempt caught legacy Bool assertions in TerminalReplyTransportTests; those were
updated for typed outcomes before the successful build. All 20 repetition runs
passed 16 tests/4 suites each (320 total test executions, including seven new test
functions per run). The requested wider filter passed 175 tests/33 suites, with
five known issues also present on base: one intentional missing-handoff issue,
two cancellation-before/after-registration cases, and two second-waiter cases
in ReplyRecipientHandoffWaitTests. No unexpected OwnedReply failure occurred in
this filter on either revision. Coaching suites and a full-suite run were not
requested or run; no claim is made that their VM-specific failures were fixed.
`git diff --check` passed. SwiftLint is unavailable locally; nothing was installed.
