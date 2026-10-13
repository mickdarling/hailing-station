# Private coaching qualification — source-only first slice

Part of #269, #268 and #225. Explicitly enabled coaching may continuously forward a room microphone while advice
plays only on verified private headphones. This is not echo cancellation and does not alter ordinary ambient
capture, its plain-engine masking, #346 route rebuild, VPIO, speaker full duplex or cross-device AEC.

`PrivateCoachingSession` is an unactivated local library lifetime with exclusive capture/player ownership. Its
synthetic harness is the first qualification checkpoint, not a shipped app/host feature or hardware proof.

## First-slice acceptance and test expectations

- Default-off state and missing consent/unknown output do not start capture (`defaultOffAndConsentPrecedesCapture`).
- Nonzero synthetic microphone samples continue during qualified advice (`rawCaptureContinuesDuringPrivatePlayback`).
- Actual unknown/changed output vetoes capture, chunks, resume and unmute. Route notification retires queued and late
  advice even if the output returns (`observedUnknownOrDifferentOutputVetoesChunkResumeAndUnmute`,
  `notificationCancelsQueuedAndLateAdviceEvenIfRouteReturns`, `captureObservationVetoesForwarding`).
- Monotonic expiry stops idle capture; renewal cannot extend old tickets or queued audio's original deadline
  (`expiryStopsIdleCaptureWithoutAnotherInput`, `renewalDoesNotExtendOldAdviceAndStaleTimerCannotStopNewLease`,
  `renewalCannotExtendAlreadyQueuedAudioDeadline`, `completedChunksReleaseDeadlineButOldRenewalCannotRefresh`).
- Queue and PCM chunks are bounded (`boundedLifetimeQueueAndPayloads`); partial starts, playback failures, resource
  release and reentrant teardown fail closed (`PrivateCoachingResourceTests`,
  `playerFailureRetiresWholeLifetime`, `stopIsIdempotentAndReentrantBeginIsRejected`).
- Delayed completion and slow route observation cannot erase or revive an expired deadline
  (`delayedCompletionCannotEraseAnExpiredOriginalDeadline`, `slowOutputObservationCannotRenewAnExpiredGeneration`,
  `slowOutputObservationCannotForwardPastExpiry`). Timer setup invalidation cannot report successful admission
  (`synchronousSchedulerInvalidationCannotReturnSuccessfulBeginOrRenew`).

## Contract with RightyO

- Explicit session opt-in and participant awareness/consent precede capture. Speech/model output is not authority.
- Correlation: session UUID, route generation UUID, opaque private destination UUID, qualification UUID (new per
  renewal), request UUID, short expiry. Advice echoes the qualification ID and retains that observation's original
  Hailing monotonic deadline; receipt or same-generation renewal cannot extend it.
- Qualification expires on the local monotonic clock after at most two seconds. Renew within one second from a
  fresh trusted actual-output observation; expiry never re-admits a generation. Cross-process control must not
  deserialize a remote clock instant: receivers enforce a local TTL and exact scope independently.
- Invalidate BEFORE asynchronous route rebuild on every route transition, disconnect, unknown observation,
  speaker fallback, interruption or connection/session loss. Stop playback and coaching capture, cancel provider
  work, clear coaching context and discard queued/in-flight advice. A new begin creates a new generation.
- Revalidate actual output immediately before each audio chunk, resume and unmute; check captured buffers before
  admission. Downstream asynchronous queues also check scope at consumption, not only at enqueue.
- PCM is mono s16le 24 kHz, nonempty and even-byte, at most 48,000 bytes/chunk and 32 outstanding chunks. Completion
  releases each queued chunk's deadline; the earliest outstanding original deadline cancels the entire lifetime.
- No tool/action authority is conferred by qualification. Hailing remains final routing/playback authority.
- Future wire admission must use a bounded ledger of host-issued qualification IDs and their original deadlines,
  then deduplicate producer-issued request IDs once per generation. Request IDs need not be secretly host-issued.
  This core's typed ticket API is not a wire decoder, issued-qualification ledger or replay deduplicator.

## Required integration and physical qualification (not done)

The platform adapter must supply `verifiedHeadphones` only after independently classifying the actual active output.
A2DP and LE are transports, not headphone proof: car stereos may use A2DP. A requested route, device name, readiness,
microphone choice or the existing ambient capture-mode resolver is not sufficient. Unknown output fails closed.
No platform classifier, route-notification wiring, coaching UI, daemon admission or wire control is activated here.
`CoachingAudioPlaying` additionally requires a renderer that cannot activate/reconfigure an audio session or choose
fallback output. The ordinary `PCM16AudioPlayer` does not conform because its preparation can change the route.

The application must own all stop paths and the lifetime, connect suspension to RightyO cancellation/context clear,
and stop it before releasing resources. It must not share the private player with ordinary playback. Software
notification handling alone does not prove the OS cannot reroute already-rendered Bluetooth audio before an
observer runs. A controlled AirPods/room-mic matrix must establish that hardware boundary separately; if the
platform cannot prevent fallback leakage, the topology must remain unsupported.

Rightyo's authored v1 wire guide and five-object synthetic fixture exist, but its executable coordinator/producer
is unfinished. The existing contract artifact is not execution evidence. Combined local producer/consumer
qualification is blocked on that implementation; a hand-invented Hailing fixture cannot stand in for it. This slice
does not resume Rightyo work or alter its priority. Neither the runtime gap nor physical qualification is waived.

No live recording, device installation, deployment, paid provider call or merge is authorized for this slice.
