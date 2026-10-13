# Native Mac private coaching composition — inactive source

Part of #269, #268 and #225. This slice composes the independently reviewed fixed-output prerequisite with
the private-coaching core, wire consumer and renderer. No app, UI, daemon or automation constructs it.
It changes neither the installed apps nor ordinary ambient masking and reply playback.

The native initializer creates two exclusive engines. A local operator must eventually supply a private
output device and a separate room microphone; no remote request, name or Bluetooth transport selects or
qualifies them. Construction reads OS evidence and binds only these unstarted HAL units.
Unknown or shared input/output IDs fail before construction of live engines. Consent-confirmed
`begin` is the sole capture/start entry point. The output engine owns a dedicated player; the separate
input engine supplies plain microphone samples without ordinary reply masking or voice-processing/AEC.

Output authority requires every actual output stream to have the OS headphone terminal classification,
a live non-aggregate/non-virtual device with stable private UID, and observed fixed HAL device readback.
AirPods are conditional on that independent evidence, not on their product name or transport. Input authority
requires every actual input stream to have the OS microphone terminal classification; Bluetooth, headset
microphone, receiver, aggregate, virtual, anonymous and unknown input evidence is rejected. Both unit bindings
and original evidence are checked repeatedly; failure permanently retires the binding rather than rebinding
to a default device. No system-default device setting is written.

The owned startup sequence starts the fixed output engine, rechecks both bindings, then starts the separate
capture engine and rechecks again. Any partial startup failure stops both owned resources. Normal stop,
qualification/advice expiry, route invalidation and permission/consent loss retire capture and queued playback
and invoke the owner's provider/context clearing hook. Engine readiness and original-ticket deadlines remain
mandatory at renderer effects; this composition does not introduce another admission mechanism.

Core Audio device/stream property listeners retire the thread-safe route latch on their calling thread before
main-actor cleanup. Engine configuration, app-resign, workspace sleep/session-resign and default-output changes
also retire it. A default-output notification is conservative observation, not device selection. Old queued
cleanup cannot retire an explicitly re-armed newer lifetime. Partial listener installation and deinitialization
remove only the listeners owned by this monitor.

Synthetic composition tests exercise nonzero room capture during queued private output, loss with queued/late
advice, binding loss without notifications, startup errors, idle expiry, lifecycle loss, immediate explicit
restart and stale-event cleanup. Separate monitor tests cover partial listener installation and delayed cleanup
after release. These invoke authored operations only. Compilation checks the real Core Audio/AVAudioEngine
implementation; it does not prove driver behavior or output privacy.
Red-before boundary tests also reproduced initial/final input-binding observation gaps, nested observation
retirement, and startup cancellation that could admit capture or publish a stopped stream. Input binding now
fences final running/retired state; startup carries an owned revision checked after observations and before
capture/publication, and failed old startup cleanup cannot retire a successor. Ownership/effect assertions
remain unchanged; the final-readiness reporting assertion distinguishes the actual cleanup paths below.
If a property notification arrives at final renderer readiness, schedule/resume can report `playbackFailed`
before the queued route cleanup runs; mute's nonthrowing protocol reports `routeInvalidated` through the
adapter denial hook. Both retire the owned capture/queue and clear context before any denied effect.

## Still requires separately authorized physical qualification

No live microphone, playback, recording, device selection/activation, installation, signing, deployment or
paid call ran. The iOS adapter still deliberately rejects all Bluetooth/AirPods. Native Mac source support is
conditional on the actual driver's OS terminal evidence and fixed HAL readback; failure is a concrete unsupported
topology, not permission to use names or fallback. A prior content-free default metadata probe did not identify
AirPods and cannot establish how all AirPods drivers classify their terminals.

Future physical qualification must independently establish the actual AirPod terminal/binding, separate room
microphone continuity while private output plays, and route loss/speaker fallback with queued and late samples.
Software notification fences do not establish hardware-atomic silence or rule out samples already queued before
a loss notification. Do not activate real coaching until a separate scoped operator choice and controlled proof.
