# Dedicated native Mac coaching microphone input

Part of #524. The Mac composition uses a separately owned AUHAL input unit instead of an
AVAudioEngine input graph. The unit enables input on bus1, disables output on bus0, reads both flags
back while stopped, and accepts only the selected independently qualified physical microphone ID.
It retains the existing repeated exact HAL readback/physical metadata checks and paired private-output
binding. It never creates an input aggregate, changes defaults, accepts an aggregate alias or restarts.

The hardware input format supplies rate/channel count for an unprocessed Float32 client format.
Only explicit qualified begin calls AudioOutputUnitStart. Native callback frames are bounded to8,192
and at most250ms; each delivered snapshot owns a copy. The eight-buffer queue ends permanently on
overflow, bad extent, failed render or revocation. Its health participates in every output-observation
check, so queued buffers cannot continue granting a live coaching route after callback failure.
Stop revokes delivery before AudioOutputUnitStop; disposal stops, uninitializes and disposes the owned
unit while its callback context remains retained. No audio/transcript/renderer/endpoint data is logged.

The output renderer remains its own fixed private-headphone engine. iOS composition is unchanged.
Native property-change callback crashes and aggregate remapping motivated this isolation; source and
synthetic/stopped tests do not prove physical live correction or an audible useful cue. System/conference
audio remains separate #525 work, with no new capture permission granted by this change.

Apple primary references:
- https://developer.apple.com/library/archive/technotes/tn2091/_index.html
- https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_enableio

MacCoachingHALInputDeliveryTests use authored injected pulls only, covering independent copied PCM,
bounded overflow, revocation during a pull, invalid frame extents and render error retirement.
