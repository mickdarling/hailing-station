# Private-coaching foundation publication (#269)

This records source provenance and the remaining delivery boundary. It is not an installed-build,
hardware, full-duplex or useful-coaching qualification.

## Content coverage

The original aggregate is `650ef10c4a290dfc5803aa2f379f985f9f1294b2` (30 production paths).
The corrected integration anchor is `99a0167f75771957bdc17d94e4dc12bc18483415`, including the
already-owned fixture, startup and player-effect corrections through #513. Publication copies the final
owning files/tests/docs; historical intermediate versions are not separate delivered implementations.

Existing foundation #514, #516, #518 and #549 cover lifetime, wire/consumer, renderer/monitor and
capture-run identity. #553 adds fixed Mac output evidence/binding; #557 adds Apple/native ownership.
The bounded #561–#566 branches publish foreground lifetime, child control, codec/transport/configuration,
joined speech, explicit command/keyboard and test-only entry/cleanup fences. This follow-through carries
verifier registration and the late #557/#561 corrections with original commit references; later bounded
follow-through units carry #562/#563/#565 corrections without rewriting earlier published histories.
Every source unit stays within the authoritative four-production-file limit.

A complete-tree comparison for this follow-through against the corrected anchor accounts for:

- ApplePrivateCoaching Begin-registration and renewal cleanup track the exact lease rather than only
  its generation. Authored same-generation renewal/reentry cases fail before correction and preserve
  newer capture/advice afterward. Monitor cleanup also handles nil-core retirement after ledger exhaustion
  or clock expiry. Lifecycle revisions fence reentrant Stop/Begin from monitor disarm, startup, explicit
  retirement and renderer-denial cleanup; an old operation cannot overwrite a successor. Tests also establish that partial-start nil cleanup and the core's
  suspended-hook transition fence already work. The test-only suspension hook and owning regressions
  are deliberate fixture additions, without a new public production accessor or capture backend.
- ForegroundCoaching retires the current run when an effect observes its original run/lease deadline.
  Timer delivery is deliberately withheld at the 900-second boundary while the short capture lease
  remains valid; exact-boundary and later cases fail before correction, while earlier controls work.
  A changed lease or epoch cannot give an old operation cleanup authority over a successor. The run
  deadline is sampled before capture startup; a 500ms qualification-send delay cannot extend that budget.
- This source publication preserves the foundation prerequisite's existing marketing version 0.1.111,
  rather than copying the aggregate's historical 0.1.158. It is not a new installed build.
- This provenance document is additional documentation.

The existing verifier registration for CoachingTransportRegression and AmbientSharedAudit is included.
It moves the unchanged suites into the serial timing lane. Assertions, budgets, watchdogs and gates
are not relaxed. Tests, fixtures, documentation, Package.swift and all other source content are compared
as complete trees, not inferred from path counts or commit subjects.

## Review and delivery boundary

Independent reviews and current-head CI are recorded in each PR. Pending, rejected and superseded
rounds remain visible; local synthetic success is separate from independent approval and hosted checks.
Three executable integration cases explicitly skip unless a pinned authored-only producer is supplied.
No skipped case establishes a producer-to-playback round trip.

The original aggregate, #509–#513 and downstream Mac branches retain their histories. Publishing this
replacement foundation does not automatically reconnect those downstream branches. Their source join,
any resulting new review, maintainer merge and later delivery are separate work; no install, active
validator change or deployment follows from this provenance record. All late corrections must be
included in the eventual verified integration before a replacement build is delivered. Source content
coverage does not replace current-head independent reviews, required second keys or actual hosted CI.

Useful private coaching (#266/#524), actual Superwhisper coexistence, speaker double-talk/barge-in
and conferencing/system audio (#525) still require their own acceptance evidence. The user-confirmed
basic Mac conversation session is distinct from those capabilities. No captured speech, transcript,
private endpoint, device identity or biometric score is retained here.
