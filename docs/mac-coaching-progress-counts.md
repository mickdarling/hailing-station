# Content-free coaching progress counts

Part of #524. After the owned local transcription child has stopped and joined, the native transport
emits one unified-log record under subsystem `com.mickdarling.Hail`, category `coaching-progress`.
It records existing actual written PCM byte/drop/stderr-byte counters, validated transcription-final
and received advice-event counts, and the number of converted input buffers that crossed the existing
1,000-amplitude activity threshold. No additional audio reads or changes to that threshold occur.

A speech-level buffer is amplitude evidence, not proof of speech recognition, speaker identity or a
useful cue. Advice events are received events, not proof of admission, rendering or audible playback.
Counts do not grant qualification, trigger a request or change hold/retirement/cleanup behavior.
Repeated/concurrent stop calls emit at most once; construction without a child emits nothing.
No audio, transcript, advice text, profile, endpoint, credential, device UID or child stderr is logged.
Physical signal/transcription/advice/playback qualification remains a bounded local test.
