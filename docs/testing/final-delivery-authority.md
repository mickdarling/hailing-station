# Final delivery authority

Part of #1120. Tighten final delivery authority checks at the adapter handoff.

Final delivery authority includes a live-peer token and, for a fresh reply owner, its original reply
permit, cooperative binding lease when present, and ordinary request lifetime. The clock must remain
at or beyond creation and strictly inside that lifetime. The existing `DeliveryAuthority` carries these
synchronous checks through the registry to the adapter. Checks hold only short authority gates and
never span adapter I/O or an asynchronous wait.

The peer token uses the existing terminal reply-transport lifecycle. WebSocket receive and local
dispatch entry points retain that token. Ambient dispatch, local socket dispatch and the
`rightyo --reply-to` dispatch path share the peer entry point; phone text uses the receive entry point.
Listener shutdown retires every peer token before its first suspension. Transport close and terminal
connection callbacks retire the same lifecycle.

Session delivery composes the fresh owner's original tickets and clock with the retained peer token.
It preserves any existing task-progress handoff closure, using the existing `beforeHandoff` composition
hook already captured by HailHost's `DeliveryAuthority`. This keeps the change within four production
files without introducing another adapter contract. Post-handoff ownership commit remains required.
Refusal uses the existing outcome vocabulary and removes uncommitted ownership state.

Legacy ambient references retain their existing unleased binding contract: final authority checks the
reply permit and lifetime, while existing listing and adapter binding checks apply. Generic legacy
input has no fresh reply owner; its peer token and existing policy authority still apply. Direct
HailHost callers without a peer or fresh reply owner retain their existing authority contract.

`FinalDeliveryAuthorityTests` uses synthetic adapters, never-started transports, injected clocks,
continuation barriers and a loopback phone-text connection. It covers final transport authority at
registry and adapter boundaries, final reply authority (lease, permit, lifetime and clock), current
ambient and local dispatch authority, and the legacy ambient-reference lifetime boundary.
The permit case uses the existing internal reply-authority retirement boundary and independently
confirms that the input policy generation remains current. Existing tests are unchanged.

## Rebase and held Send

Rebased onto `9aa07edd319913264d86f863465c2e0501799ba3`, retaining the host held-request store.
Ambient read-backs are held only when the originating session negotiated `held_requests`; other sessions
retain cancellation and refusal. Reservation follows evaluation that requires a hold. Held Send and
Discard retain their existing scopes and paths.

Held Send carries the same final delivery authority as ordinary dispatch: a retained live-peer token
and the fresh reply owner's permit, lease and lifetime through the session's `beforeHandoff` hook.
The held confirmation hash remains part of `sendAuthorized`. The fixed nested gate order is reply
permit, binding lease, peer token, then clock. Those gates release before the prior task-progress
hook runs; HailHost subsequently checks held policy, selection, permission and notice lifetime through
the same `DeliveryAuthority`. When final reply authority is retired, held refusal reasons retain their existing order after the
final gates release. No gate is acquired twice within a nested critical section. Peer close,
transport close and listener shutdown continue to retire the peer token synchronously.

`FinalDeliveryHeldAuthorityTests` exercises current held Send and independent final peer/reply authority,
plus held notice expiry and selection at a suspended adapter handoff. All fixtures are synthetic.

## Verification

The earlier branch snapshot `38a4096ac5a060f5e837af6145f5ca2ed3dddc13` passed 919 tests in 168 suites
with 10 expected known issues, plus 124 reply CLI tests. Rebased-source verification follows below;
these earlier counts are historical evidence only.

The rebased source/test snapshot is `d86a833a31c37118450bdd9f475d84ab283e1ad8`, synced with
a git bundle of `origin/main..HEAD` into a fresh GitHub clone on the Dev Work VM.
The clone fetched the bundle's `HEAD`; subsequent source corrections
were fast-forwarded from a new bundle with the same range. No source was pushed.

Each VM job waits for the shared lane using a remote script whose
process arguments do not match the wait pattern. SSH invocations are blocking with stdin `< /dev/null`.

Each run waited for the shared VM lane to be idle.

The VM verification wrapper built the package and tests, then ran the filtered tests: `'HailDaemonKitTests\.(FinalDelivery|Held|LocalDispatch|Ambient|HailHost|Host|Reply|RightyoInputConsumer|WebSocket|Listener|Guard|Policy)'`.

The first rebased run identified a same-target selection fixture that did not change selection, and
held refusal-reason ordering when reply authority also retires. The fixture now selects another
synthetic target and returns; held refusal reasons preserve their established order after final gates
release. That initial run is not passing evidence.

On the corrected snapshot, the focused diagnostic command passed with `build=0`, `test=0`:
**48 tests in 10 suites**, 0.141 s, including the existing held concurrency checks.

The VM verification wrapper built the package and tests, then ran the filtered tests: `'HailDaemonKitTests\.(FinalDelivery|Held)'`.

The full requested filter then passed with `build=0`, `test=0`: **1,032 tests in 186 suites**,
591.241 s, with **10 expected known issues** from `LocalDispatchPreflightWaitTests` and
`ReplyRecipientHandoffWaitTests`. There were no unexpected issues. Both final-authority suites passed
inside that run. The new held suite has five test functions covering nine cases. These are synthetic
macOS VM results using the supplied Command Line Tools runner, not physical-device proof.

The reply CLI suite then passed: **124 tests in 215.892 s**, `OK`, exit **0**, using the VM-built
executable in the same workspace:

```sh
python3 -m unittest discover -s Tests/ReplyCLITests
```

Host strict lint passed with **zero violations in all seven changed Swift files**:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict Sources/HailDaemonKit/Listener/WebSocketPeer.swift Sources/HailDaemonKit/Listener/WebSocketListener.swift Sources/HailDaemonKit/Listener/LocalDispatch.swift Sources/HailDaemonKit/Listener/HostSession+Routing.swift Tests/HailDaemonKitTests/FinalDeliveryAuthorityTests.swift Tests/HailDaemonKitTests/FinalDeliveryTestSupport.swift Tests/HailDaemonKitTests/FinalDeliveryHeldAuthorityTests.swift
```

The exact production exclusions in `scripts/pr-shape.py` count four changed production files:
`WebSocketPeer.swift`, `WebSocketListener.swift`, `LocalDispatch.swift` and `HostSession+Routing.swift`.
There are no renames. Tests and this document are excluded. No GitHub API call, push, deployment,
host build/test, simulator build or physical-device validation was performed. Independent review is
not claimed. Full repository verification remains outside this focused record.

Finally, the requested warnings-as-errors build passed with **build exit 0** and **script exit 0**:

The VM warnings-as-errors build of the package and tests.

The CLT linker emitted missing module-cache debug-info warnings; the warnings-as-errors Swift build
completed successfully. This is VM iteration evidence, not a shipping-Xcode build.

Full and focused build/test logs, reply CLI output, and warnings-as-errors build/result
logs were retained on the VM. The initial nonpassing test log was retained separately.
Source and tests match the verified snapshot; the final follow-up updates this document only. `git diff --check` and its staged equivalent passed.
