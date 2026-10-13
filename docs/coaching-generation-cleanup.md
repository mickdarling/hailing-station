# Coaching cleanup ownership prerequisite

Part of #269, #268 and #225. This local source correction is independent of platform output classification.

Output and clock observations may synchronously replace or renew the current qualification. The core now
checks that its captured qualification still owns the lifetime before classifying an old route/deadline
failure as a reason to suspend. Capture-start and renderer-error cleanup is scoped to the originating
generation; old errors cannot stop a replacement's capture, cancel its queued advice or clear its context.
Real failures on the current generation still suspend, and deadlines are read before and after observation.
Final ticket validation and renewal issuance also recheck exact ownership after their clock reads. Consumer
registration revalidates the captured lease after clock-capable pruning before publishing into its ledger.
This does not grant private-output authority, activate coaching or prove physical audio behavior.

`CoachingGenerationCleanupTests` replaces ownership during output observation, during a clock read and
inside a throwing schedule/resume call. The old operations fail while replacement capture, advice and
controls remain usable. The prior source fails these three tests with seven recorded issues. All resources
are authored synthetic operations; no microphone, playback, device selection or public writes ran.
Additional final-clock regressions cover replacement and same-generation renewal for resume/mute/renew,
plus replacement during registration pruning. Round1 source fails these with thirteen recorded issues.
