# Device diagnostics (#234)

When the phone stops ambient listening or fails, the Mac usually sees only the stream end and a disconnect. Device diagnostics let the app report why, as a short structured event log the host stores and the user or the Mac-side AI can query.

## Privacy and safety

- No audio, no transcript or reply text, no request contents. Ever.
- Only enumerated event names and a fixed set of field keys. Each key has one value kind: a token from that field's closed vocabulary, a version number (one to four dot-separated groups of digits), a 32-bit integer, or a boolean. The log's readers include AI agents, so nothing a peer picks freely, not even a short phrase like `ignore_prior_rules`, can be stored.
- The decoder refuses anything else: an unknown event name, an unknown payload, event or field key, the wrong kind for a key, a token outside its field's vocabulary, a version that isn't digits and dots, an integer out of range, an empty batch, or more than 32 events in one batch. This is stricter than the rest of the protocol, which ignores unknown keys.
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

## Controls (planned in the next #234 slices; not shipped yet)

- **Host:** haild accepts and stores diagnostics only when started with `--device-diagnostics`. Without the flag it does not advertise the capability and writes nothing to disk. The log is owner-only (0600), capped at about 5 MB (one current file plus one rotated file), and rate-limited per session. `haild diagnostics tail [--device <name>] [--since <time>]`, `haild diagnostics show <session>` and `haild diagnostics clear` read and clear it.
- **App:** a "Diagnostics logging" toggle, off by default. While it is off the app records and sends nothing, and turning it off clears the app's buffer. While it is on the app keeps a bounded ring buffer, sends batches only to a host that advertises `device_diagnostics`, and says when the host isn't collecting.
