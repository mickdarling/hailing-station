# Silent session-update settle (#1249, Design A)

Local implementation against `origin/main` at `3c6fb4ce62bf52921cd026918620e6357d4a204e`.
No host configuration, install, restart, app build/upload, network deployment or physical-device proof is included.

The existing held count is the daemon queue; the app appends permitted cards on receipt. No presentation delay
is added. Silent ordinary `info` cards gain an event-driven deadline per recipient connection. The queue's
natural-pause policy is reused under a separate settle lease; successful delivery logs `trigger=settle`.
Action delivery and the existing asked/interaction/reply-end triggers retain their existing behavior.

`sessionUpdateSettleMs`: default 8000 ms, inclusive bounds 2000...120000. The host.sh session-update reader validates
it and writes `HAIL_SESSION_UPDATE_SETTLE_MS` into the generated LaunchAgent environment. The listener reads that
scalar at construction, with 8000 as the fallback for absent/invalid direct environment values. No live setting
was read or edited for this implementation.

Signals restart the interval: finalized tap-to-talk text, ambient finalized live transcript classification
(the existing echo/privacy classifier also conservatively observes request/echo checks), pending input,
request-ledger mutation, host reply-flight mutation, admitted playback start/end/error and router mode changes.
The host has no continuous speech-activity signal. None is inferred or needed to display these silent cards.
A configured renderer suppresses settle delivery regardless of device speech capability.

The listener owns the timer dictionary; queue-empty and connection retirement cancel deadlines. An activity
revision and monotonic due time travel through actor hops to the synchronous final enqueue gate. Scheduling
checks pending input, reply flight and the current request ledger. Fire time repeats the ledger check; publication rechecks pending
input/playback and the activity revision, which every request/flight mutation invalidates. The settle lease is
passed explicitly with the card and cannot escape into unrelated tasks or cadence callbacks. A request's existing
correlation expiry gets one deadline plus the settle interval, without polling. Router privacy/media/meeting state, global
privacy epoch, quiet fence, selection, policy/binding authority and peer transport lifetime are rechecked.
Concurrent refreshes coalesce to one timer. Fired callbacks must match both revision and deadline; the cancelled
callback/new-queue interleaving with an unchanged activity revision is covered explicitly. Overlapping drains use
the existing single sender and acknowledge only successful exact-peer handoffs. A retired peer or a stale revision cannot enqueue. Privacy drops old output.

Enabled drain attempts emit only `session_update_drained` and `trigger=<asked|interaction|natural_pause|settle> count=N`.
Empty or blocked enabled attempts report `count=0`; counts include only completed exact-peer sends.
Completion is transport evidence, not visibility or hearing proof.

The initial corrected `swift build --build-tests` completed successfully in 1920.12 s at the required background
priority and two jobs. The dependent test-target rebuild exceeded the preferred 15-minute phase length.
The first serial settle run passed **20 tests in 3 suites** (including parameter cases) in 4.336 s.
`bash scripts/tests/test-host.sh` reported `test-host: OK`. Strict SwiftLint on all changed Swift files,
ShellCheck on both changed shell files, shell syntax and `git diff --check` passed.

The new suite families are `SessionUpdateSettleTests`, `SessionUpdateSettleGuardTests` and
`SessionUpdateSettleSignalTests`; their shared synthetic fixture is `SessionUpdateSettleTestSupport.swift`.
They cover automatic queue arming, all blockers, real router media/meeting transitions, admitted request
retirement, finalized ambient transcripts before attention/request, playback batch ordering, closure, configured
speech, immediate action cards, zero-count/actual-count content-free logs, batches, concurrent drains and
stale cancelled callbacks against a new queue with the same activity revision.

Every build/test phase uses the owner-provided `hostslot-wait.sh`, then `voice-quiet.sh`, and exports
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Commands run from the issue worktree:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
taskpolicy -b swift build --build-tests -j 2
taskpolicy -b swift test --no-parallel --skip-build --filter SessionUpdateSettle
bash scripts/tests/test-host.sh
shellcheck scripts/host.sh scripts/tests/test-host.sh
bash -n scripts/host.sh scripts/tests/test-host.sh
git diff --check
```

## Mutation and final restoration results

Each mutation changed production behavior in `WebSocketListener+SessionUpdate.swift`. Declaration positions were
preserved to keep the rebuild incremental. Each variant was built, then tested with the exact build and serial
`--filter SessionUpdateSettle` commands above, with separate host/quiet gates before build and test.
All mutation builds exited **0**; all mutation test runs exited **1** for real expectation failures:

| Mutation | Build seconds | Failing acceptance witness | Test result |
| --- | ---: | --- | --- |
| Remove settle dispatch | 54.34 | `silentInfoDrainsOnceAfterFullIntervalAndLogsOnlyCountAndTrigger`: 0 deliveries instead of 1 | 31 issues, 4.079 s |
| Drop reply-playing gates | 38.68 | `playingReplyBlocksAndEndStartsAFullInterval`: timer armed while playing | 4 issues, 4.027 s |
| Skip activity revision/timestamp re-arm | 36.88 | `activityDuringIntervalRearmsWithoutEarlyDelivery`: reply-end, final-turn and admission cases all retained the old deadline | 11 issues, 64.147 s |
| Ignore configured-renderer eligibility/publication checks | 32.41 | `configuredSpeechHasNoSettleAndExistingTriggersStillWork`: timer armed with configured speech | 5 issues, 4.144 s |

All four changes were restored. `cmp` confirmed the production file was byte-for-byte identical to the saved
passing source, before the final rebuild and again after regression tests. The restored build exited **0** in
**35.08 s**.

The final neighboring-family run exited **0**: **450 tests in 84 suites passed in 94.516 s**, including the new
settle tests. Eight intentionally injected timeout/cancellation assertions were recorded with `withKnownIssue`
in `RecipientPublicationGateTests` and `ReplyRecipientHandoffWaitTests`; those tests passed. There were no
unexpected failures. No failure was classified as pre-existing, and no A/B worktree run was needed. The new
fixture's actor-isolation compile error was corrected locally before these passing results.

Exact final regression and strict-lint commands:

```sh
taskpolicy -b swift test --no-parallel --skip-build --filter 'SessionUpdate|HostSession|Recipient|RequestLifetime|ReplyStop|VoiceStop|AmbientVoiceMedia|AmbientVoiceMeeting|AmbientMeetingControl|AmbientWiringReplyControl|RightyoInputConsumer|TaskProgress'
swiftlint lint --strict --quiet Sources/HailDaemonKit/Listener/HostSession.swift Sources/HailDaemonKit/Listener/WebSocketListener.swift Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift Tests/HailDaemonKitTests/SessionUpdateSettleTestSupport.swift Tests/HailDaemonKitTests/SessionUpdateSettleTests.swift Tests/HailDaemonKitTests/SessionUpdateSettleGuardTests.swift Tests/HailDaemonKitTests/SessionUpdateSettleSignalTests.swift
git diff --check
```

Final strict SwiftLint, restoration comparison and whitespace checks passed. These are host-local synthetic
results; no simulator, physical-device, installed-build or live captured-output round trip is claimed.

## Files and signal trace

Production count is **4**, using `scripts/pr-shape.py`'s exact prefix/suffix exclusions; there are no renames.

| Production file | Change |
| --- | --- |
| `Sources/HailDaemonKit/Listener/HostSession.swift` | Pending input, request/reply mutations and playback diagnostics feed the content-free activity fence |
| `Sources/HailDaemonKit/Listener/WebSocketListener.swift` | Queue/peer deadline ownership, ambient finalized-turn classifier, mode-change invalidation and lifecycle cancellation |
| `Sources/HailDaemonKit/Listener/WebSocketListener+SessionUpdate.swift` | Injectable one-shot deadline, explicit settle delivery lease, final enqueue guard and every-drain logging |
| `scripts/host.sh` | Bounded launch-time setting beside the existing session-update settings |

Tests: `Tests/HailDaemonKitTests/SessionUpdateSettleTests.swift`, `SessionUpdateSettleGuardTests.swift`,
`SessionUpdateSettleSignalTests.swift`, `SessionUpdateSettleTestSupport.swift`, and `scripts/tests/test-host.sh`.
Documentation: this record, `docs/host-operations.md`, `docs/proactive-task-candidate.md`,
`docs/proactive-notifications.md`, and `docs/design/settings-inventory.md`.

Signal locations (relative to `Sources/HailDaemonKit/Listener/`):

- Host reply flight mutation: `HostSession.swift:231`.
- Request admission/commit/completion/retirement mutation: `HostSession.swift:248`.
- Finalized tap-to-talk text: `HostSession.swift:306`; pending ingress spans `:349` and `:389`.
- Pending ambient dispatch: `WebSocketListener.swift:529`.
- Playback start/end/error: `HostSession.swift:481`, with ordered admitted batches applied at `:483`.
- Finalized ambient live transcripts: `WebSocketListener.swift:1544` and `:3287`; the existing echo/privacy
  classifier also conservatively observes request/echo classifications, without retaining their content.
- Media/meeting/privacy state mutations: `WebSocketListener.swift:841`, `:845`, `:854`, `:864`, `:869`.
- Each activity change updates a revision and monotonic timestamp: `WebSocketListener+SessionUpdate.swift:358`.

Setting read: `scripts/host.sh:195`; environment handoff: `scripts/host.sh:394`; listener construction:
`WebSocketListener.swift:125`; default/bounds parser: `WebSocketListener+SessionUpdate.swift:333`.
Deadline scheduling/fire: `WebSocketListener+SessionUpdate.swift:482` / `:515`; final activity/privacy handoff:
`:545`; logging: `:146`.
