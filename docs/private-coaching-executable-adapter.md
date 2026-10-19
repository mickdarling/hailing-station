# Foreground executable adapter (#269 / #268 / #225)

Source-only, default-off. This slice joins the same HailCore ForegroundCoaching coordinator to
HailDaemonKit's existing owned RightyoChildProcess in the haild composition layer. HailCore has no
DaemonKit dependency. No HailHost, target/action consumer, tmux, network listener or reply publication
is created. Initialization validates the owner-private listener profile but starts no child or audio.

Explicit enable starts one child/session and installs profile before enable/qualification over the
distinct trusted fd3. Capture remains raw mono16k s16le PCM, converted without any engine/device call;
one immutable source format and bounded <=250ms source buffers. Dropped child PCM is a failure, not
an invitation to resume/relabel it. Disable/EOF/control error retires input and joins only the owned
child. Each one-second renewal floors the remaining original host validity rather than extending it.

Only an actual ordinary finalized SpeechEvent may trigger activity. Its sequence/session, bounded
utterance identifier and declared provenance are checked; synthetic-authored recognition is accepted
only with the explicit synthetic coaching capability. This does not broaden ordinary action decoder
allowlists. Duplicate final IDs and unknown action-shaped output fail closed. Transcript text, roles,
names and coaching state are never controls or qualification grants, and are not retained by the host.

Ordinary child events require an integer-valued nonnegative emitted timestamp before lifecycle or
sequence state is committed. The existing typed decoder remains responsible for shape decoding.
An authored startup/next-advice regression rejects negative, nonintegral and Boolean timestamps;
valid zero, including its integral floating representation, preserves the existing decoder behavior.

Pause derives from the same converted PCM stream and monotonic receipt time. Missing/stale capture
evidence holds. Owner-mid-answer and playback flags come only from separate trusted local observations;
missing flags hold. The exact actual final ID/current generation are sent on fd3 within the original
qualification and <2s receipt window. Every advice then enters the existing strict consumer ledger and
original immutable ticket, including final private scheduling. Renewals cannot extend admitted work.

Executable tests require HAIL_COACHING_EXECUTABLE pointing to the pinned authored-only entrypoint.
Without it they are explicitly skipped, not evidence of a round trip. With it the same foreground
orchestrator uses generated 440Hz PCM, actual Rightyo LiveProcessor endpointing/finalization, authored
advice, nonzero mock TTS PCM, and the real private session/consumer with a synthetic private player.
The second immediate turn holds under unchanged cadence; after 20s of actual silent capture/renewals
a later advice cycle is tested. Missing activity, owner answer/playback, off and original deadline
during delayed mock TTS are negative paths. Synthetic diagnostic scratch is preserved; no private data
or audio/transcript archive is introduced. Execution and independent review remain pending until
exact producer/host heads and actual logs establish them. This is not speech quality or device proof.

Full independent Round1 reviews rejected fc951c187d2f4045b792afb2abc444e96c3f1ab4 despite passing
synthetic executable evidence: supported typed owner_voice descriptions incorrectly retired coaching,
and renewal during a trusted activity callback retired the newly renewed owner. Red-before tests using
the actual owned child/public foreground coordinator reproduced both. Valid descriptive events now
remain non-authoritative; callback-superseded activity is held without changing current authority.
Actual control-channel write failure still retires the owner. Profile integer fields reject booleans
and floating scalars during inert validation. Fresh full exact-head reviews and verification are required;
old approvals or green runtime tests do not qualify this correction.
