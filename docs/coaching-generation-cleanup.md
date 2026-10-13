# Coaching cleanup ownership prerequisite

Part of #269, #268 and #225. This local source correction is independent of platform output classification.

Output and clock observations may synchronously replace or renew the current qualification. The core now
checks that its captured qualification still owns the lifetime before classifying an old route/deadline
failure as a reason to suspend. Capture-start and renderer-error cleanup is scoped to the originating
generation; old errors cannot stop a replacement's capture, cancel its queued advice or clear its context.
Real failures on the current generation still suspend, and deadlines are read before and after observation.
Final ticket validation and renewal issuance also recheck exact ownership after their clock reads. Consumer
registration revalidates the captured lease after clock-capable pruning before publishing into its ledger.
The same final clock snapshot must precede the current lease and every outstanding original advice deadline,
not only retain the same generation. Exact or past expiry retires that still-owned lifetime before renewal
publication or a control effect, including when a shorter renewed lease expires before an older ticket.
If buffer observation is superseded by a same-generation renewal, that unqualified buffer is dropped while
the source subscription remains owned and live. Subsequent buffers require fresh validation; actual stream
exhaustion or cancellation still retires the originating generation as capture-ended.
This does not grant private-output authority, activate coaching or prove physical audio behavior.

`CoachingGenerationCleanupTests` replaces ownership during output observation, during a clock read and
inside a throwing schedule/resume call. The old operations fail while replacement capture, advice and
controls remain usable. The prior source fails these three tests with seven recorded issues. All resources
are authored synthetic operations; no microphone, playback, device selection or public writes ran.
Additional final-clock regressions cover replacement and same-generation renewal for resume/mute/renew,
plus replacement during registration pruning. Round1 source fails these with thirteen recorded issues.
Exact/past renewal expiry and shorter-current-lease/outstanding-advice expiry regressions produce eleven
issues against Round2 before the final deadline correction. Actor timers are deliberately not delivered.
Round3 fails the forwarding-renewal regression with three issues: it mistakes the superseded observation
for stream exhaustion. The corrected regression also verifies later forwarding, actual source exhaustion
and cancellation, without activating any audio hardware.
