# Explicit library composition (#166)

Source 0.1.59 joins the managed diagnostic adapter, owned publisher and owner-only local reply
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
