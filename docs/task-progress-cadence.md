# Task progress cadence (#1013)

This candidate adds `TaskProgressState` and an event-driven `TaskProgressScheduler` in HailDaemonKit.
They are host groundwork, not an enabled watcher, device delivery, or physical hearing proof. Nothing in
this slice installs a service, changes host configuration, starts listening, renews a voice request, or
recovers a provider. #609 owns proactive delivery; #720 and #1002 retain their separate authority.

## State and deadlines

An owning host explicitly enrolls one `TaskProgressTask` with a fresh UUID, registry-derived session and
exact current adapter binding. One scheduler owns one enrollment. Replacement and finish retire its
old deadlines and update tokens. The scheduler creates no deadline until both a task and an eligible
recipient exist. Production sleeps on a single `ContinuousClock` deadline; changes cancel and replace
that sleep. No model polls the clock and no catch-up ticks are retained.

The default interval is five minutes, with a supported range of fifteen seconds to one hour. Agent
intervals apply until the owner sets an interval. Owner fixed intervals and more/less-often choices
then win. Pause and stop persist until an explicit owner resume; changing an agent interval cannot
clear either. Resuming waits a full interval. The snapshot exposes task, interval, setter, pause reason,
next due monotonic instant and outstanding token. A UI or CLI may convert the remaining monotonic
duration for presentation; it must not treat that conversion as a new deadline.

The host supplies privacy, quiet, media, owner speech, current playback, connectivity, listening and
recipient-uniqueness observations. Unknown recipient state starts paused. Every blocked deadline is
forgotten; resuming waits a full interval. An already-outstanding solicitation stays outstanding across
pause, so resume cannot prompt a busy session again.

At expiry, the callback receives the exact enrollment and a random single-use update token. The
callback has **no provider-input authority**. Host composition must check its original enrollment
policy generation, current exact adapter binding, task liveness and current audience at its existing
admitted commit boundary. It must neither replay/renew a voice request nor interrupt, restart or
recover the session. `permits` supports a policy recheck but does not substitute for that atomic host
admission. A failed/unavailable solicitation must complete its exact token if another attempt is
appropriate; an accepted solicitation remains outstanding until its report is accounted for. A stale
completion cannot release a replacement task's outstanding token.

Confirmed progress reports use #609 delivery, preserving session attribution. Repeated unchanged
reports should complete the token silently, rather than inventing progress or replaying speech.
Completion and blockers remain distinct from routine cadence. Finishing/canceling work must call
`finish(task:)`; loss of binding, task ownership or host authority must retire the enrollment.

## Controls

`TaskProgressOwnerControl` is the shared typed owner control surface. Its exact phrase parser accepts:

- `progress updates every 2 minutes` (integer seconds, minutes or hours within the supported range);
- `updates more often` / `updates less often` (also with a leading `progress`);
- `pause updates`, `resume updates` and `stop updates` (also `pause progress updates`, etc.).

Caller composition must establish owner attribution before applying parsed controls. Quoted commands,
compound requests, unrelated text, invalid intervals and overflow are refused by the parser. Parsing
alone does not wire a voice command or grant agent text owner authority.

## Synthetic verification

Authored suites: `TaskProgressStateTests`, `TaskProgressSchedulerTests` and
`TaskProgressVoiceControlTests`, with host-boundary cases in `TaskProgressGuardedWakeTests` and
`TaskProgressGuardedPolicyTests`. The state tests supply every time directly; the deadline-driver tests
inject a cancellation-aware clock and advance it programmatically, without wall-clock sleeps. They
cover deadlines, interval changes, explicit owner precedence, pause/resume/stop, every audience hold,
no catch-up burst, one outstanding update and stale completion versus replacement. Test execution is
recorded separately in the PR evidence. Host composition, actual device delivery and physical hearing
are separate gates and cannot be inferred from these tests.
