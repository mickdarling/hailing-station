# Connected proactive updates and task cadence candidate

This source candidate advances [#609](https://github.com/mickdarling/hailing-station/issues/609) and
[#1013](https://github.com/mickdarling/hailing-station/issues/1013). It is not installed, enabled or physically
qualified. Exact source review, executed checks and remaining gates belong in the issue-linked PR dossiers.

## Supported boundary

The connected path uses the existing explicit `--personal-terminal --session-updates` private-network boundary.
It does not add terminal authentication or TLS. The approved owner-key and APNs ladder in
`proactive-notifications.md` remains separate proposed work; no APNs network sender, enrollment, credentials or
push installation is supplied here. The queue alone, and a successful card send, are never hearing proof.

The host chooses the live ambient connection, otherwise the exact target's current last-input connection.
Capabilities, selection generation, current target policy, registry binding, global privacy, quiet and media
are checked before publication and again at enqueue. Cooperative provider binding leases remain leases;
legacy tmux binding validation remains a fresh listing snapshot, as in the existing requestless reply path.
An ambiguous, missing, incapable or unavailable recipient leaves the update held. No voice request is borrowed.

Cards enter the attributed session conversation once per host/update identity, with bounded receipts and history.
Enrolled progress/completion cards also carry their exact task identifier as unspoken metadata.
Private updates are dropped and held updates are purged. Privacy entry followed by exit cannot restore a delayed
report or prepared frame. Ordinary `info` waits for an interaction or playback-pause drain; explicitly enrolled
cadence reports can show their card without waiting for another owner request.

## Speech admission

Speech is a separate opt-in: `--session-update-speech-root <private-existing-absolute-directory>`. The existing
owned local house renderer supplies bounded PCM and joins child cleanup. No second synthesizer or local playback
is added. The host sends marked background/enqueue audio only to a peer advertising `session_update_audio`,
using the exact card UUID and retained publication admission. A completed card send does not prove playback.

The device accepts marked audio only against its original current connection/card receipt, while the same live
ambient capture is already authorized, public and outside media mode. It measures already-captured buffers;
it neither starts capture nor retains PCM for activity analysis. Speech waits for 600 ms of contiguous measured
low-energy samples with capture timestamps less than 150 ms old, an echo-cancelling route, and ordinary reply
arbitration. Missing/stale buffers never count as silence. This is a conservative activity measurement, not owner
recognition or physical proof that quiet speech will be detected.

New activity, stale capture or a retired policy cancels only proactive playback. Ordinary replies can pass a
deferred proactive item, and a proactive item cannot supersede paused ordinary audio. Pending proactive speech
expires after 30 seconds rather than catching up in a burst. Replay must satisfy the original unrenewed permit.
Quiet/global privacy retract already-transmitted proactive identities with a capability-gated exact cancellation;
that control never becomes generic `stop_playback` and leaves the card visible.
Marked progress audio also retains its own presentation identity, so it cannot complete the owner's pending
question even after its conversation card is evicted.

The host retains at most 128 cancellation identities rather than forgetting potentially buffered PCM. At capacity,
new speech is unavailable (`receipt_capacity`) until retraction clears room; cards still work. The device bounds
its pending proactive identities and audio independently. Physical routes, microphone activity, quiet speech,
cross-host audio and cancellation timing still need device qualification.

## Task enrollment and controls

Deadlines additionally require explicit `--task-progress`. These options prepare a possible configuration;
this implementation task does not change the live host, install anything, restart listening or install a build.

```sh
haild progress start <target-id> --every 300
haild progress status
haild progress interval <task-UUID> --every 600
haild progress owner <task-UUID> --command 'progress updates every 2 minutes'
haild progress report <task-UUID> --token <wake-UUID> --say '<confirmed progress>' --card '<optional detail>'
haild progress finish <task-UUID> --say '<completion>'
haild progress cancel <task-UUID>
```

An active enrollment cannot be replaced to evade owner settings. Agent interval changes cannot override a fixed
owner interval or clear an owner pause. Live enrolled owner voiceprints can use “updates more often”, “updates
less often”, “progress updates every N seconds/minutes”, “pause updates”, “resume updates” and “stop updates”.
They reach the same inspectable state; quoted, compound, synthetic, guest and unconfirmed-owner requests do not
silently become settings. Local socket controls remain owner-account cooperative controls, not process identity.

There is one enrolled task and at most one outstanding solicitation. A cancellation-aware host deadline wakes
the exact bound target through existing sanitizer/tier/lockdown/input admission. There are no idle LLM clock
polls or arbitrary scheduled shell commands. The status-only prompt carries a new task/wake token, never a
voice request reference. It grants no restart, interruption, recovery or authority renewal under #720/#1002.
An unchanged report releases its exact token without repeating the update. Completion/cancel ends the deadline;
an accepted slow solicitation stays outstanding rather than generating more prompts.

The original task check and policy generation travel together into the adapter's retained-authority check.
They are captured before dispatch suspension; a later actor hop never supplies fresh task permission.
Adapters with only `CheckedHandoffDelivering` keep that handoff-only boundary. This does not claim protection
for every later native paste/Enter operation or turn a legacy binding snapshot into a cooperative lease.

Privacy, quiet, media, disconnect and unavailable recipients pause host cadence. Playback activity also pauses
it; owner sound is ultimately enforced by the device's measured activity gate. Resumption schedules a full interval,
not missed ticks. The retained enrollment policy generation and binding survive neither revocation nor replacement;
queued reports carry that original authority through final output enqueue. Enrollment cannot initiate further
wakes after its six-hour bound. Existing six-updates-per-hour session limits are preserved, so a shorter requested
cadence can produce an explicit delivery refusal; it does not bypass notification limits.

`progress status` exposes task, session, interval, setter, pause reason, next due delay and outstanding state.
`notify status` distinguishes card counts from renderer availability, device attention gating and receipt capacity.
No status value establishes a physical spoken round trip.

## Verification boundaries

Injected clocks and synthetic transports cover deadline changes, precedence, coalescing, pause/cancel, stale
tokens, privacy epochs, policy retirement, exact recipients, capability negotiation, activity freshness and
proactive-only playback arbitration. CLI tests use an authored private Unix socket; speech tests use injected
synthetic renderers. These do not constitute APNs delivery, live provider/task feedback or physical hearing.
Authored guarded-adapter tests place a barrier before authority admission and retire the original task,
privacy, quiet or ambient boundary before releasing it; their execution results belong in the PR evidence.
Host builds, serial neighboring suites, repository verification and a simulator build remain distinct evidence
from physical-device qualification. Activation and any actual device delivery need a separately authorized step.
The new update, cadence and proactive playback families join the existing serial timing lane; no test is removed
and no deadline is widened.
