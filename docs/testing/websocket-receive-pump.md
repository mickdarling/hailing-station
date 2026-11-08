# WebSocket receive pump

Part of #1120.

## Implemented invariants

Each peer has one receive pump and one application worker. Network callbacks classify close, error,
missing metadata, unsupported opcodes and missing application content before application dispatch.
Terminal events retire the peer's `ReplyTransportLifecycle`, clear queued messages and cancel the
connection before scheduling actor cleanup. The callback never awaits session processing, adapter
completion, response transmission or router teardown.

Application callbacks enqueue bytes and immediately arm the next receive. A single worker removes
messages in wire order and awaits all of `session.receive` and ordered response processing before
removing the next message. The peer actor can service closure while that worker is suspended; actor
reentrancy is not used as a serialization guarantee. Transport ping/pong only rearms receiving.

There are at most eight queued application messages and at most
`2 * PayloadLimits.defaultMaxFrameBytes` queued bytes (182,954 bytes). These bounds exclude the active
message and one receive bounded by the listener's existing `maximumMessageSize` (91,477 bytes).
A single application message also must fit that frame limit. Exceeding either queue bound retires
and terminates the peer immediately. Receiving never pauses to wait for capacity.

Protocol closure, hello timeout, listener shutdown, connection failure and send cancellation retire
the same lifecycle and stop the pump. The lifecycle's retirement observer clears the pump even when
listener-wide retirement precedes asynchronous peer cleanup. One receive already submitted to Network
may complete after local stop; it cannot enqueue application work or rearm receiving.

A submission already admitted at paste launch retains its bounded completion. Pending submissions
refuse after retirement. No application task is cancelled to recall an admitted submission. The pump
retains a worker-task snapshot so a caller can join outside the peer actor; closure and shutdown do
not join it. Tasks are created only when an idle worker becomes active, not for queued messages or
transport ping/pong.

## Lock order

The new pump state mutex protects only start/stop flags, receive reservation, worker ownership,
queued data and byte accounting. No synchronous callback, lifecycle operation, session operation,
Network call or asynchronous wait runs while it is held. Worker task creation only records the task;
the task must acquire the state mutex separately before removing any data.

Pump stop first retires the lifecycle, releases its gates, and then acquires pump state to clear the
queue. Lifecycle retirement invokes its observer only after releasing the retirement mutex and the
transport publication authority. Registration is under the lifecycle mutex; an immediate observer
callback also runs after releasing it. Pump state never nests a lifecycle, reply-permit, binding,
router, privacy or policy lock. No new path acquires router, privacy or policy while holding lifecycle,
reply permit or binding lease. Existing delivery-stage order remains unchanged.

The worker holds no pump lock while entering the peer actor, `HostSession`, adapter or response send.
Neither pump callbacks nor peer closure turns wait for the worker. The worker's task snapshot is read
under pump state and awaited only after releasing it, by the tests.

## Synthetic evidence

`WebSocketReceivePumpTests.closeObservationRemainsActiveDuringDelivery` uses a loopback WebSocket,
production `TmuxAdapter`, and a guarded scripted runner. Its first message parks in `beforeResponse`
before paste `launch.perform`. After the acknowledged park, the client sends a second application
message followed by transport close. The test awaits the peer's disconnect event and asserts lifecycle
retirement and peer termination while the first delivery remains parked. Only then does it release
and join the recorded worker. No paste or Enter executes, and only the first paste command was prepared.
The companion argument parks before Enter after paste admission: that submission completes exactly
once after close, and the queued second message never starts delivery. Disconnect may be reported as
the classified close or Network cancellation; retirement precedes either cleanup notification.

Other cases cover ordered text/select/text through real sessions, a transport pong during suspended
application processing, a single active worker, exactly one outstanding receive, count and byte
boundaries, queue clearing on direct lifecycle retirement, malformed metadata, receive failure,
protocol closure, hello timeout and listener shutdown. Synthetic count/byte tests fill exactly to the
bound before overflowing and prove that receiving remains armed at the bound. Loopback count/byte
overflow cases prove peer termination before releasing delivery.

Ordering uses acknowledged entry, release, disconnect and completion barriers. Deadlines are
watchdogs, except the hello timeout and the existing elapsed-age assertion, which explicitly measure
time. No sleep or scheduler-yield loop establishes message ordering. Scripted runners execute no tmux
process. These tests do not establish device capture, playback or a live captured-output round trip.

## Existing test assertion accounting

Only the three test-only carries below modify existing test files. Existing receive/listener and final
delivery test bodies are unchanged. No existing assertion is weakened or removed.

| Existing test / assertion | Status | Accounting |
| --- | --- | --- |
| `TaskProgressTmuxAdmissionTests.wakeAttemptCommitsOnlyAtPasteAdmission`: tainted refusal type | KEPT | Existing assertion unchanged. |
| Same: no committed attempt on tainted refusal | KEPT | Existing assertion unchanged. |
| Same: no later capture, buffer, paste or key commands on tainted refusal | KEPT | Existing assertion unchanged. |
| Same: established taint's delivered text and Enter | KEPT | Existing assertion unchanged. |
| Same: no attempt at set-buffer preparation | KEPT | Existing assertion unchanged; additional paste-launch case below. |
| Same: no delivered keys before preparation release | KEPT | Existing assertion unchanged. |
| Same: delivered outcome, committed attempt and text/Enter after release | KEPT | All three existing assertions unchanged. |
| New `wakeAttemptRemainsUncommittedBeforePasteLaunch`: attempt boundary | TIGHTENED | Parks on recorded paste-buffer in `beforeResponse`; asserts no attempt and no delivery before `launch.perform`, then delivered outcome, committed attempt and text/Enter after release. |
| `TmuxRefusalEvidenceTests.aConfirmedInsertThatCameBackIsNamedStaleAndOwnWithItsLengthAndAge`: refusal type | KEPT | Existing assertion unchanged. |
| Same: delivered text and Enter remain unchanged by refusal | KEPT | Existing assertion unchanged. |
| Same: one confirmed submit evidence line | KEPT | Existing assertion unchanged. |
| Same: exactly one refusal evidence line and parsed whole-second age | KEPT | Existing requirements unchanged. |
| Same: age is within 1...30 seconds | KEPT | Same monotonic deadline; suspending clock wait replaces yield-based polling. |
| Same: exact refusal evidence with the observed age | KEPT | Existing assertion unchanged. |
| Same: token-only evidence excludes synthetic payloads | KEPT | Existing assertion unchanged. |
| `TmuxAuthorityBoundaryTests.retirementAfterPasteCompletesBeforeTheNextTerminalRefusal`: delivered first outcome | KEPT | Existing assertion unchanged. |
| Same: next terminal message has exact notAllowed response | KEPT | Existing assertion unchanged. |
| Same: only first text pasted | KEPT | Existing assertion unchanged. |
| Same: no subsequent capture, set-buffer, paste-buffer or send-keys | TIGHTENED | Each argv element is searched for each command substring, including if-shell command strings. |
| Same: exactly one Enter and empty input | KEPT | Both existing assertions unchanged. |

All other tests in those files remain unchanged. The elapsed-age clock wait is intentionally a time
measurement, not a replacement for an ordering barrier. The runner responder executes inside the
guarded `launch.perform`; the paste-launch park precedes that call.

## Verification

Verification results are recorded after the VM runs. No host build or test is part of this evidence.
