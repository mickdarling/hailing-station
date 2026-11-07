# Held ambient requests: host foundation (#1120, PR 3)

Status: host-only implementation on the local unmerged stack. Nothing advertises `held_requests`; no held notice,
decision or resolution frame is sent. This is synthetic host groundwork, not a shipped build, physical-device
proof, live captured-output round trip or delivery deployment. No installed daemon, private configuration,
allowlist, TestFlight build or app is changed.

## Design

`HailHost` owns an in-memory `HeldRequestStore`. Before evaluating a new ambient dispatch, the session reserves
one possible hold slot. Reservations and unresolved holds share limits of eight per originating connection and
64 per host. There is no eviction, age purge or disconnect purge. Exhaustion returns `holdAdmissionRefused`
through the structured local dispatch API. The existing consumer receives its per-request capacity refusal and
keeps the run. Device-side admission/backpressure and local buffering are still required before advertisement.

A hold retains the exact prepared prompt, including any already-minted #230 reply reference, connection,
selection generation, target, binding, original target-policy grant and host policy revision, same-evaluation
read-back/hash, closed reasons, frozen rule tokens and notice deadline. All configured guard names map to
`custom`; only the daemon default rule set may map trusted built-in names. Hashing still uses the existing
sanitized `DeliveryRequest`, so confirmation is checked against the same prepared content after sanitization.

`HeldRequestPolicy` names the v1 choices: `onPrivacy = .keep`, `persistence = .memory`, and `reoffer = .sameDevice`.
These are the settings seam for later issue decisions. No alternate deletion or persistence behavior is enabled.
Host crash/restart loses memory. Reconnect does not transfer ownership: authenticated same-device recovery,
re-offer and host-local recovery/Discard UI remain deferred.

`HostDeliveryOutcome.held` and `LocalDispatchResult.held` carry the opaque ID and content-free notice. The existing
ambient consumer deliberately continues to receive its established `.confirmationRequired` per-request refusal,
which #874 already handles without ending the run. Non-ambient confirmation still says “confirm at the Mac”.
The generic local socket response is unchanged; structured held IDs are not sent on that socket or the wire.

The public listener APIs are `sendHeld`, `discardHeld`, and content-free `heldStatus`, scoped to the originating
session connection UUID. Send checks live peer membership/liveness, original selection generation (including
away-and-back), live target and exact binding, original policy grant/revision, authorizer, privacy snapshot,
lockdown, allowlist/tier, rate limits, fresh guard evaluation, reply permit/lease, capacity and request lifetime
through normal session/registry/host delivery. Policy changes refuse rather than silently adopting new authority.
Selection, privacy, lockdown, pinned policy revision and notice expiry also participate in adapter delivery
authority checks. Listener liveness is checked again
before host dispatch and each line handoff. Existing adapter authority contracts still define the handoff boundary.

Only a fresh `.confirm` can consume a held read-back hash. A denial never becomes delivery. A fresh timeout or
new guard evidence renews the hold rather than using old consent. Expired notices are renewed for the same held
ID/content and cannot deliver automatically, including when fresh evaluation is clean. If expiry occurs at the
adapter authority boundary, delivery is refused and the next explicit Send renews the notice. No timer sends or
purges content. Ordinary refusals remain retryable and keep their hold slot. Privacy/lockdown refuse Send while
Discard remains available. No held text is shown or spoken by these APIs.

The store coalesces overlapping Sends and serializes Discard against an in-flight Send. Successful Send and
explicit Discard release content and leave minimal terminal replay records: duplicates and conflicting later
decisions replay the terminal result. An uncertain adapter handoff keeps the content, reports `unresolved`
through `heldStatus`, and blocks further Sends until future reconciliation; explicit Discard remains possible.
Unknown or inaccessible IDs on a live originating API path are `stale`. Terminal records contain no prompt or read-back.

Content-free logs are `ambient_request_held reasons=... rules=...` and
`ambient_request_resolution outcome=... reasons=... rules=...`. Values come only from closed enums, never prompt,
custom rule name, pattern, hash, endpoint or identity. These OSLog records are not chain audit records.

## Files and PR shape

Exactly four production files, counted against local stack head `160b770c` using `scripts/pr-shape.py` exclusions:

- `Sources/HailDaemonKit/Listener/HeldRequests.swift`: store, snapshots, policy settings, serialized decisions.
- `Sources/HailDaemonKit/Listener/HostSession+Routing.swift`: reserve, hold instead of cancel, pinned selection.
- `Sources/HailDaemonKit/Listener/LocalDispatch.swift`: structured outcomes and listener APIs.
- `Sources/HailDaemonKit/Daemon/HailHost.swift`: authorized confirmation, rate-limit holds, same-evaluation evidence,
  fresh checks and injectable host clock.

New `Held*Tests.swift` files cover admission/content/scope/reference, stream continuation, terminal replay,
concurrent decisions, selection/binding/target/policy/privacy changes, rate/capacity, fresh timeout, expired notices,
unknown/foreign IDs, discard, bounds and content-free log/notice fields. Two existing #874 tests are updated because
they explicitly asserted the ambient read-back cancellation that this change removes. Direct host-local
`RightyoHostDispatcher` and non-ambient confirmation behavior retain their existing expectations.

| Test file | Evidence |
| --- | --- |
| `HeldRequestTestSupport.swift` | Shared synthetic rig with injected clocks and privacy state. |
| `HeldRequestTests.swift` | Exact content/scope, reasons, Send/Discard, replay, ownership, selection, binding, target, policy, rate, expiry and admission bounds. |
| `HeldAmbientStreamTests.swift` | One held request followed by a delivered request in the same consumer run; disconnect retains the hold. |
| `HeldRequestConcurrencyTests.swift` | Concurrent decisions, away/back during suspension, policy/privacy/lockdown/expiry at the adapter boundary and uncertain handoff. |
| `HeldRequestFreshChecksTests.swift` | Global guard-policy change, capacity, privacy retry, 64 actual host-wide holds and content-free fields. |
| `HeldRequestLegacyTests.swift` | Listener APIs preserve the original #230 reference and exact prompt; expired notices with clean fresh evaluation still renew. |
| `RightyoInputRequestRefusalSessionTests.swift` | Updated cancellation expectation, with non-ambient confirmation unchanged. |
| `RightyoInputRequestRefusalTests.swift` | Existing consumer continuation expectation now distinguishes retained ambient read-backs from the unchanged direct host dispatcher. |

## Verification

No host builds or tests. Host work is limited to source edits, Git, SSH and strict SwiftLint.

The Dev Work VM workspace was freshly cloned from GitHub at `~/codex-workspaces/vw1120c`. Each validation snapshot
was committed locally and synchronized with:

```sh
git bundle create /tmp/vw1120c.bundle origin/main..HEAD
# Copy the bundle to the VM, then in its fresh clone:
git fetch /tmp/vw1120c.bundle HEAD
git checkout --detach FETCH_HEAD
```

Before each run, a VM script waits with the requested loop, with no runner name in its own command line:

```sh
while pgrep -f vw327-run.sh >/dev/null; do sleep 20; done
WS=vw1120c ~/codex-workspaces/vw327-run.sh 'HailDaemonKitTests\.(Held|Ambient|Guard|Policy|HailHost|Host|LocalDispatch|RightyoInputConsumer|Audit)'
```

SSH stdin is closed (`< /dev/null`) and the command runs synchronously. A different session's waiting command
initially matched the literal pattern; it was left alone and the requested wait eventually cleared. No competing
runner was stopped. The final wrapper preserves workspace-specific build/test logs.

The final source validation snapshot is `bb44e03efefdd8be9f4afed1bc6debeae9480e2e`. A documentation-only
commit records the final results afterward. Build time was 69.88 seconds; the existing missing-module-cache
debug-info warnings were present. The requested full command returned **`build=0`, `test=0`**:
**981 tests in 174 suites passed in 386.247 seconds**, with **zero unexpected failures** and the five
intentional known issues described below. All five new held-request suites passed.

Strict lint passed with zero violations for all **12 changed Swift files**, using this exact command per file:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b swiftlint lint --strict <file>
```

Earlier validation history is retained rather than described as passing:

- Two initial compile runs found public-import/actor-isolation and test-helper type errors; these were fixed.
- Snapshot `dee7a456` built successfully and ran **973 tests in 172 suites**, with **two unexpected failures**
  plus **five known issues**, in 504.785 seconds. The failures exposed lockdown classification and premature
  confirmation consumption on a rate denial; both were fixed. Logs are retained on the VM as
  `~/codex-workspaces/vw1120c-dee7a456-build.log` and `vw1120c-dee7a456-test.log`.
- Snapshot `ae10bead` built, then its own test process tree was stopped to include the additional adapter-boundary
  lockdown/privacy/expiry checks in the final run. Its partial test log is not a completed verification result.
- The five known issues are deliberately expected assertions in `LocalDispatchPreflightWaitTests` for missing
  listing arrival, early dispatch exit and a suspended synthetic step. They are distinct from unexpected failures.

The final full command's workspace-specific logs are `~/codex-workspaces/vw1120c-build.log` and
`~/codex-workspaces/vw1120c-test.log`.

All new time-sensitive tests use injected clocks or explicit continuation/stream barriers, without sleeps.
Existing regression suites retain their own timing mechanisms. No simulator or physical device validation is claimed.

## Deferred work and blockers before advertisement

- Chain audit events for `held` and resolution, including target, reasons/rules, salted text hash and byte length.
  This PR deliberately does not repurpose `delivered` as a held event. Adding truthful event kinds and their existing
  hashed-text fields requires audit event/field/schema edits beyond the four-production-file budget; host Send
  needs the fourth file. Audit serialization coverage for held events therefore remains deferred, not passed.
- The optional #1123 carry-forward treating regex `internalError` as timeout requires the guard implementation
  file and is deferred under the same limit.
- Capability advertisement, wire handlers/notices, clear Send/Discard UI, admission/backpressure/device buffering,
  authenticated same-device reconnect recovery, restart reconciliation, persistence decisions, uncertain-handoff
  reconciliation and provider-context exclusion remain later #1120 work.
- Independent exact-head security review/second key and PR checks have not been requested or represented as complete.
  This worktree is local only and has not been pushed or opened as a PR.
