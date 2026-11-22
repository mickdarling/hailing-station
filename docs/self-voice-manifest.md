# Self-voice reference clips

The publisher prepares a local reference for RightyO to recognize synthesized replies as a non-person voice.
Self-voice is off by default. The daemon publishes to `~/.config/hail/self-voice/manifest.json`.
The publisher takes an absolute directory path with an existing parent and creates the final directory when needed.

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

Pass `--ambient-self-voice <absolute enrollment path>` once to `haild run`. It requires
`--ambient-rightyo`, `--ambient-rightyo-config`, `--ambient-target`, `--personal-terminal` and
`--single-terminal-reply-fallback`. Omit the switch to keep ordinary child arguments and skip all
enrollment and manifest I/O. The enrollment file uses UTF-8 JSON.

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

An opted-in daemon starts one background preparation at utility priority. It reads enrollment, checks
profile identity, and publishes or verifies the manifest and WAVs. A kick during an existing attempt
coalesces with it. Each attempt has one 20-second deadline. Expiry revokes the attempt and cancels
its render child. Daemon shutdown also cancels preparation.

First starts, starts after a crash, device takeovers, and active-stream reloads all launch immediately
with respect to preparation. At argv assembly, haild checks the enrollment and manifest against the
last generation verified in this daemon run. It securely reads each file by descriptor with the 16 KiB
limit above on a dedicated utility queue. The spawn waits at most 250 ms for both reads together.
If an earlier verification is still running, the spawn falls back immediately. If the enrollment bytes
and the manifest SHA-256 both match, the final two arguments are `--self-voice-manifest <absolute path>`.
RightyO checks each WAV's SHA-256 against the manifest and skips any voice whose clip differs.

Otherwise the child starts with ordinary arguments and haild kicks background preparation. The daemon
queues a content-free log event such as `{"detail":"off for this child (pending)","event":"self-voice"}`.
During a sink stall, haild counts fallbacks by reason and writes one line per occurrence when the sink
recovers. Child launch and retirement diagnostics share the serial log queue with their own 16-slot limit.

- `pending` means preparation is pending or spawn-time verification was busy or exceeded 250 ms.
- With no verified generation after a failed preparation, the reason is `read`, `validation`, `render`,
  `publication`, `timeout`, or `cancelled`.
- `changed` means the enrollment bytes differ or the enrollment file failed its secure read.
- `mismatch` means the on-disk manifest digest differs or the manifest failed its secure read.

A running child keeps its startup enrollment. The next restart after successful preparation can use
the new manifest. A removal or revision edit withholds the old manifest immediately at the next
spawn. During preparation, reuse requires the configured name to resolve to the same profile ID
verified for that clip. A new ID under the same name triggers a fresh render.

The worker closes its stdout and stderr readers on cancellation even if a descendant holds the write
ends open. It joins both closes and reaps its own child in the background.

The worker checks the deadline and revocation before each WAV install and immediately before the
manifest rename, under the same lock the timeout uses to revoke the attempt. If expiry wins the
final check, the previous manifest stays byte-identical and the worker rolls back its new WAVs.
If the rename passed that check before expiry, it may finish after the caller has timed out. It
publishes a complete generation at the fixed `manifest.json` path. The worker installs and syncs
the WAVs first and renames the manifest last. A late rename never yields a path for the timed-out
call. The next `prepare()` rereads enrollment and verifies the on-disk manifest and WAV digests
before returning any path.

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

RightyO reads the manifest at child start. When preparation detects a profile or revision change, it regenerates the
affected clip. Each regeneration sets `rendered_at` to `max(clock, previous + 1)`, seeded from the greater
of the manifest's modification time and its highest `rendered_at`. The modification time preserves the last
enrollment second even for an empty list. A same-UID restore of an older manifest combined with a clock
rollback can repeat a value. RightyO keys its embedding cache by `(id, rendered_at, sha256)`, so a repeated
ID and timestamp with the same digest refer to identical WAV bytes and the same embedding.

For the later playback contract, a closing `reply_window` uses `tail_ms` 0 when the tail cannot be measured.
