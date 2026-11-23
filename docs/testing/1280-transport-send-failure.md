# Ambient send failure before reconnect publication

Part of #1280 and slice 3 of #1283.

A live audio write can fail while the socket is ready and receive is still open.
The store identifies writes made for the audio binding so the raw socket callback
can defer to the caller that knows the stream and the error. The store checks
capture admission, the active stream and the selected binding. The controller
also checks its session and streamer when handling the sender's returned error.

A transport loss that passes those checks closes audio admission, retains
listening intent and requests a paced retry for the failed socket generation.
The connection checks that the same socket is still ready before replacing it.
A receive failure and state transition for that generation share the pending
recovery. A healthy capture resumes on a fresh stream at sequence zero with the
resume flag after target reauthorization and any required privacy confirmation.

If capture ends during the gap, the existing failed-recovery notice says
“Connection dropped; listening stopped, tap to resume”. Rebuilding an ended
capture belongs to the broader epic.

## Synthetic tests awaiting execution

The send-only test queues a synthetic peer and sets the retry clock to return
immediately before it fails the first write. Only production code closes the
original socket and initiates the replacement. Scripted pongs confirm selection,
and the replacement peer records the resumed audio.

| Case | Expected observation |
| --- | --- |
| ENOTCONN at the controller or socket, with receive open | One close, two total opens, fresh sequence-zero resume audio to the original target, one applied notice and no unexpected stop. |
| Replacement peer sends “ambient moved to pad” after send-only recovery and before its acceptance pong | Listening stops with the iPad handoff reason, and the applied notice changes to failed with the same notice ID. |
| Send and receive report the same loss | One pacing owner, reconnecting status, retained intent and discarded gap audio. A subsequent loss on a different generation counts as an interruption. |
| URL cancellation at either send boundary | The ordinary stop callback receives the cancellation reason. Recovery stays idle and the socket stays open. |
| Old stream's held socket write fails after a new capture sends on the same binding | The new stream continues sending, with one total socket open and no recovery or stop notices. |
| Remote refusal, policy stop, codec error or stale selection | The existing stop reason reaches the ordinary stop callback. |
| Owner off or privacy tap during retry backoff | One blocked notice. Listening stays off and the replacement socket receives no audio. |
| Capture ends during recovery | One tap-to-resume notice and no ordinary unexpected-stop callback. |

The focused host command is
`swift test --filter 'AmbientTransportSendFailureTests|AmbientReconnectSocketIdentityTests'`.
Build, focused tests and broader reconnect/privacy regression results are pending
for this revision.

## Physical check deferred

On an iPad or iPhone, interrupt the active network path while ambient audio is
sending, then restore connectivity. Verify that fresh microphone audio reaches
the original destination after reconnect and that the device gives one recovery
notice. Repeat with owner Off and with a privacy tap during recovery, and verify
silence after reconnect. Physical flaky-network behavior remains unverified.
