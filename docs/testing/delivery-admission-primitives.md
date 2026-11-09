# Operation-bearing delivery admission

Part of #1120.

`DeliveryAuthority` exposes an explicit operation-bearing delivery admission capability. A check-only
authority reports no support and throws `DeliveryAdmissionError.unsupported` without invoking the
operation. `CheckedHandoffDelivering` retains its explicit handoff-only contract.

`DeliveryAdmission` composes retained gates in this fixed order, skipping absent stages:

1. Target policy.
2. Task output fence.
3. Reply permit.
4. Binding lease.
5. Session-update fence.
6. Ambient router.
7. Privacy hold.
8. Peer lifecycle.
9. Attempt/cancellation decision.
10. Operation.

Each stage appears at most once. The task stage must use the retained policy generation without
reacquiring the target-policy gate. Gate providers must hold their authority through their synchronous,
nonescaping continuation. Operations must remain short and must not suspend, wait for completion,
retire authority or reacquire any held gate.

Admission is ordered against retirement: after retirement completes, no later operation is admitted;
an operation admitted before retirement may complete. Return values, including optional values, and
thrown operation results pass through admission. A missing or repeated gate continuation is refused.

Preliminary validation uses separate read-only closures and commits neither cancellation nor attempts.
Admission does not use a cached validation result. Existing check-only authority preserves its handoff
semantics. No production consumer adopts operation-bearing delivery admission in this change, so live
behavior is unchanged.

The production scope is two files: `Adapter.swift` and the new `DeliveryAdmission.swift`.
`DeliveryAdmissionTests.swift` covers each stage's retirement ordering with deterministic barriers,
refusal after retirement, exactly-once invocation, return values, thrown results, fixed stage order,
absent stages, separate validation and invalid continuations. `DeliveryAuthorityAdapterTests.swift`
adds unsupported-admission and explicit handoff compatibility checks. Existing handoff tests are unchanged.
Blocking test operations use dedicated executors; no test uses sleeps.

## Verification

A fresh GitHub clone on the Dev Work VM receives the local stack using a git bundle created
with `origin/main..HEAD`. Each run waits for the shared VM lane in a remote script
whose process arguments contain only its filename, then builds and runs the targeted filter:

Each run waited for the shared VM lane to be idle.

The VM verification wrapper built the package and tests, then ran the filtered tests: `'HailDaemonKitTests\.(DeliveryAdmission|DeliveryAuthority|FinalDelivery|Tmux|LocalDispatch|HailHost)'`.

SSH stdin is closed with `< /dev/null`; execution remains blocking.

Verification ran on the pre-rebase stack. The run on source/test snapshot `3e4a2a7854a9d78a81c228d665c981152e3efd9d` passed with
`build=0`, `test=0`: **211 tests in 40 suites**, in **65.955 seconds**. The five expected known issues
belong to the existing `LocalDispatchPreflightWaitTests`; there were no unexpected issues.
`DeliveryAdmissionTests` passed all seven tests, including 24 cases across ordinary and parameterized
tests. `DeliveryAuthorityAdapterTests` also passed. The final follow-up changes this record and a
documentation comment only; executable source and tests match the verified snapshot.

Build and test logs were retained on the VM.
The build emitted existing missing module-cache debug-info warnings; this is Command Line Tools VM
iteration evidence.

Host lint uses this command separately for each of the four changed Swift files:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

Final host lint passed with zero violations for `Adapter.swift`, `DeliveryAdmission.swift`,
`DeliveryAdmissionTests.swift` and `DeliveryAuthorityAdapterTests.swift`. `git diff --check` and its
staged equivalent passed.

This record covers synthetic VM package verification and host lint only. It does not establish simulator,
physical-device or live captured-output behavior. No host build or test, GitHub API call, push, install,
upload, daemon or configuration change is part of this work.
