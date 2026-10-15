# Content-free coaching progress counts

Part of #524. After the owned local transcription child stop call returns, the native transport
emits one unified-log record under subsystem `com.mickdarling.Hail`, category `coaching-progress`.
The record is a post-stop-call snapshot: the bounded stop can return while supervisor cleanup continues,
and the stderr drainer is not joined by that call. It does not prove final totals or reaping.
It records existing actual written PCM byte/drop/stderr-byte counters, validated transcription-final
and received advice-event counts, and the number of converted input buffers that crossed the existing
1,000-amplitude activity threshold. No additional audio reads or changes to that threshold occur.

A speech-level buffer is amplitude evidence, not proof of speech recognition, speaker identity or a
useful cue. Advice events are received events, not proof of admission, rendering or audible playback.
Counts do not grant qualification, trigger a request or change hold/retirement/cleanup behavior.
Repeated/concurrent stop calls emit at most once; construction without a child emits nothing.
No audio, transcript, advice text, profile, endpoint, credential, device UID or child stderr is logged.
Physical signal/transcription/advice/playback qualification remains a bounded local test.

While coaching is Off, its Mac device inventory now refreshes every two seconds and stops polling when
the view disappears. Live selections are held during active/stopping sessions. This prevents a stale
headphone picker after Bluetooth device IDs change; it does not relax native output qualification.
