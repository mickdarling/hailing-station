# Explicit library composition (#166)

This change joins the managed diagnostic adapter, owned publisher and owner-only local reply
endpoint in one explicit library lifetime. The daemon still has no diagnostic profile flag or
automatic registration. Existing runtime, grants, target selections and installed apps are unchanged.
This is not a Claude session bridge, deployment or controlled physical proof of #161.

Trusted construction supplies an existing private output root, exact trusted CLI executable, socket
and matching host identity. Neither a mobile request nor its text can choose these values. The publisher
uses the already reviewed fixed `haild reply` argv, retained UUID outside text, diagnostic phrase and
explicit owner-only output root. No new shell, renderer fallback, speech simulation in production or
whole-command retry is introduced. The injected environment/deadline constructor is internal test-only.

`DiagnosticReplyComposition.start()` awaits actual owner-only endpoint readiness before registering
the adapter. Construction alone is default off and admits no diagnostic work. Registration alone does
not grant policy or select a target; exact stable utility binding and existing ingress/policy/publication
checks remain required. The trusted owner must retain the composition and call `stop()` on shutdown.
Start is single-use, and a startup failure or cancellation permanently stops the lifetime.

Retirement invalidates the adapter's publication permits and stops utility admission before cancelling
publisher jobs and stopping the endpoint. If registration races retirement, an already in-flight registry
operation may leave a permanently dead adapter listed; it cannot revive stopped leases/admission. No
unregister operation removes somebody else's adapter. Repeated stop is safe. Publisher ownership retains
uncertain jobs/directories under its existing 16-admission/four-resource bounds; stop is not a promise of
immediate kernel or filesystem cleanup. Existing command outcomes and separately diagnosed cleanup
failures retain their reviewed semantics.

Synthetic `DiagnosticReplyCompositionTests` exercises construction/default-off, cancellation before
startup, duplicate registration failure, single-use start and real owner-only socket plus built CLI and
controlled renderer. Two real loopback WebSocket clients select the same exactly granted synthetic
target. Holding the first text acknowledgement lets the second reply finish before the first audio,
in both client request orders. Text, PCM and final marker share retained identity on each origin; both
clients' ordered pong barriers reject stray replies. Input text and identical client names are not
recipient authority. No microphone, physical client, real provider or real speech tool is used.

`DiagnosticCompositionRetirementTests` separately proves actual CLI renderer failure and stop
during a held acknowledgement remain failures with no fabricated audio; admission/root cleanup and
utility completion diagnostics settle without reporting success. Existing pending-only CLI retry,
failed dispatch, unknown/stale request and malformed envelope tests remain unchanged. These tests are
not physical hearing, elapsed kernel cleanup guarantees or a diagnosis of historical timing/network
failures. Daemon profile/configuration wiring, separately agreed operator target choice and physical
two-device validation remain deferred; keep #166/#161 open.

## Independent review correction: endpoint cleanup ownership

The first unpublished slice received a genuine independent REQUEST CHANGES. A never-started
composition could stop its inherited endpoint, whose cleanup previously unlinked any same-owner socket
at the configured path. Two lifetimes constructed before either started let the second remove the
first's live socket; the first's utility remained registered/alive. Existing verifier passes were not
proof against this gap.

The endpoint now records socket device/inode only on actual listener readiness, verifies it again after
permission hardening, and unlinks on stop only when that recorded identity, owner and socket type still
match. Never-started or failed-bind lifetimes have no cleanup identity. Late readiness after stop cannot
secure/claim a socket. A removed/replaced path is preserved, not repaired or automatically adopted.
Unknown pre-readiness residue may require operator recovery; no borrowed socket is deleted to make
startup appear clean. A private trusted-owner directory remains a precondition: POSIX has no atomic
inode-conditional unlink against hostile concurrent same-UID renames.

`LocalReplyEndpointOwnershipTests` failed before the correction for both the never-started composition
and an old ready endpoint stopping after a new live socket replaced its path. They verify retained
device/inode and normal removal of the new endpoint's own socket. No real endpoints or child ownership
were disturbed. This fixes endpoint lifetime cleanup ownership, not historical network/timing causes.
