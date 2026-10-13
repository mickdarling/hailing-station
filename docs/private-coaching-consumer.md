# Private coaching wire consumer — local stacked slice

Part of #269, #268 and #225. This follows the unactivated [qualification core](private-coaching-route.md).
It adds no UI, daemon flag, transport, platform output classifier, renderer, deployment or capture activation.
It does not change ordinary playback or grant action/tool authority.

## Admission and bounds

`CoachingAdviceConsumer` accepts ASCII JSON advice only through `CoachingWireAdvice.decode`. The exact v1
schema rejects unsupported versions, unknown or duplicate keys (including escaped duplicate keys), incorrect
types, noncanonical UUIDs, nonfinite confidence, controls and non-private delivery. The line is at most
8,192 bytes; listener/provider/model identifiers are 1–96 bounded ASCII characters. Printable nonempty text
is at most 280 Unicode scalars and 45 whitespace-delimited words. Advice is suggestion data, not a command.

The trusted application calls `register` only with the exact current host-issued qualification returned by
`begin` or `renew`. No received wire message creates a qualification. A bounded ledger retains up to 16
unexpired original qualifications. Advice must echo their complete session/generation/destination tuple
and the selected listener. Producer-issued request UUIDs are admitted once per generation, with a limit
of 128. Expiry does not erase replay protection; ledger exhaustion stops the whole owned lifetime rather
than evicting protection. A new actual begin permits a fresh generation.

The receipt TTL (integer 1–2,000 ms) can shorten, never extend, the original host observation deadline.
Renewal preserves old qualification deadlines. Each asynchronous renderer must return through this
consumer's `schedule`, `resume` and `setMuted` gates with its immutable admission result. These check the
consumer identity, original issued lease, deadline and current core qualification/output at consumption.
Route/session/connection loss must call `invalidate` or `stop`; owners must also cancel provider/render
work and clear their plaintext context from the core suspension hook. The consumer stores correlations,
not a transcript archive, but external immutable advice strings are not forensic zeroization.

## Synthetic qualification

`CoachingWireAdviceTests`, `CoachingAdviceConsumerTests` and `CoachingConsumerResourceTests` cover strict
decode, wrong scope, original expiry across renewal, duplicate requests, ledger limits, route vetoes and
delayed playback. The five-line authored fixture in `fixtures/coaching-wire-v1.jsonl` is not execution proof.

`CoachingProducerReplayTests` is an explicit optional cross-repository probe. Set
`HAIL_COACHING_REPLAY_JSONL` to output from RightyO's actual `coach-replay` executable, then run
`swift test -Xswiftc -warnings-as-errors --filter CoachingProducerReplay`. It uses those unmodified advice
bytes and producer-issued request ID; only its test host installs the known authored qualification IDs.
No production initializer accepts that ledger shortcut. It checks private synthetic scheduling, duplicate,
state/control rejection, changed destination, invalidation and original expiry across renewal. Without
the environment variable those two probes are skipped; ordinary tests do not depend on another checkout.

All audio and routes here are fakes. Source admission cannot prove physical AirPods privacy, acoustic AEC,
or that the OS cannot reroute already-queued Bluetooth samples before a callback. The platform classifier,
non-rerouting renderer, route/lifecycle wiring, trusted control channel and controlled physical matrix
remain separate requirements. Default off, unmerged, not deployed; no live or paid-provider proof is claimed.
