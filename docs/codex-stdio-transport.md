# Owned stdio transport prerequisite

Part of #153; not a completed Codex adapter. This macOS-only internal foundation
does not conform to `Adapter`, register targets, submit real inference, attach to
existing tasks, or publish captured output. #153 and #134 remain open. The source
marketing version is `0.1.21`, build `1`; no installed-device or TestFlight proof
is claimed.

## Interface and ownership

The [official App Server documentation](https://learn.chatgpt.com/docs/app-server)
was fetched before inspecting CLI `0.159.0` public schemas. Those schemas informed
the narrow typed method names (`initialize`, `thread/start`, `turn/start`) and
the no-ID `initialized` notification. The transport does not validate their
provider-specific parameter/result schemas or promise those operations succeed.
A later adapter must implement handshake sequencing, compatibility checks,
thread/turn/item attribution, visibility and terminal-state mapping.

`OwnedStdioCommand` requires an explicit absolute executable and argv from trusted
host composition. `posix_spawn` uses no shell, an explicit environment (empty by
default), close-on-exec isolation and discarded stderr. This is descriptor and
environment isolation, not proof that a real CLI ignores inherited working
directory, user configuration, hooks or CLI-managed credentials. There is no
default Codex executable, auth export, daemon registration or approval handler.

Use `CodexStdioTransport.withTransport` for scope ownership: early return, thrown
error and parent cancellation synchronously stop admission/close pipes, then join
the owned work before returning. Direct construction is internal low-level test
support and requires explicit `join`; dropping a reference is not cleanup.
`cancel` is synchronous and idempotent. `join` waits the transport reader,
retained writer/timer tasks, OS read/write/reap work and escalation callback.

The exact child PID is protected by the same lock for signalling and `waitpid`.
Termination closes nonblocking parent pipes and sends SIGTERM, then SIGKILL after
the configured grace when the owned PID remains unreaped. Tests inspect actual
reaping, including a child that ignores SIGTERM. Ownership does not extend to a
child-created descendant process tree. Kernel/process scheduling is not a hard
real-time guarantee; tests bound observed synthetic shutdown.

## Framing, correlation and failure boundaries

- JSONL frames are at most 65,536 bytes excluding newline. Incomplete EOF is a
  fixed truncation failure. Strict UTF-8, at most 16 container levels and 2,048
  values are checked before decoding. Duplicate keys, including escaped-equivalent
  keys, are rejected before the decoder could collapse them. Outbound recursive
  values are bounded before encoding and exact encoded size is checked before
  admitting any write or spending an ID.
- The OS reader retains at most four 4,096-byte chunks. Overflow stops the child;
  it is not silent loss. Notifications are separately bounded by count (default
  32, maximum 256) and raw-frame bytes (default 65,536, maximum 262,144). A decoded
  value has bounded expansion, not a claim that raw byte limits equal heap bytes.
- At most four request/notification operations and their retained owned tasks are
  admitted. Notifications consume operation capacity too. One notification waiter
  is allowed. IDs are positive monotonic integers; replies resolve only a matching
  outstanding request, not arrival order. Duplicates, unknown IDs, ambiguous
  envelopes and server requests fail closed. Notification methods are limited to
  256 UTF-8 bytes; their payloads remain opaque and host-local.
- A request succeeds only when both its complete underlying write and matching
  reply have succeeded. An early reply cannot cancel the write deadline or mask
  broken-pipe failure. No-ID initialized sends have the same write deadline.
  Default deadline is two seconds; valid configurations are positive and at most
  60 seconds. Deadline failure stops the whole transport and resolves all waiters.
- EOF, cancellation, malformed input, overflow or write loss is terminal. A reply
  whose write/reply rendezvous already completed remains returned; EOF observed
  before that rendezvous fails pending work even if reply bytes arrived first.
  Queued notifications are purged on terminal failure. There is no reconnect or
  history fallback.

All thrown transport failures use `CodexStdioError`; arbitrary stderr, provider
error strings and identifiers are not diagnostics. Notification/result payloads
are deliberately available only to the internal caller, not logged or mapped to
visible output. A later contextual adapter must independently enforce capture,
exact binding/generation, policy freshness and cancellation authority.

## Verification record

All fixtures are invented public-synthetic Perl programs launched over actual OS
pipes; no model, account, live task, private configuration or device was accessed.
Logs remain ignored local artifacts, not committed build products.

After rebasing onto merged main `6ffdf89cc47233757f7829a35b07e1cd01345dae`:

- Focused command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift
  test --filter 'CodexStdio|OwnedStdioChild' -Xswiftc -warnings-as-errors`. The
  pre-rebase scope-proof run passed 30 tests in three suites, exit 0,
  retained as `artifacts/codex-transport-focused-scope-proof.log`. The source/test
  files were preserved by rebase. The later lint-only test layout adjustment
  moved one test into the same-file suite extension without changing behavior.
- The first `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  scripts/verify.sh all` exited 1: 556 tests in 91 suites, one `inUse` issue in
  unchanged `AuditLogFileTests.aClockStepBackStillFindsATailOlderThanEightDays`.
  All new transport suites passed. Log: `artifacts/codex-transport-all-first.log`.
  #79 remains unresolved; subprocess association is not an exact cause claim.
- The inspected audit follow-up (`swift test --filter AuditLogFileTests` with
  warnings-as-errors) passed eight tests in one suite, exit 0. Log:
  `artifacts/codex-transport-audit-file-followup.log`. After the meaningful test
  layout repair, one authorized full rerun passed 556 tests in 91 suites, all 45
  checker tests, five intent tests, one reply CLI test, audit/script checks and
  strict lint, ending `verify: OK`, exit 0. Log:
  `artifacts/codex-transport-all-inspected-rerun.log`. No repeated retry loop.
- A standalone final lint initially caught the new test suite body at 152 lines
  against its 150-line limit (`codex-transport-lint-final.log`); the same-file
  extension repair passed strict lint (`codex-transport-lint-layout-repair.log`).
  No suppressions or threshold changes. Standalone scripts also passed exit 0
  (`codex-transport-scripts-final.log`), before the passing combined rerun.
- First `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  scripts/verify.sh sim` passed build-for-testing, exit 0. Log:
  `artifacts/codex-transport-sim-first.log`. Read-only `plutil` inspection of the
  generated app and UI-test bundle confirmed `0.1.21` / `1`. This is generated
  simulator-product metadata, not installation, UI execution or physical proof.
- Offline `scripts/spec_trace.py` against the issue's seven named expectations
  exited 0 with exactly the three named adapter deferrals below; all four delivered
  expectations were recognized (`codex-transport-trace-final.log`).
  `git diff --check` passed. These are verification results, not an independent
  exact-head review or approval.

Development failures were inspected and repaired, not dismissed as existing
flakes. A handshake fixture used stale Perl `$1` after a failed match; branching
on the current match repaired it. `codex-transport-focused-draft.log` exposed an
early-response/broken-write error precedence race; the child now finishes its
stream with the fixed write-loss reason before cancelling. The next
`codex-transport-focused-writer-repair.log` still failed because the 60 KB fixture
could fully fit in the pipe before close; it did not prove an incomplete write.
The exact 65,536-byte frame plus newline forces that case and passed in
`codex-transport-focused-max-frame-repair.log` (29 tests, three suites). The final
scope-proof run added pre-cancelled no-spawn and scoped cancellation/reaping
coverage. Earlier compile/lint setup and complexity issues were corrected without
weakening repository gates. Only retained log paths are named here.

Spec trace is intentionally partial: the three transport suites and this document
are delivered; `CodexAppServerAdapterTests`, `CodexAppServerEventsTests` and
`docs/codex-app-server-adapter.md` are genuinely deferred. This prerequisite does
not establish provider-turn interruption, held server-request invalidation,
late-output exclusion, authenticated configuration isolation, captured-content
network delivery or mobile/TestFlight support. See #134/#153 for the separate
public-safe probe record and live-enablement blockers.
