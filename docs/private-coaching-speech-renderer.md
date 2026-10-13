# Private coaching speech renderer — inactive source (#269 / #268 / #225)

The narrow haild adapter reuses OwnedReplyRenderer's existing PCM stdout capability. It neither publishes
ordinary replies nor constructs playback, a socket, a target dispatcher or a route. Its local factory is inert;
only an explicitly enabled foreground owner can request rendering. Tests replace the source and never invoke
vbsay, query devices, capture audio, contact a service or make an inference request.

The audited renderer sets VBSAY_STDOUT/VBSAY_NOPLAY, supplies text as a single argv element (no shell), and
produces mono24k s16le. The existing trusted local vbsay implementation treats argv as text and disables its
own player and macOS-say fallback in stdout mode. Its selected local service/runtime remains an operator trust
precondition, not a sandbox or a new hosted-text permission. No service was executed for this audit.

The adapter reserves one render slot before callback-capable construction, rechecks cancellation after every
await/callback, caps PCM at96k bytes/32chunks and48k bytes per chunk, joins split sample bytes, and rejects empty
or incomplete PCM. The last nonempty chunk is finalized only after successful renderer exit and owned cleanup.
Every chunk passes the coordinator's immutable original advice gate; no asynchronous downstream route is chosen.

Cancellation retires only this source and retains the slot until cleanup returns. OwnedReplyRenderer fences
signals/reaping against exact child ownership and waits for cleanup even on abnormal outcomes. Historical failed
renderer artifacts remain preserved; abnormal cleanup or ownership loss is an error, not successful final speech.
Kernel reaping is not promised within a fixed deadline. The foreground owner remains retiring until return,
so a noncooperative source cannot create overlapping successor work. No bypass of runtime/signal hooks is added.

Full verification and independent exact-head review remain pending. This adapter does not complete command wiring,
actual executable proof, speech-quality qualification or physical headphone privacy proof. It remains unmerged,
unpublished and undeployed. Native execution requires separate scoped human authorization.
