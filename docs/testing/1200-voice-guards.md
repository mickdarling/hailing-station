# Voice guard configuration and live status (#1200, slices 1–2)

Policy version 1 accepts an owner setting, `"voiceGuards": "on"` or
`"voiceGuards": "off"`. Absence defaults to `on`. Encoding omits `on` and writes
`off`; all other values, including null, are refused. Unknown keys and empty or
invalid guard lists remain errors. A malformed policy continues to refuse delivery.

Configuration is separate from enforcement. `off` is **not enforced by this build**:
guard matches still require confirmation for ambient requests, `haild send` and every
other delivery path. Runtime skipping is deferred to slice 3.

Doctor, plain status and JSON status query the running daemon over the existing
owner-only local `replies.sock` Unix socket. The newline-terminated request is
`{"kind":"voice-guards","action":"status"}`. A successful response is
`{"delivered":0,"voiceGuards":{"value":"off","enforced":false}}`; the value is
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
`off (not enforced by this build)`; a future enforcing daemon reporting off is shown
as `voice guard holds are off for voice requests`.

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
`VoiceGuardsAdmissionTests` and the real CLI send test pin unchanged confirmation
holds while configured off, and refusal after a malformed-setting reload.
These use synthetic inputs and targets; they do not establish physical-device behavior.

The future runtime origin marker proves that a request came through the host's
voice pipeline, not that a human spoke. A device can supply synthetic audio.
