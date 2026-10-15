# Content-free native coaching route trace

Part of #524. The native fixed-device bindings and route monitor emit a small unified-log diagnostic
under subsystem `com.mickdarling.Hail`, category `coaching-route`. Messages contain fixed labels and, for HAL input readback mismatch only, the already-observed ephemeral numeric device IDs:
input/output set-device refusal, first binding mismatch/physical input-evidence change, or the first armed device-property,
audio-engine-configuration, workspace-sleep or workspace-inactive event. No error descriptions, device
names/UIDs, profile data, endpoints, transcripts, PCM, advice or credentials are included.

The first binding mismatch still retires permanently; subsequent reads do not repeat its log. Route
events are recorded only when the latch was armed, after synchronous retirement and before queued cleanup.
No extra hardware observation or authority check is introduced. The small unchanged output-engine lifetime
helper moves beside the output binding to keep the input owner's file within the review-size limit.

Existing native binding/monitor/composition/lifecycle tests exercise the unchanged boundaries. Logs diagnose
an observed software event; they do not establish physical causation or permit capture, fallback, rebinding,
permission changes or playback. Physical startup remains a separately bounded local test under #524.

The input-unit adapter now lives beside the output-unit adapter. This is the same stopped HAL binding and the same sequence of reads; mismatched readback logs the requested and observed numeric IDs without re-querying hardware. The broader input binding message correctly includes failure of its paired output check.
