# Retained delivery authority

Part of #1120.

The host composes retained delivery authority in the admission stage order. HailHost supplies the
single target-policy gate. Session delivery contributes the original reply permit, binding lease,
peer permit and request clock. Task delivery contributes its original output fence, session-update
fence, ambient audience, privacy revision, peer permit and attempt decision. The task generation must
match the host generation; the task stage uses `TaskProgressOutputFence.perform`, without calling
`TaskProgressPublicationAuthority.perform` or reacquiring target policy.

The task wake caller explicitly binds the retained stages before host dispatch. This requires four
production files: `HailHost.swift`, `HostSession+Routing.swift`, `TaskProgressAuthority.swift` and
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

## Synthetic coverage

`DeliveryAdmissionCompositionTests` covers independently retired policy, permit, lease and peer,
exact request expiry, clock rollback, TaskLocal replacement, generation identity, read-only validation
and composition of the real policy lock with the task fence. `FinalDeliveryAuthorityTests` adds
barriers after handoff and before completion for contextual and legacy ownership. The pending
session record is present when only peer authority retires; neither ownership nor last-input
attribution commits afterward. `TaskProgressHandoffTests` adds checked-handoff attempt accounting.
Existing test cases remain unchanged. The new concurrency tests use injected barriers and clocks,
without sleeps.

## Verification

Verification is pending on the Dev Work VM. The workspace is a fresh clone at
`~/codex-workspaces/vwf2`, synchronized with a local bundle of `origin/main..HEAD`, including the
prerequisite delivery. Each run waits for the shared lane in a remote script:

```sh
while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done
WS=vwf2 ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(DeliveryAdmission|DeliveryAuthority|FinalDelivery|TaskProgress|Held|LocalDispatch|HailHost|Host|Ambient|Tmux|Reply)'
python3 -m unittest discover -s Tests/ReplyCLITests
~/codex-workspaces/vw-werr.sh vwf2
```

SSH stdin is closed with `< /dev/null`; each command completes before the next begins. Host checks
are limited to strict lint per changed Swift file and diff checks. This record establishes no
simulator, physical-device or live captured-output behavior.
