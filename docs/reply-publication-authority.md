# Reply publication authority prerequisite

Part of #167 and #161. This is a synchronization primitive and an in-memory
host-policy permit, not the completed reply routing or P1 fix.

Each `ReplyPublicationAuthority` owns an independent mutex and opaque revision.
`issuePermit` returns immutable evidence for that exact revision. A permit's
`performIfCurrent` accepts a synchronous, nonescaping operation. It either runs
the operation under the gate or returns nil without running it. Invalidation
rotates object identity; old permits can never become current again. A new gate
cannot affect an existing gate, and each host owns its own private gate.

The revocation linearization point is the synchronized revision replacement.
An operation already inside the gate finishes before invalidation returns.
After invalidation returns, an old permit cannot start another operation. This
orders overlapping publication and revocation; it cannot retract a frame that
was already committed. Operations must be short, synchronous and non-reentrant:
no `await`, waiting for a network completion, or re-entering/invalidating the same
gate. Composing independent gates requires one consistent lock order. Network
enqueue may be a synchronous future operation; waiting for delivery must happen
outside the gate.

`HailHost.replyPublicationPermit(for:)` checks exact policy binding, non-locked
tier, policy failure and lockdown in one actor turn without suspension before
issuance. Every central `revokeAuthority` call invalidates prior permits before
the completed mutation returns. Policy commit invalidates before adopting its
new in-memory policy; changed-policy refresh and observed reload/compile failure
also invalidate. Lockdown's synchronous transition invokes the same boundary.
Restoring a grant or recovering policy does not restore an earlier permit.
When a policy transaction fails before returning its committed view, the host
conservatively invalidates reply permits immediately, then reconciles the current
store with `refreshPolicy` before rethrowing the original transaction error.
Unknown transaction phases cannot prove continuous reply authority; even a
failed save of an unchanged policy retires old reply permits. Reconciliation of
unchanged valid policy still preserves existing generic confirmations and permits
issuing new reply authority. Observed invalid or changed policy uses the central
revocation path too. A bad-then-restored store cannot revive an earlier permit.

The grant reflects only this host's current in-memory policy. It is not a disk
refresh, provider/binding validity lease, terminal authentication, request owner
or capture grant. Existing send and capture behavior remains unchanged. No
listener uses these permits yet. Subsequent work must compose a cooperative
provider binding lease, request/selection/connection authority and final media
admission at the actual publication boundary. Generic tmux snapshots cannot
promise continuous validity of non-cooperative external process state.

Synthetic tests cover before/after revocation, exception cleanup, independent
gates/hosts, an already-running operation ordered before revocation completion,
deny/restore, tier changes, changed-policy reload, failed reload, invalid policy
compilation and lockdown. They use invented data only. No provider process,
device, host deployment, network speech or TestFlight action is performed. The
P1 and #161 remain open until integrated checks and physical proof succeed.

Initial prerequisite verification at `ee4b42a` with Xcode selected through
`DEVELOPER_DIR` (superseded by the failed-transaction correction below):

- `swift test --filter 'ReplyPublicationAuthorityTests|HostReplyPublicationAuthorityTests|HostPolicyTests|HostLockdownTests|PolicyCommitTests|PolicyConfirmationRevocationTests|ProviderContextDispatchTests' -Xswiftc -warnings-as-errors`: 42 tests in 7 suites passed.
- `swiftlint lint --strict --no-cache --quiet`: repository-wide uncached lint passed.
- `git diff --check`: passed. Exactly three production paths change, including
  the initial source version advance to 0.1.34. No full-suite, simulator or physical
  validation is claimed by this prerequisite record.

After the blocking independent-review finding about an exception from
`store.update` before its committed view is returned:

- `swift test --filter 'ReplyPublicationAuthorityTests|HostReplyPublicationAuthorityTests|ReplyPublicationPolicyFileTests|HostPolicyTests|HostLockdownTests|PolicyCommitTests|PolicyConfirmationRevocationTests|ProviderContextDispatchTests|PolicyFile' -Xswiftc -warnings-as-errors`: 66 tests in 11 suites passed.
- `swiftlint lint --strict --no-cache --quiet`: repository-wide uncached lint passed.
- `git diff --check`: passed. The same three production paths change; source
  version advances again to 0.1.35. Scratch-file tests include actual changed,
  malformed and wrong-permission policy, and deterministic save refusal. A
  separate regression proves unchanged failed saves preserve generic confirmed
  dispatch while retiring old reply permits. These are synthetic checks, not
  integrated publication or device proof. Independent re-review is still required.

The GitHub verify job for `60861714` subsequently failed the publication barrier
watchdog at 15 seconds. Both semaphore-held publication and mutex-blocked
revocation had been scheduled as `Task.detached` operations; this is consistent
with starving Swift's cooperative executor on the smaller concurrent CI runner.
The test now runs those deliberately blocking operations on `DispatchQueue.global`
with checked continuations. Its causal event-order assertions and 15-second
watchdog are unchanged; no production authority code changes. Source version
advances to 0.1.36. Fresh full verification and exact-head review are required.

An attempted restricted-pool diagnostic applied the environment to SwiftPM itself
and stalled before test startup; it is not test evidence. No restricted-pool
success or direct root-cause measurement is claimed. The isolated launcher and
its worktree are retained rather than bypassing process safety controls.

The corrected dispatch-worker source passed a fresh standard scratch-directory
warnings-as-errors run of the same focused suites: 66 tests in 11 suites.
Repository-wide strict uncached lint and `git diff --check` passed. The first
dispatch-worker compile flagged an implicit `Void` async-let warning; the explicit
annotation and a non-optional Boolean result also satisfy the existing lint rules.
No watchdog or production gate semantics were changed to obtain these results.
