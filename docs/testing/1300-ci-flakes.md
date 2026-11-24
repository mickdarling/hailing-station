# CI flakes in recovery, WebSocket teardown and ambient listening

Host and parallel CI results for these edits are pending. Line numbers below refer to baseline `dc6f7da3`.

## Recovery proof (#1300)

Runs 44893949966 attempt 2 and 44896322421 attempt 1 timed out after 15.898 s and 13.268 s of total test
time. The waiter can suspend at `CodexRecoveryChannel.swift:72`, the reader can validate EOF at line 83
before the deadline, and the waiter can next run after the deadline. Line 64 then skips the snapshot
and line 74 revokes the proof. The logs cannot establish when either reader processed EOF. The Foundation
launch sample is from `PastedContentShellTests.swift:49` on its dedicated executor. Recovery calls
`posix_spawn` before the test starts its deadline.

The channel timestamps EOF under the state lock and joins the reader as well as the child. The test
uses completion to order its observations. A cutoff taken after join accepts terminal proof, a cutoff
taken before prepare rejects it, and ready at EOF is revoked. Worker startup speed is outside this assertion.

## Close during delivery (#1293)

The test awaits its last application send at `WebSocketReceivePumpLoopbackTests.swift:18`, then cancels
at line 21 with delivery parked. Network can return EPIPE on the outstanding receive during teardown.
`WebSocketIngressPump.swift:151` checks that error before the close opcode. EPIPE establishes transport
loss here, while a completed close handshake would require wire evidence. The separate #1293 change makes the
test require a live peer immediately before cancel and accept the exact receive-side EPIPE diagnostic.

## Ambient refusal (#1300)

Run 44893949966 attempt 1 recorded four polls in 10.053 s, a 6.694 s condition check, and a false
final check. `HostConnectionStore.swift:995` clears the toggle. Line 1019 awaits streamer teardown,
then line 1020 releases the session. The log cannot locate the last completed step. The test now waits
for the injected release callback and checks both listening flags, the refusal reason and the release count.

## Verification pending

On the host, run

```sh
taskpolicy -b swift test -j 2 --no-parallel \
  --filter 'CodexRecoveryChannelTests|WebSocketReceivePumpTests/closeObservationRemainsActiveDuringDelivery|AmbientListeningControllerTests/aSendFailureStopsListeningAndSurfacesTheReason'
```

- Confirm both recovery EOF cases execute, late proof times out, invalid trailing output denies recovery,
  and cancellation and idle timeout reap the child.
- Confirm retirement precedes worker release for both admission values. Only admitted work may finish
  and the later input must never be delivered.
- Confirm the synthetic refusal stops listening, preserves “ambient busy” and releases exactly once.

Parallel-runner validation requires the normal CI `verify` lanes on the changed head.
