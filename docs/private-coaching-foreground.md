# Foreground private coaching contract (source-only, #269 / #268 / #225)

This isolated integration is not shipped, activated or physically validated. The qualified native
audio baseline is ae4ff2b796c59b439700dca79d8e84dc83c19c50; Rightyo's producer baseline is
be13f29745244c43bd24492c6c12966e64ad0aa3. Neither linking nor initialization enables capture.

## Layering and channels

HailCore coordinates provider-neutral private audio, advice admission, timers and replaceable TTS.
HailDaemonKit owns the existing child process and byte transport. The foreground `haild` command will
compose them without constructing HailHost, action dispatch, tmux, the network listener or ordinary
ambient capture/reply masking. No HailCore-to-HailDaemonKit dependency is introduced.

The runtime child input remains raw mono 16 kHz s16le PCM. JSONL stdout remains untrusted data;
only bounded v1 advice enters the existing CoachingAdviceConsumer ledger. Ordinary transcript,
state and status events never grant authority. A distinct explicit `--coaching` startup capability
uses inherited fd3 for validated profile/control/measured-activity JSONL. Without that capability,
ordinary reply-started/ended fd3 behavior is unchanged. Profiles can exceed PIPE_BUF: the coaching
adapter must serialize bounded nonblocking queued writes, handle partial writes and fail closed on
overflow/error; it must not assume one atomic 4 KiB write. No transcript-JSONL second runtime is added.

Trusted local profile, explicit enable and participant awareness precede qualification/capture forwarding.
The child is inert until qualification. The foreground owner alone issues actual route-qualified leases.
Renewals occur every second, use new qualification IDs and never extend an earlier advice/TTS/playback
deadline or the original 15-minute session budget. Measured pause/owner-mid-answer/playback activity
is correlated to finalized SpeechEvents, never guessed from words. The agreed activity envelope is
`{schema_version:1,type:"coaching_activity",session_id,generation_id,utterance_id,pause_ms,
owner_mid_answer,playback}`: canonical UUID session/generation, existing bounded Turn identifier
(1..96 ASCII characters), integer pause 0..60000 and strict booleans. One pending final/activity;
receipt freshness <2000ms AND original qualification expiry; missing/stale activity holds advice.
Profiles retain the existing exact `listener_profile` envelope with `version:1`, not a parallel schema.

Synthetic executable startup uses existing `listen --mode stdin --provenance synthetic --coaching
--control-fd 3 --session-id UUID --config PATH --coaching-mock-suggestions PATH`. Agreed config uses
paired `transcriber.kind` / `diarizer.kind` of `synthetic-authored`, finite authored transcriber
`utterances` (1..32, <=1024 characters each, <=16KiB aggregate). Each actual finalized PCM utterance
consumes one script entry; exhaustion fails closed. Mock suggestions map actual Turn IDs to authored
bounded advice. No native assets or microphone helper, hosted decisions, native end-of-turn or speaker
identity extensions. This exercises the existing LiveProcessor/controller, not a transcript-input bypass.

Disable, profile mutation, awareness/permission loss, child/control/output EOF/error and private route
loss retire capture, playback, context and owned child/TTS work. Re-enable requires fresh child/session.
One render job only; no queue of advice, at most 32 contiguous PCM chunks / 96,000 bytes per advice.
Retirement keeps the slot occupied until cancellation/owned cleanup joins; noncooperative work cannot
allocate unbounded successor jobs. Every emitted chunk returns through its immutable advice ticket and
the final private audio gate. No advice text can dispatch a command, switch profiles or enable coaching.

## Software verification / deferred work

This first slice adds the coordinator and typed ports, not yet the executable child adapter or command.
Subsequent small slices must use this same coordinator for authored synthetic capture, executable mock
ASR/advice, nonzero mock TTS PCM and private synthetic playback, including repeated cycles and failures.
Native source composition will use ApplePrivateCoaching's separate fixed room-input/private-output
bindings; no test here may execute its live factory or query/select/activate devices. No audio/transcript
archive is added. Hardware, paid inference, install/signing, public push/PR/main merge and deployment
remain outside the authorized software work.

## Lifecycle review correction

Independent full Round1 reviews rejected a71e3de13f523e5ed618f3e35a3970b84c43fee7 despite its green
verification. Callback-capable advice admission could allocate overlapping render jobs; queued render
startup ignored cancellation; old completion-time cancellation could overwrite a newer job's timer.
The corrected source reserves admission before callbacks, revalidates task startup, and holds the join
slot through detached old timer cancellation. Three red-before regressions reproduced the defects;
another regression ensures noncooperative rendering cannot retain the owner and prevent deinit cleanup.
Old failed logs/probes are preserved. Fresh exact-head full independent review is required; this note is
not an approving verdict or an executable end-to-end claim.

Full Round2 rejected 1ef6b719a6ccbf520fbd8c11b168e19947ea1898 for heartbeat redelivery during
callback-capable renewal and queued provider startup after the original admitted advice deadline.
Red-before tests reproduced both. Timer ownership is now consumed before renewal; provider startup
checks immutable original advice expiry and current scope after the final clock observation, even
when the expiry callback has not run. Both previous verdicts and their diagnostics remain historical.
