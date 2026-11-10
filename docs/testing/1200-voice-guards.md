# Voice guard configuration (#1200, slice 1)

Policy version 1 accepts an owner setting, `"voiceGuards": "on"` or
`"voiceGuards": "off"`. Absence defaults to `on`. Encoding omits `on` and writes
`off`; all other values, including null, are refused. Unknown keys and empty or
invalid guard lists remain errors. A malformed policy continues to refuse delivery.

This slice stores and displays configuration only. `off` is **not enforced by this
build**: guard matches still require confirmation for ambient requests, `haild send`
and every other delivery path. Doctor warns when configured off; plain status and
JSON status expose the configured value. Unreadable or malformed policy fails doctor,
and JSON reports an unknown setting as null. The JSON enforcement flag is false.
The runtime change is deferred to slice 2.

The future runtime origin marker proves that a request came through the host's
voice pipeline, not that a human spoke. A device can supply synthetic audio.

`VoiceGuardsPolicyCodingTests` covers strict decoding, default omission, round trips,
reproducible encoding, guard validation and the unchanged version.
`VoiceGuardsDoctorStatusTests` covers doctor, JSON, plain status, unusable policy and
real CLI confirmation refusal. `VoiceGuardsAdmissionTests` pins unchanged guard
escalation for an ambient-shaped authorized request and an ordinary send, and
refusal after a malformed-setting reload. These use synthetic inputs and targets;
they do not establish physical-device behavior.
