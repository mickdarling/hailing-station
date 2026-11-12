# Playback stream diagnostics, first slice (#1227)

This is host-local diagnostics groundwork, with no change to playback, sequencing,
queue admission, idle deadlines, or recovery. It does not identify or fix the cause
of the Mac reply truncation. Normal `reply_playback_end` records are unchanged.

An audio-stream `reply_playback_error code=stream_abandoned` keeps `ms=20000` and
adds these content-free fields, captured synchronously before retiring the stream:

| Field | Meaning |
| --- | --- |
| `last_sequence` | Sequence of the last accepted audio arrival, not necessarily the highest sequence. |
| `expected_sequence` | First sequence missing from the contiguous received prefix, starting at zero. |
| `gap` | A higher sequence was received beyond that missing sequence; this is a current gap, not historical. |
| `received_frames` | Unique accepted audio sequence numbers, including empty final markers. |
| `scheduled_frames` | Contiguous frames successfully handed to `ReplyAudioPlaying.schedule`, including markers. |
| `terminal` | An accepted audio frame had `isFinal`, even if a gap prevented scheduling it. |
| `last_frame_ms` | Monotonic elapsed milliseconds since this stream's last accepted audio arrival. |

These are transport audio-frame counts, not PCM sample counts or proof of audible
playback. The PCM16 path can retain scheduled audio while catching up; successful
scheduling does not prove a buffer played. Duplicate sequences do not inflate the
counts; accepted retransmissions refresh last-arrival sequence/time. Refused or
undecodable frames never enter these counters. Filled gaps stop reporting a gap.
Queued replies retain their own arrival time, rather than the time they became head.
Receipt bookkeeping retires with its stream, including stop and failure.

The shared first-audio-timeout hook still emits its legacy record without these
fields: no accepted audio exists for that reply, and another active reply's state
must not be attributed to it. Absence therefore means unavailable, not zero.

haild's decoder is strict about diagnostic field names and kinds. A diagnostics-enabled
host now advertises `device_diagnostics_playback_stream`. The device strips all seven
fields at send time unless that receiving host advertised it, including after reconnect
or when sending buffered events. The separate `device_diagnostics_stream_abandoned`
gate still replaces the code with `other` for hosts lacking that older capability.
Old devices continue sending the original optional-field shape; new hosts accept it.
Diagnostics collection remains opt-in. All new values are bounded 32-bit integers or
booleans; overflow saturates. No audio, text, endpoint identities, reply IDs, or request
IDs are added to the diagnostic event. The generated schema follows the same vocabulary.

## Verification and remaining proof

Swift Testing coverage uses `IdleRig`'s injected monotonic clock and scheduler for
gaps, missing terminal frames, completed/stalled playback, retransmissions, queue age,
receipt cleanup, and unrelated first-audio timeouts. Sending tests cover all combinations
of the old code gate and the new field gate. Protocol and daemon tests cover decoding
and storing both optional-field shapes, plus rejection of content in the new fields.

Build/test phases use the owner's host-slot and voice-quiet scripts in that order,
then background policy, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
Only package builds and selected serial suites are in scope. Validation results are
recorded with the local commit's implementation report.

Host results: package build passed; the final selected serial run passed 105 tests
in 17 suites. Schema validation passed 57 fixtures and rejected 126 negative cases.
Host SwiftLint passed all eight changed Swift files without warnings or errors.

Physical proof requires a Mac app build and an owner-approved installation/run.
No app build, installation, upload, live captured-output round trip, speaker/headphone
proof, or 30-reply acceptance run is claimed by this slice. Obtain the owner's OK
before that app-build/physical-validation work.
