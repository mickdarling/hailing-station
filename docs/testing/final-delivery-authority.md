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

## Verification

Verification uses a fresh Dev Work VM workspace, bundle-synced from this branch. No host build or test
is used. The focused command is:

```sh
WS=vwauth ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(FinalDelivery|LocalDispatch|Ambient|HailHost|Host|Reply|RightyoInputConsumer|WebSocket|Listener)'
```

Initial VM compilation identified actor-isolation annotations needed in the new assertions. After
those corrections, the first execution identified the new fixture's empty guard list as invalid
policy. The fixture now uses a neutral synthetic guard. A focused diagnostic also corrected permit-test
isolation: a target policy transaction retires input authority, so the test instead calls the existing
internal reply-authority retirement method. Those attempts are not passing evidence.

The corrected source/test snapshot is `38a4096ac5a060f5e837af6145f5ca2ed3dddc13`. Its focused
authority check passed with `build=0`, `test=0`: **6 tests in 1 suite**, covering **13 cases**, in 0.017 s:

```sh
WS=vwauth ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.FinalDelivery'
```

The final requested regression filter on that snapshot passed with `build=0`, `test=0`:
**919 tests in 168 suites**, in **519.559 s**, with **10 expected known issues** from the existing
`LocalDispatchPreflightWaitTests` and `ReplyRecipientHandoffWaitTests`. There were no unexpected
issues. The new authority suite also passed inside this run. Build output includes missing
module-cache debug-info warnings; this is Command Line Tools VM iteration evidence.

The saved logs are `~/codex-workspaces/vwauth-build.log`, `~/codex-workspaces/vwauth-test.log`,
`~/codex-workspaces/vwauth-final-build.log`, `~/codex-workspaces/vwauth-final-test.log` and
`~/codex-workspaces/vwauth-cli.log`. Final source and tests match the corrected snapshot; the final
follow-up changes this document only.

Before each VM run, a remote script waits for the shared lane to be idle using the literal loop below.
The script's process arguments contain only its filename, keeping the wait pattern out of those arguments.
SSH stdin is closed with `< /dev/null`.

```sh
while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done
```

`Tests/ReplyCLITests` is a Python suite, so it runs separately with
`python3 -m unittest discover -s Tests/ReplyCLITests`, using the VM-built executable. The reply CLI
evidence boundary and existing runner guidance are in [reply-cli-ci.md](reply-cli-ci.md).

The reply CLI suite passed: **124 tests in 215.062 s**, `OK`. It used the executable built from
`d8c7bff140955ec4a3b7c939c08ab4c4e0aa43f7`; production sources are identical to the corrected snapshot.
Only the new Swift test fixtures changed between those snapshots. No existing tests changed.

Host lint passed with zero violations for all six changed Swift files, using:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

`git diff --check` and its staged equivalent passed.

The PR-shape production count is four: `WebSocketPeer.swift`, `WebSocketListener.swift`,
`LocalDispatch.swift` and `HostSession+Routing.swift`. Tests and this document are excluded by the
checker's existing rules. Independent exact-head review and the security-critical second key remain
pending. Online PR-shape issue, label and review checks are not run under the no-GitHub instruction.
Full repository verification, simulator builds and physical-device proof are outside this focused
record. No GitHub API call, push or deployment is claimed.
