# Generic USB microphone terminal compatibility — source only

Part of #269, #268 and #225. The native Mac input checker accepts Apple's `micr` terminal and, only on
an independently observed USB device, the standard USB Audio generic microphone terminal `0x0201`.
The [USB Audio Terminal Types specification](https://www.usb.org/sites/default/files/termt10.pdf), table 2-2,
defines that code as a microphone. Apple's public terminal constants cover only some terminal values.
No product name, selected default input, transport alone or user-provided device label grants authority.

Every actual input stream must still have input direction and one of these exact generic microphone
classifications. Unknown, personal/headset/receiver/array/line/output terminal codes remain refused.
Bluetooth/LE, aggregate, virtual, dead, anonymous, malformed, duplicate and oversized evidence remains
refused. The numeric USB code is not accepted for any non-USB transport. Private-output classification
is unchanged, as are fixed HAL readback, binding retirement, original deadlines and owned cleanup.

Authored tests cover both classifications, multiple streams, mixed non-generic types, every retained
guard and permanent binding retirement after a terminal becomes unsupported. The old source fails
the new USB-positive and retirement cases; that red evidence is preserved outside the repository.
Tests never open devices or start native audio. This correction alone does not establish microphone
continuity, physical privacy, echo cancellation, live provider readiness or hardware-atomic fallback safety.
