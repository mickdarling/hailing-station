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

Prerequisite verification with Xcode selected through `DEVELOPER_DIR`:

- `swift test --filter 'ReplyPublicationAuthorityTests|HostReplyPublicationAuthorityTests|HostPolicyTests|HostLockdownTests|PolicyCommitTests|PolicyConfirmationRevocationTests|ProviderContextDispatchTests' -Xswiftc -warnings-as-errors`: 42 tests in 7 suites passed.
- `swiftlint lint --strict --no-cache --quiet`: repository-wide uncached lint passed.
- `git diff --check`: passed. Exactly three production paths change, including
  the source version advance to 0.1.34. No full-suite, simulator or physical
  validation is claimed by this prerequisite record.
