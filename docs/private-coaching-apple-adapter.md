# Apple private coaching adapter — inactive local composition

Part of #269, #268 and #225. This separate slice follows the reviewed core and wire consumer. It leaves
ordinary ambient masking, #346 route rebuild, existing players, UI, daemon and installed apps unchanged.

## Actual production integration

The iOS `ApplePrivateCoaching` initializer creates an exclusive `AVAudioEngine`, attaches a dedicated
`AVAudioPlayerNode`, and composes `AVAudioEngineCapture`, `CoachingEngineRenderer`, `CoachingOutputMonitor`,
`PrivateCoachingSession` and `CoachingAdviceConsumer`. Construction does not start the engine or microphone.
Only an explicit consent-confirmed `begin` may start capture. Buffer and suspension hooks are the owner's
existing downstream seams; the suspension hook must cancel its provider/render work and clear context.
No app or daemon constructs or enables the composition by default; no cross-process controls are wired here.

The separately reviewed capture-run identity prerequisite fences old stream termination callbacks before
immediate reuse. `AppleCoachingProductionCaptureTests` exercises two immediate `begin` calls through the
actual capture/composition with injected engine operations, then forwards a synthetic microphone buffer and
schedules advice on the replacement lifetime. No live engine operations run in that regression.

The monitor reads `AVAudioSession.sharedInstance().currentRoute.outputs`, not an input selection or requested
route. Only one actual `.headphones` port with a nonempty UID qualifies as wired headphones. The transient
UID never leaves the monitor; downstream correlation receives a new opaque token per arm. Empty, mixed,
unknown, speaker, AirPlay, USB, HDMI, car and every Bluetooth output are unqualified. Native macOS is also
unsupported by this adapter. A route observed to change without notification retires rather than re-arms it.

Route, interruption, media-service loss/reset, app-resign/background and engine-configuration notifications
retire a thread-safe latch on the posting thread. Later main-actor cleanup invalidates the consumer/core,
cancels playback, stops owned capture and invokes context clearing. The latch vetoes consumption before
that actor hop; an old event cannot invalidate an explicitly re-armed newer lifetime. Connection, permission
and participant-awareness loss must explicitly call `invalidate` before asynchronous owner rebuilding.

The dedicated renderer converts bounded mono s16le 24 kHz PCM, schedules it on the already-running capture
engine and controls only its node. It never calls session activation/category/input/output selection, starts
an engine, moves to another engine or chooses fallback output. A stopped engine or invalid route cancels
instead of resuming. Queue replacement validates all payloads before changing playback. This is actual
AVAudioPlayerNode production implementation, with synthetic operation seams for tests—not an audio fake
presented as hardware proof.

The renderer is default-denied. The owning composition supplies a synchronous original-ticket gate around
schedule/resume/mute. After route observation and conversion, each queue/play/resume/mute effect rechecks
that exact ticket's scope and authoritative deadline, not a later renewed lease. The scoped gate is retired
on return/throw; mute denial propagates through the owning throwing API despite the player protocol's void
mute seam. `AppleCoachingEffectDeadlineTests` advances time inside renderer observations without firing
actor timers; the previous source fails all three effect cases. Renderer tests cover lost authority after
queueing and lost engine readiness inside the gate. These are software checks, not hardware-atomic guarantees.
Every void-mute readiness failure is also recorded, including engine/route denial before its ticket gate runs.
The owner disarms/invalidate-clears that lifetime before surfacing the error; repeated cleanup is idempotent.

Renewal failure cleanup owns the exact input lease, then the exact returned lease during consumer
registration. A stale renewal or an observation that publishes a newer lease in the same generation
must fail without stopping that newer capture/ledger. AppleCoachingRenewalOwnershipTests reproduces
both schedules; fresh advice remains usable, and explicit Stop still retires capture once.
The route-loss-inside-unmute regression fails on the prior source and asserts prompt capture/context retirement.
The separately reviewed generation-cleanup prerequisite preserves a successor created synchronously inside
an old route or clock observation. Renderer denial cleanup is scoped to its originating generation;
failed renewal is scoped more narrowly to its exact lease. Old work cannot disarm a new monitor,
cancel its queued advice or stop its capture.
Replacement regressions exercise core, renderer and final-gate observations across schedule/resume/mute,
plus failed renewal after an explicitly begun successor. The old operations fail; fresh advice remains usable.
Arm and observation failure retire only their captured monitor revision, including a successor on a different
qualifying wired UID. Failed begin cleanup owns only its exact started lease (or an empty lifetime before start),
not a successor created during arm or registration. Round5 source fails the new monitor/startup regressions;
their evidence remains preserved separately from later passing runs.
The renderer's last readiness callback is followed by a final owner gate that checks current scope, original
and outstanding deadlines, and the armed route token without re-entering route observation. Replacement or
exact expiry at that final readiness boundary cannot authorize an old resume/unmute. Round6 source fails
the six-case final-readiness regression with nine issues; the corrected source preserves replacement advice.

## Concrete AirPods blocker and physical limits

The inspected public iOS port API exposes transport type, descriptive name, UID, channel/data-source and
spatial/voice-processing capabilities. None of the inspected properties establishes an AirPod-only output
identity or an atomic no-speaker-fallback binding. Bluetooth A2DP/HFP/LE describe transports, not a private
headphone product class. Spatial capability and microphone high-quality support are not output identity.
Therefore this adapter deliberately rejects AirPods/Bluetooth before capture startup; it does not use a
name match, transport heuristic, user-selected route or fixture as a private-route grant.

Apple documents that the system reroutes audio when devices are added/removed, then notifies observers.
The actor/thread fences here do not prove already-queued hardware samples cannot leak before notification.
Even the wired source classification remains a local software prerequisite, not physical fallback privacy
qualification. Do not enable a topology for real coaching until a supported no-fallback strategy and controlled
physical qualification exist. No live capture, playback, installation, signing, deployment or paid call was run.

Primary references: [port description](https://developer.apple.com/documentation/avfaudio/avaudiosessionportdescription),
[route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes).
The installed iOS SDK's `AVAudioSessionRoute.h` independently confirms those exposed attributes.

## Test expectations

`CoachingOutputMonitorTests` covers default-off, every output kind, mixed/anonymous ports, changed UID,
notification races during arming, immediate and off-actor fencing, and stale-event handling.
`CoachingEngineRendererTests` covers conversion/scheduling on an already-running owner, no restart on
stopped/unknown output, route loss while queuing and preflight of malformed/unbounded replacement queues.
`ApplePrivateCoachingTests` covers whole composition, nonzero unmasked synthetic capture during advice,
consent/Bluetooth rejection before capture, lifecycle/connection invalidation, generation fencing, expiry,
release and partial/startup failures. Tests never instantiate live hardware. Simulator compilation checks
the actual iOS initializer and platform constants; it does not establish physical behavior.
