# Dedicated native Mac coaching microphone input

Part of #524. This slice adds a separately owned AUHAL input adapter. It is not yet wired into the
Mac composition; the integration and cleanup-fault UI are a separate required slice before live retry. The unit enables input on bus1, disables output on bus0 and reads both flags back while stopped.
Its internal fixed-device binding seam does not itself qualify a microphone or private output. The
integration must apply existing independent physical-microphone evidence, repeated exact HAL readback
and paired private-output checks before begin, and incorporate callback health into each observation.
The adapter never creates an input aggregate, changes defaults or automatically restarts.

The hardware input format supplies rate/channel count for an unprocessed Float32 client format.
Only explicit qualified begin calls AudioOutputUnitStart. Native callback frames are bounded to8,192
and at most250ms; each delivered snapshot owns a copy. The eight-buffer queue ends permanently on
overflow, bad extent, failed render or revocation. The integration must include its health in every
output-observation check so callback failure revokes qualification before queued buffers can forward.
Stop revokes delivery before native stop/uninitialize/dispose. The unit owns its callback context
before callback installation, including partial setup failures. Successful final disposal releases that
ownership. Failed disposal quarantines the native unit, driver and retired context until process exit,
sets observable cleanup state and refuses creation of another coaching input unit. It does not mark
the uncertain unit disposed or retry it. The integration must show incomplete cleanup rather than
claiming the microphone closed, deny Start and avoid implicit capture resume until app exit. No audio/transcript/renderer/endpoint data is logged.

The existing Mac input/output composition and iOS composition are unchanged in this foundation slice.
Native property-change callback crashes and aggregate remapping motivated this isolation; source and
synthetic/stopped tests do not prove physical live correction or an audible useful cue. System/conference
audio remains separate #525 work, with no new capture permission granted by this change.

Apple primary references:
- https://developer.apple.com/library/archive/technotes/tn2091/_index.html
- https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_enableio

MacCoachingHALInputDeliveryTests use authored injected pulls only, covering independent copied PCM,
bounded overflow, revocation during a pull, invalid frame extents and render error retirement.
MacCoachingHALInputLifetimeTests inject every native operation to cover teardown recovery, failed
disposal/context retention and safe late callbacks, failed preparation/initialization/start, constructor
failure, idempotent teardown and refusal of new input ownership after quarantine. No authored sentinel
handle reaches a real audio API.
