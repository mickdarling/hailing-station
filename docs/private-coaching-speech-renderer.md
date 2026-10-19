# Private coaching speech renderer — inactive source (#269 / #268 / #225)

The narrow haild adapter reuses OwnedReplyRenderer's existing PCM stdout capability. It neither publishes
ordinary replies nor constructs playback, a socket, a target dispatcher or a route. Its local factory is inert;
only an explicitly enabled foreground owner can request rendering. Tests replace the source or use an authored
owner-private fake executable. They never invoke the installed vbsay, query devices, capture live audio, contact
a service or make an inference request.

The audited renderer sets VBSAY_STDOUT/VBSAY_NOPLAY, supplies text as a single argv element (no shell), and
produces mono24k s16le. The existing trusted local vbsay implementation treats argv as text and disables its
own player and macOS-say fallback in stdout mode. Its selected local service/runtime remains an operator trust
precondition, not a sandbox or a new hosted-text permission. No service was executed for this audit.

The adapter reserves one render slot before callback-capable construction, rechecks cancellation after every
await/callback, caps PCM at96k bytes/32chunks and48k bytes per chunk, joins split sample bytes, and rejects empty
or incomplete PCM. The last nonempty chunk is finalized only after successful renderer exit and owned cleanup.
Every chunk passes the coordinator's immutable original advice gate; no asynchronous downstream route is chosen.

Cancellation retires only this source and retains the slot until cleanup returns. OwnedReplyRenderer fences
signals/reaping against exact child ownership. The adapter explicitly awaits requireSuccessfulExit even after
abnormal retirement: waitForCleanup can report deferred artifacts before exit and cancellation signals do not
prove reaping. Cancellation/error from the exit boundary is an outcome after joining, not permission to skip it.
Historical failed
renderer artifacts remain preserved; abnormal cleanup or ownership loss is an error, not successful final speech.
Kernel reaping is not promised within a fixed deadline. The foreground owner remains retiring until return,
so a noncooperative source cannot create overlapping successor work. This joins only the exact owned child,
not arbitrary descendant quiescence; the existing trusted nonescaping renderer remains a precondition.
No bypass of runtime/signal hooks is added.

Full Round1 rejected the .140 speech head: it emitted first sequence 1 against the foreground gate's required
0, rejected printable Unicode already admitted by the advice contract, and could lose its join handle when
the renderer constructor spawned then threw cancellation. The public-owner ASCII/escaped-Unicode regression
failed on the old source; independent authored-child probes reproduced early return before reaping five times.
These failures and artifacts remain preserved. The corrected source captures sequence 0 and reserves its
increment before callback entry, uses the same bounded printable Unicode policy as advice admission, and uses
a coaching-only synchronous joinable-start factory. That factory still rejects pre-spawn cancellation/errors;
post-spawn cancellation retires but returns the owned facade so the render job installs it before cancellation
checking and joins before releasing its slot. Ordinary renderer constructor behavior remains unchanged. No
detached late-start construction is introduced. Composed synthetic playback and five authored startup-cancel
cases now pass, but a fresh exact-head full review is still required; this paragraph is not an approval.

Full verification and independent exact-head review remain pending. This adapter does not complete command wiring,
actual executable proof, speech-quality qualification or physical headphone privacy proof. It remains unmerged,
unpublished and undeployed. Native execution requires separate scoped human authorization.
