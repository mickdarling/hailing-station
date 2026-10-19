# Native Mac private-output prerequisite — inactive, not a completed AirPods path

Part of #269, #268 and #225. This is separate source groundwork after the iOS wired adapter. HailCore
already targets macOS15; it can inspect native Core Audio metadata instead of relying on AVAudioSession.

`MacCoachingDeviceEvidence` reads the selected local device's alive flag, class, transport, private UID and
all output streams. Every stream must report the public OS headphone terminal type and output direction.
Unknown, missing, duplicate, empty, oversized, mixed/non-headphone, aggregate and virtual evidence is denied.
Bluetooth alone never qualifies; a Bluetooth device can qualify only with independent headphone terminal
metadata. No device name/product match is used, and the private UID is transient correlation, never logged.
This establishes a headphone class, not an AirPods-specific product identity or actual device qualification.

`MacCoachingBindingOperations.live` uses the actual output node's audio unit. It requires AUHAL, rejecting
default/system-output units. `MacCoachingOutputBinding` sets `kAudioOutputUnitProperty_CurrentDevice` once
on an exclusive unstarted output-only engine, then verifies actual readback plus unchanged device metadata.
Subsequent checks never choose the default device, rebind, restart or revive. A lost binding, changed UID,
or changed stream evidence retires the binding. No system-global default-device property is written.

These components do not start an engine, microphone or playback and do not issue a coaching qualification.
They are not yet assembled into a native Mac room-microphone/private-renderer lifetime or app/daemon path.
That next slice needs route-property/engine/lifecycle invalidation and ticket-aware effect fences before
capture admission and rendering. A selected/requested device and setter success alone must never grant it.

The inspected public APIs provide a feasible conditional native headphone classification and device-binding
path, not proof that a specific AirPods driver reports headphone terminal metadata, nor a hardware-atomic
no-speaker-fallback guarantee. The content-free read-only current-default metadata probe did not report a
headphone terminal. It did not identify that device as AirPods; that result says nothing about every AirPods
driver. iOS remains deliberately Bluetooth/AirPods-unsupported because its inspected port API lacks that
independent output terminal classification and fixed-device binding. No device selection or live IO occurred.

Primary references: [headphone terminal type](https://developer.apple.com/documentation/coreaudio/kaudiostreamterminaltypeheadphones),
[current-device property](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice).
Installed macOS SDK AudioHardwareBase.h and AudioUnitProperties.h document the same APIs.

`MacCoachingOutputEvidenceTests` uses authored property/binding operations, not real device identities or
audio streams. It covers transport-only denial, malformed/unknown/mixed classification, binding readback,
running-owner refusal, UID replacement, changes during observation, retirement and no revival/rebind.
Round 1 independent review found same-call retirement and unstarted-owner observation gaps. Authored
regressions reproduced both before correction. The binding now rechecks retirement after its final device
observation, refuses a device write when metadata reading starts the owner, and refuses successful
publication when the final binding observation starts it. Tests cover retirement at each of the three
observation boundaries and startup during initial metadata, final metadata and final device readback.
Physical acceptance remains deferred: operator-selected AirPods metadata on the intended Mac, room mic
continuity during private advice, route loss/default-output changes, and queued/late advice under unplug,
sleep, interruption and reconnect. Those checks require separate scoped live authorization; none ran here.
