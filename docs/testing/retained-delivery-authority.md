# Retained delivery authority

Part of #1120.

The host composes retained delivery authority in the admission stage order. HailHost supplies the
single target-policy gate. Session delivery contributes the original reply permit, binding lease,
peer permit and request clock. Task delivery contributes its original output fence, session-update
fence, ambient audience, privacy revision, peer permit and attempt decision. The task generation must
match the host generation; the task stage uses `TaskProgressOutputFence.perform`, without calling
`TaskProgressPublicationAuthority.perform` or reacquiring target policy.

The task wake caller explicitly binds the retained stages before host dispatch. Relative to the
prerequisite delivery, the production delta is four files: `HailHost.swift`, `HostSession+Routing.swift`, `TaskProgressAuthority.swift` and
`ListenerTaskProgress.swift`. Original authority survives registry and adapter suspension and cannot
be replaced by a later TaskLocal binding.

Existing adapter consumers receive a committing check-only view backed by `admit {}`. This includes
the default checked handoff, contextual handoffs and tmux checks. Their `requireCurrent` calls still
record task attempts; operation-bearing preliminary validation commits neither attempt nor
cancellation. Checked handoff retains its declared in-flight semantics. Guarded per-side-effect
consumers retain their checks at each side effect. The check-only path takes short locks and performs
no policy I/O. This change does not move the tmux launch boundary.

`DeliveryAuthority.admit` may throw after its operation ran: a gate may throw after its continuation,
or a repeated continuation may be refused after one invocation. An error does not prove zero
execution. Callers must rely on the attempt/cancellation record and must not infer safe retry from
an admission error. The API documentation in `Adapter.swift`, including its per-side-effect and
lock-only check-only contract sentences, is deferred to the next delivery to stay within four
production files.

Post-handoff ownership and last-input attribution require the original peer permit. The commit orders
reply permit, binding lease, then peer lifecycle; it checks the original request clock inside those
gates. Peer retirement before completion prevents both commits, even before session cleanup runs.
Local dispatch preserves the peer wrapper's existing `connectionLost` result after a completed adapter
handoff. An ownerless internal handoff marker commits neither ownership nor last-input attribution;
the retired peer refuses it before returning to the caller.

## Synthetic coverage

`DeliveryAdmissionCompositionTests` covers independently retired policy, permit, lease and peer,
exact request expiry, clock rollback, TaskLocal replacement, generation identity, read-only validation
and composition of the real policy lock with the task fence. `FinalDeliveryAuthorityTests` adds
barriers after handoff and before completion for contextual and legacy ownership. The pending
session record is present when only peer authority retires; neither ownership nor last-input
attribution commits afterward. `TaskProgressHandoffTests` adds checked-handoff attempt accounting.
Existing test cases remain unchanged. The new concurrency tests use injected barriers and clocks,
without sleeps.

| Invariant | Synthetic evidence |
| --- | --- |
| Independent policy, permit, lease and peer retirement | `retainedStagesRefuseIndependentRetirement`, existing final delivery tests |
| Exact expiry and backwards request clock | `retainedStagesRefuseIndependentRetirement`, existing final reply/legacy tests |
| Retained stages survive TaskLocal replacement | `retainedStagesSurviveTaskLocalReplacement` |
| One target-policy acquisition and matching generation | `taskContributionUsesTheHostsSinglePolicyGate`, `aDifferentRetainedGenerationCannotCompose` |
| Peer retirement before completion commits no ownership or last-input | `peerRetirementBeforeCompletionCommitsNoOwnership` |
| Checked handoff records its attempt before cancellation | `checkedHandoffRecordsTheComposedTaskAttempt` |

The earlier primitive retirement-ordering test now documents that its invocation event marks the
call site rather than proof that the retirement thread reached a blocked lock. Its executable body
is unchanged. The earlier verification record explicitly identifies its pre-rebase stack.

## Verification

The Dev Work VM workspace is a fresh clone at `~/codex-workspaces/vwf2`, synchronized with a local
bundle of `origin/main..HEAD`, including the prerequisite delivery. Verification uses Apple Swift
6.3.3 on arm64 macOS. Each run waits for the shared lane in a remote script:

```sh
while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done
WS=vwf2 ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(DeliveryAdmission|DeliveryAuthority|FinalDelivery|TaskProgress|Held|LocalDispatch|HailHost|Host|Ambient|Tmux|Reply)'
python3 -m unittest discover -s Tests/ReplyCLITests
~/codex-workspaces/vw-werr.sh vwf2
```

SSH stdin is closed with `< /dev/null`; each command completes before the next begins.

The verified source/test snapshot is `bf95a5c13efa0263cddae665f2051c632852964e`, locally stacked on
`b5923e5bb69550a6c35ad107e26e12ca73dc2412`; this evidence precedes the later integration rebase.
A focused follow-up passed **26 tests in 5 suites** in **0.299 seconds** with `build=0`, `test=0`:

```sh
WS=vwf2 ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(DeliveryAdmissionComposition|FinalDelivery|LocalDispatchLifecycle|TaskProgressHandoff)'
```

The full requested Swift filter then passed with `build=0`, `test=0`: **1,089 tests in 225 suites**
in **658.766 seconds**. Its ten expected known issues are the five each in
`LocalDispatchPreflightWaitTests` and `ReplyRecipientHandoffWaitTests`; there were no unexpected
issues. Existing test expectations remain unchanged. The follow-up preserves the established local
connection-loss result while refusing ownership and last-input commit after peer retirement.

Reply CLI verification passed: **124 tests in 215.572 seconds**, exit 0. The warnings-as-errors
command finished with **`werr build=0`, exit 0**. Existing missing module-cache debug-info warnings
were emitted; this is Command Line Tools VM iteration evidence.

Saved VM logs are `~/codex-workspaces/vwf2-focused-build.log`,
`~/codex-workspaces/vwf2-focused-test.log`, `~/codex-workspaces/vwf2-build.log` and
`~/codex-workspaces/vwf2-test.log`. Reply CLI output is retained in
`~/codex-workspaces/vwf2-cli.log`; warnings-as-errors output is retained in
`~/codex-workspaces/vwf2-werr.log` and `~/codex-workspaces/vwf2-werr-result.log`.
The final follow-up updates this record only; executable source and tests match the verified snapshot.

Strict host lint passed with zero violations on all ten changed Swift files: the four production
files, `DeliveryAdmissionCompositionTests.swift`, `DeliveryAdmissionTests.swift`,
`FinalDeliveryAuthorityTests.swift`, `FinalDeliveryTestSupport.swift`,
`TaskProgressGuardedAdapterTestSupport.swift` and `TaskProgressHandoffTests.swift`. Each file is
checked separately with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

`git diff --check` and the staged equivalent passed. Host checks are limited to lint and diff checks.
No host build or test was run. This record establishes no simulator, physical-device or live
captured-output behavior.
