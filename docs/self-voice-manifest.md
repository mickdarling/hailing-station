# Self-voice reference clips

The publisher prepares a local reference for RightyO to recognize synthesized replies as a non-person voice.
The feature is off until slice 2b wires the daemon switch and passes the absolute manifest path to the child.
The planned default is `~/.config/hail/self-voice/manifest.json`. The publisher takes an absolute directory
path with an existing parent and creates the final directory when needed.

Enroll only explicitly configured local reply profiles. Never enroll a reply profile cloned from the owner's
voice. RightyO would classify the owner's speech as self and discard it as evidence, defeating the feature.

As with every spoken reply, the renderer relies on the trusted local `vbsay` wrapper and Voicebox engine
to confine the synthesis request to the host. It uses a fixed environment,
sets the HTTP and HTTPS proxies to `127.0.0.1:0` with a loopback exception for the engine, and disables fallback and the
streaming daemon. It queries the profile catalog at the configured loopback origin. A process running under
a different UID with access to the unauthenticated loopback engine is outside this slice's threat model.

`vbsay` accepts a profile name and prefers an exact match. Before and after rendering, the renderer requires
exactly one exact-name match with the same profile ID. The launcher disables playback. Every clip uses
the same neutral English passage. Enrollment takes no microphone input or conversation text.

## Enrollment before child launch

The planned `--ambient-self-voice` switch takes the absolute path of an explicit UTF-8 JSON enrollment file.
Slice 2a provides the loader and preparation API. The daemon switch stays off until slice 2b connects them.
A disabled daemon constructs no preparer and performs no enrollment I/O.

```json
{
  "version": 1,
  "vbsay": "/opt/example/bin/vbsay",
  "voices": [
    {
      "id": "reply_a",
      "profile": "Synthetic reply",
      "source": "reply",
      "revision": "1",
      "endpoint": "http://127.0.0.1:1234"
    }
  ]
}
```

All keys shown are required. Unknown or duplicate keys are rejected. The file is at most 16 KiB.
Open it by descriptor without following symlinks, including in its ancestors. It must be a regular file
owned by the daemon UID, mode exactly 0600, with one hard link and no extended ACL. Its ancestors
follow the manifest directory rules below. The executable path must match its own `realpath(3)`
byte for byte. The executable must be regular and executable. It and every directory up to the
filesystem root must belong to the daemon UID or root and prohibit group and other writes.
The enrolled renderer spawns that absolute path directly.

Supply up to 16 unique IDs matching `[A-Za-z0-9_-]{1,64}`. Each profile is a nonempty name of at most
256 UTF-8 bytes without control characters or surrounding whitespace. Use a nonempty revision string
and change it when the voice changes. Only `reply` and origins exactly of the form
`http://127.0.0.1:<port>` are accepted, with a decimal port from 1 through 65535.
An empty array publishes an empty manifest and clears enrollment.

Before each planned startup or respawn, including a reload, the daemon will call `prepare()` off the
audio callback. Each call rereads enrollment, checks profile identity and verifies the manifest generation
and WAVs. An unchanged verified generation can be reused. Changed voices render again and removed IDs
drop out of the next manifest. A running child retains its startup enrollment.

Only a successful verification in this daemon run authorizes `--self-voice-manifest <absolute path>`.
The presence of an earlier manifest on disk never authorizes that argument. Read, validation, render,
publication and timeout failures record a content-free reason. Preparation returns no path and the child
launches without the argument.
The next preparation starts fresh. The whole attempt has one 20-second deadline, matching the announcer's
render deadline. At expiry preparation returns immediately and cancels its own work and render child.
Child reaping can finish in the background. A late render cannot authorize a publication.

## Published manifest

Manifest v1 has integer `version` 1 and a `voices` array. Each entry contains `id`, `file`, `source`
(`reply` for this publisher), `rendered_at` (Unix seconds), and `sha256` (lowercase hex over the final WAV).
The manifest fits in 16 KiB and holds up to 16 unique IDs matching `[A-Za-z0-9_-]{1,64}`. An empty array
clears the self profile. Each bare WAV name contains neither a slash nor `..`. Clips are RIFF/WAVE PCM,
16 kHz, mono, signed 16-bit little-endian, 8–20 seconds inclusive and at most 1 MB each.

The directory is 0700 and its regular files are 0600, all owned by the daemon UID and free of extended ACLs.
The publisher refuses symlinks. From the parent through the user's home or filesystem root, directories must
belong to the daemon UID or root. Group or other write requires the sticky bit, and ACL grants allowing
changes to directory entries are refused.

Under the directory lock, the publisher checks all entries before sweeping its own stale temporaries. It
installs new WAVs under unique names and syncs the directory before replacing the manifest. A failed attempt
removes its installed WAVs if the manifest rename has yet to occur. After replacement, the publisher retains
the WAVs named by both the new manifest and its predecessor. A child that already opened the previous
manifest can still open its WAVs until the next successful publication.

RightyO reads the manifest at child start. During a daemon run, a profile or revision change regenerates the
affected clip. Each regeneration sets `rendered_at` to `max(clock, previous + 1)`, seeded from the greater
of the manifest's modification time and its highest `rendered_at`. The modification time preserves the last
enrollment second even for an empty list. A same-UID restore of an older manifest combined with a clock
rollback can repeat a value. RightyO keys its embedding cache by `(id, rendered_at, sha256)`, so a repeated
ID and timestamp with the same digest refer to identical WAV bytes and the same embedding.

For the later playback contract, a closing `reply_window` uses `tail_ms` 0 when the tail cannot be measured.
