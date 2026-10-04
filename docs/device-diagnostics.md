# Device diagnostics (#234)

When the phone stops ambient listening or fails, the Mac usually sees only the stream end and a disconnect. Device diagnostics let the app report why, as a short structured event log the host stores and the user or the Mac-side AI can query.

## Privacy and safety

- No audio, no transcript or reply text, no request contents. Ever.
- Only enumerated event names and a fixed set of field keys. Each key has one value kind: a token from that field's closed vocabulary, a version number (one to four dot-separated groups of digits), a 32-bit integer, or a boolean. The log's readers include AI agents, so nothing a peer picks freely, not even a short phrase like `ignore_prior_rules`, can be stored.
- The decoder refuses anything else: an unknown event name, an unknown payload, event or field key, the wrong kind for a key, a token outside its field's vocabulary, a version that isn't digits and dots, an integer out of range, an empty batch, or more than 32 events in one batch. This is stricter than the rest of the protocol, which ignores unknown keys. Every name, key, token and version is compared byte for byte on its UTF-8 form against ASCII, never as Swift Characters. Tag characters ("ASCII smuggling"), combining marks, zero-width joiners and fullwidth digits can't pass, even when they merge with a valid character into one grapheme.
- Diagnostics grant no authority and change no behaviour.

## Protocol (shipped in this slice)

A `control` frame with `"command": "diagnostic"` and an `events` array:

```json
{"command": "diagnostic", "events": [
  {"ts": 1758200049500, "name": "route_change", "fields": {"reason": "old_device_unavailable", "route": "built_in_mic"}}
]}
```

`ts` is milliseconds since 1970 on the device clock. `fields` may be omitted.

Event names: `app_info`, `connection_state`, `connection_error`, `ambient_start`, `ambient_stop`, `route_change`, `interruption_begin`, `interruption_end`, `app_background`, `app_foreground`, `host_refusal`, `capture_state`, `capture_error`, `reply_playback_start`, `reply_playback_end`, `reply_playback_error`, `echo_guard`, `events_dropped`.

Field keys: tokens `reason`, `state`, `code`, `domain`, `route`, `device`; versions `app`, `build`, `os`; integers `error`, `attempt`, `count`, `ms`; boolean `on`. Each token field's vocabulary is `DiagnosticVocabulary` in `Sources/HailProtocol/Control.swift` and the `enum` lists in the schema; each ends in `other`, which a device sends for anything it can't map exactly.

A client sends `diagnostic` frames only to a host whose hello lists the `device_diagnostics` capability. A host without that capability never receives one. Adding an event name or field later needs a new capability, because a strict host refuses unknown names. The protocol version stays 1.

Canonical fixture: `fixtures/frames/control-diagnostic.json`. Negative fixtures: `fixtures/invalid/control-diagnostic-*.json`.

## Host sink (shipped in the second slice)

haild accepts and stores diagnostics only when started with `--device-diagnostics`, which needs `--personal-terminal`:

```sh
haild run --bind <address> --port <port> --personal-terminal --device-diagnostics ...
```

- Without the flag, haild doesn't advertise `device_diagnostics`, refuses a `diagnostic` frame as unauthorized (the connection stays open), and writes nothing to disk.
- With it, events go to `diagnostics/diagnostics.jsonl` beside the policy file (`~/.config/hail/`, or `$HAIL_CONFIG_DIR`). Each line holds the host receive time, the connection's session id, a device token and the validated event. The token is `dev-` plus the first 8 hex digits of the SHA-256 of the hello's device name. It's stable per device, but the name itself is never stored.
- The directory is created 0700 and must be owned by you and closed to group and others. The file is opened without following links, must be a regular file you own, and is reset to 0600. Rotation refuses a rotated file that isn't a regular file.
- Writes retry interrupted and short writes. If a whole batch can't be written, the file is truncated back to where that append began, so no half-written line is left.
- Size: when a write would take the file past 2.5 MiB, it's renamed to `diagnostics.1.jsonl`, replacing the previous one. Two files at most, 5 MiB in all.
- Rate limits: each session gets a burst of 120 events, refilled at 2 per second. The host as a whole gets a burst of 300, refilled at 5 per second. Excess events are dropped without any reply. The next stored batch from that session starts with an `events_dropped` record (`count`, `code: host_rate_limit`).
- A storage failure drops the events and is counted; it never reaches the phone.

## Query and clear (shipped in the third slice)

```sh
haild diagnostics tail [--device <name>] [--since <90s|15m|2h|1d|ISO-8601>] [--limit <n>] [--json]
haild diagnostics show <session-id-or-prefix> [--json]
haild diagnostics clear
```

- `tail` prints the last 50 matching events by default, oldest first, across the rotated and current files. Each line has the host receive time (UTC), the first 8 characters of the session id, the device token, the event name, its fields as `key=value`, and the device's own time as `device_ts`, so clock skew is visible. For example:
  `2025-09-18T12:53:21.000Z 4F2A1C3B dev-1a2b3c4d route_change reason=old_device_unavailable route=built_in_mic device_ts=...`
- A value prints bare only when it's a plain token. Anything else, for example from a hand-edited file, prints as one double-quoted string of printable ASCII with `\uXXXX` escapes, at most 64 units. A value can't add a field, a line or unquoted text.
- `--device` takes a device token or a device name; a name is hashed to its token.
- `show` prints every event from one connection; a session id prefix of at least 4 characters is enough.
- `--json` prints the stored records, one per line, for tools. The output is printable ASCII only; any non-ASCII character becomes a `\uXXXX` escape.
- Readers skip any record whose device isn't a `dev-` token, and check tokens on UTF-8 bytes.
- `clear` removes both files through the same validated directory as the reads. It refuses a linked directory or one open to group or others. It's safe while haild runs, because each append reopens the file.
- Reading never creates a file and never follows a link. It refuses a directory open to group or others, and a file that isn't yours or is over 8 MiB. A line that no longer decodes under the strict rules is skipped.
- `--since` compares against host receive time.

## Controls (planned in the next #234 slice; not shipped yet)
- **App:** a "Diagnostics logging" toggle, off by default. While it is off the app records and sends nothing, and turning it off clears the app's buffer. While it is on the app keeps a bounded ring buffer, sends batches only to a host that advertises `device_diagnostics`, and says when the host isn't collecting.
