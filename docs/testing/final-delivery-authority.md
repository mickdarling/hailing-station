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

`FinalDeliveryAuthorityTests` uses synthetic adapters, never-started transports, injected clocks and
continuation barriers. It covers final transport authority at registry and adapter boundaries, final
reply authority (lease, permit, lifetime and clock), and current ambient and local dispatch authority.
The permit case uses an unchanged failed policy transaction and independently confirms that the input
policy generation remains current. Existing tests are unchanged.

## Verification

Verification is pending on a fresh Dev Work VM workspace, bundle-synced from this branch. No host build
or test is used. The focused command is:

```sh
WS=vwauth ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(FinalDelivery|LocalDispatch|Ambient|HailHost|Host|Reply|RightyoInputConsumer|WebSocket|Listener)'
```

Before each VM run, wait for the shared lane to be idle. SSH stdin is closed with `< /dev/null`.
`Tests/ReplyCLITests` is a Python suite, so it runs separately with
`python3 -m unittest discover -s Tests/ReplyCLITests`, using the VM-built executable. The reply CLI
evidence boundary and existing runner guidance are in [reply-cli-ci.md](reply-cli-ci.md).

Host lint uses this command for each changed Swift file:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

The PR-shape production count is four: `WebSocketPeer.swift`, `WebSocketListener.swift`,
`LocalDispatch.swift` and `HostSession+Routing.swift`. Tests and this document are excluded by the
checker's existing rules. Independent exact-head review and the security-critical second key remain
pending. No GitHub API call, push, deployment, simulator or physical-device validation is claimed.
