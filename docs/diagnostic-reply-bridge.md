# Managed diagnostic reply utility

Part of #166 and #161. This is library-only groundwork: no daemon registration,
local profile/configuration change, target grant, renderer invocation, AI session,
device action or TestFlight upload is performed by this slice. The existing Claude
tmux session is not a compatible bridge and is not replaced.

`DiagnosticReplyBridgeAdapter` is a deterministic in-process utility with one
distinct target, `diagnostic-reply:roundtrip`. It is constructed only explicitly
with a trusted host identity and an injected asynchronous publisher. A separate
reviewed composition slice must keep it default off, supply the existing
`haild reply` renderer/owner-only endpoint path with fixed arguments, and obtain
the operator's separate exact target policy grant. No selection or grant is automatic.

## Stable utility identity and cooperative retirement

The listed binding `diagnostic-roundtrip-v1` identifies this implementation of
trusted deterministic utility code, not an observed pane or external process.
It is deliberately stable: a `targets allow` CLI invocation constructs a different
adapter instance from the running daemon, so a random per-instance listed binding
would grant the wrong target. Incompatible utility implementations must change
this binding version and require a new exact grant. This rule does not authorize
using stable bindings or lease polling for externally rebindable tmux sessions.

Each instance still owns an independent private publication gate. Lease acquisition
validates host/provider/target/session identity and returns the exact requested
five-field `ProviderSessionBinding`, including its fresh ingress observation ID.
There is no output observation or capture subscription. `stop()` permanently
invalidates that instance's permits before cancelling/draining work, and destruction
also invalidates permits. There is no restart/rebind method that revives old leases.
A separately constructed utility has an independent gate; old connection requests
cannot transfer into the new daemon's HostSession.

## Bounded programmatic context and output

Contextual delivery encodes and strictly decodes one LF-terminated JSON line with
exactly `version`, `request` and `text`. Version must be literal integer `1`;
duplicates, unknown fields, wrong types, invalid UUID/string escapes, raw multiline
or CRLF framing and oversize data/text are refused. Text must be nonempty,
non-whitespace and a single line, with existing protocol byte limits. The decoded
UUID must equal the delivered host-owned context, never a string found in text.
Neither raw text nor an envelope is passed to a shell, model, publisher or log.

The queue retains at most 16 request records including active work and starts at
most four publishers. Admission acknowledges the bounded queue without awaiting
its own dispatch commitment or output completion. Up to 64 recent request UUID
tombstones remain for 120 seconds to refuse recent duplicate delivery, and queued
or active IDs remain non-admissible even if a callback outlives that interval.
Capacity refuses instead of dropping or retargeting requests. No model, FIFO origin
inference, wake-word logic or input echo participates in response generation.

The publisher receives the retained request UUID, trusted host and fixed target,
and a monotonic local sequence. The phrase is explicitly labeled:
`Hailing Station diagnostic reply N. Over to you.` Routing UUIDs and user text are
never generated into it. Concurrent callbacks may complete in any order; each
retains its own request identity. The publication layer, not callback ordering,
must enforce the original requesting connection and final revocable gates.

The future renderer callback must retry only the explicit bounded pre-publication
`requestPending` refusal with identical frame identity. Any other refusal or
ambiguous send failure remains a failure, and speech must not be fabricated.
The adapter itself does not turn a lease check into an asynchronous publication
grant; the owner-only endpoint retains final enqueue authority.

## Safe diagnostics and limitations

Public diagnostics expose only queued/active/completed/failed/cancelled counts and
a fixed failure enum, never raw input, request UUIDs or provider error text.
Completed means the injected publisher returned successfully, not that a device
heard audio. Publisher failures become visible aggregate failures, not successful
or fake audio. Cancellation is cooperative: active callbacks that ignore it remain
counted until they return, and no new work is accepted after stop. A permanently
stalled callback can occupy a slot; capacity remains bounded. The reviewed renderer
integration must supply its own bounded, cancellation-aware operational behavior.

Synthetic tests cover strict envelopes, exact lease identity/retirement, separate
CLI/daemon stable bindings, context mismatch, queue/concurrency bounds, cancellation,
safe failure diagnostics, recent duplicates, both client request orders and
interleaved completion. No physical-device speech or provider output is claimed.
Keep #161/#166 open through composition and controlled physical validation.
