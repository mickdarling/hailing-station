# Voice guard configuration, runtime scope and live status (#1200)

Policy version 1 accepts an owner setting, `"voiceGuards": "on"` or
`"voiceGuards": "off"`. Absence defaults to `on`. Encoding omits `on` and writes
`off`; all other values, including null, are refused. Unknown keys and empty or
invalid guard lists remain errors. A malformed policy continues to refuse delivery.

This build enforces `off` only for requests from the host ambient pipeline. The
internal immutable delivery origin is captured from the host task-local in
`HailHost.sendAuthorized`. The listener's ambient dispatcher binds it, and retained
ambient requests restore it. Device names, text, routing, provenance and client
fields cannot set it. `haild send`, local dispatch, typed device input, replies and
task progress retain ordinary behavior.

Only guard-hit escalation is suppressed, including guard-scan timeouts. The existing
bounded scan still runs and retains its evidence. The confirm tier remains
unconditional. Lockdown, nonempty input, allowlist, exact binding, locked tier,
target/device rate limits, selection and generation checks, pending-input checks,
tmux dialog vetoes and final delivery admission (#1173) all remain active. A normal
policy reload restoring `on` takes effect before the next dispatch; input already
handed off cannot be recalled.

For each ambient request whose guard escalation was suppressed, the host writes
one JSON event to its local stderr log, aggregating evidence across line evaluations.
`rules` contains sorted, deduplicated matching rule names. A scan timeout adds
`"timeout":true` and sorted, deduplicated `timeoutRules`; a timed-out rule is not
claimed as a match. Names are JSON-escaped. There is no utterance, prompt, regex,
binding or device identity. Examples with invented names:

```json
{"event":"voice_guard_skipped","rules":["synthetic rule"]}
{"event":"voice_guard_skipped","rules":[],"timeout":true,"timeoutRules":["synthetic rule"]}
```

A clean scan, ordinary request, or confirmation required by the confirm tier emits
no skip event. A skip event records policy escalation suppression, even when a
later adapter or admission check refuses delivery; it is not proof of delivery.

Doctor, plain status and JSON status query the running daemon over the existing
owner-only local `replies.sock` Unix socket. The newline-terminated request is
`{"kind":"voice-guards","action":"status"}`. A successful response is
`{"delivered":0,"voiceGuards":{"value":"off","enforced":true}}`; the value is
`on`, `off` or `unusable`. It comes from one actor-isolated read of HailHost's in-memory policy and failure state; the
handler does not reload policy, access the status file, write an audit record or
acquire an admission lock. Editing the policy file alone does not change this reply.
An observed policy failure reports `unusable` rather than a retained or default value.

The request shares the existing socket's authentication: owner-only directory and
socket permissions, ownership and ancestor checks. It adds no listener or remote
protocol operation. The existing frame, connection, rate and deadline bounds apply.

Doctor displays the effective value and fails for an unusable effective policy,
unreachable socket, timeout, malformed reply or unrecognized response. It never
assumes `on` when the daemon cannot answer. Effective off is shown as
`voice guard holds are off for voice requests`. Older daemons reporting
`enforced:false` retain the `off (not enforced by this build)` wording.

Plain status retains the policy summary and allowed count, target count, adapter
listing failures and exit behavior, including exit 9 for an unusable policy file.
It adds `voice guards configured:` and `voice guards effective:` lines. Both doctor
and status show `policy file says X; running daemon uses Y; reload pending` when the
file and live values differ. An unusable file is identified separately. JSON status
keeps its exit behavior and reports the effective `voiceGuards` and
`voiceGuardsEnforced`, with `configuredVoiceGuards` for the file value. Unavailable
live values and enforcement are null; the health check fails.

`VoiceGuardsPolicyCodingTests` covers strict decoding, default omission, round trips,
reproducible encoding, guard validation and the unchanged version.
`LocalVoiceGuardsStatusTests` covers live on/off/unusable replies, unchanged memory
after file edits, reload recovery, read-only audit behavior, strict request shape and
shared socket permissions. Existing local endpoint tests cover unsafe ownership,
ancestors and ACLs. `VoiceGuardsDoctorStatusTests` and `VoiceGuardsTransportTests`
cover doctor and JSON, mismatch text, preserved plain status output and exit codes,
adapter failures, unreachable sockets, timeouts, malformed and unknown replies.
`VoiceGuardsAdmissionTests` and the real CLI send test pin unchanged ordinary-send
confirmation holds while configured off, and refusal after a malformed-setting reload.
`AmbientVoiceGuardsTests` exercises the child/consumer/dispatcher/session path with
synthetic input. `VoiceGuardsOriginIsolationTests` covers public send, local dispatch,
claimed client fields, typed input and real task wakes. `VoiceGuardsPreservedGatesTests`
covers confirm, locked, lockdown, binding, allowlist, rate limits, real tmux pending
input and dialog vetoes, and retired final admission. `VoiceGuardsLoggingTests`
covers escaped names, deduplication, clean scans and distinct timeout evidence.
`VoiceGuardsReloadTests` covers off-to-on reload before the next ambient dispatch.
These use synthetic inputs and targets; they do not establish physical-device behavior.

The runtime origin marker proves that a request came through the host's voice
pipeline, not that a human spoke. A device can supply synthetic audio.
