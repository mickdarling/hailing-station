# Self-voice reference clips

The publisher prepares a local reference for RightyO to recognize synthesized replies as a non-person voice.
The feature is off until slice 2 wires the daemon switch and passes the absolute manifest path to the child.
The planned default is `~/.config/hail/self-voice/manifest.json`. The publisher takes an absolute directory
path with an existing parent and creates the final directory when needed.

Only explicitly configured local reply profiles qualify. Voices run locally under the standing rule against
hosted TTS in the speaking path. The renderer checks for one exact profile name on the configured loopback
Voicebox engine before rendering and checks its profile ID again afterward. This relies on a trusted local
engine with a stable profile catalog during the render. The owned `vbsay` launcher disables stream-engine
selection and playback.
Every clip uses the same neutral English passage. Enrollment takes no microphone input or conversation text.

Manifest v1 has integer `version` 1 and a `voices` array. Each entry contains `id`, `file`, `source`
(`reply` for this publisher), `rendered_at` (Unix seconds), and `sha256` (lowercase hex over the final WAV).
The manifest fits in 16 KiB and holds up to 16 unique IDs matching `[A-Za-z0-9_-]{1,64}`. An empty array
clears the self profile. Each bare WAV name contains neither a slash nor `..`. Clips are RIFF/WAVE PCM,
16 kHz, mono, signed 16-bit little-endian, 8–20 seconds inclusive and at most 1 MB each.

The directory is 0700 and its regular files are 0600, all owned by the daemon UID. Publication checks
the directory and its entries for symlinks. An exclusive temporary holds each file before rename.
New WAVs get unique names. The publisher syncs them before replacing the manifest, then removes superseded
generation WAVs. RightyO reads the manifest at child start. During a daemon run, a profile or revision
change regenerates the affected clip. The manifest modification time retains the last enrollment second
even when the list is empty, so regeneration advances the timestamp across restarts and same-second updates.

For the later playback contract, a closing `reply_window` uses `tail_ms` 0 when the tail cannot be measured.
