# Ambient sequence gap fill (#1147)

This change preserves missing time before the next admitted ambient segment reaches RightyO. It does not
change the gate's admission checks, the phone queue, F4 receive-pump eviction, or the ambient event shape.
The listener keeps each segment's sequence when forwarding it to its active pipeline. Each pipeline starts
with no last-forwarded sequence; the first accepted segment has no prefix. Privacy wishes and sequence-aware enqueues share the sequence lock, so privacy-on cannot race a prefix.
Only a successful child enqueue
advances that sequence. Final/ended events retain their existing ordered EOF path, with no trailing fill.
A new stream (or replacement child) starts fresh; refused streams and reply audio cannot reach this path.

## Format, bounds and ordering

- One missing sequence represents 100 ms of 16 kHz mono PCM16: 1,600 Int16 samples, 3,200 zero bytes.
- A gap is `sequence - lastForwardedSequence - 1`. Each fill is capped at 30 segments: 3,000 ms,
  48,000 samples, 96,000 bytes. Subtraction and capping precede multiplication, including at `Int.max`.
- HailDaemonKit has no HailCore dependency. Its host constant is pinned to `AmbientAudioFormat.chunkBytes`
  by `AmbientGapFormatTests.hostGapDurationMatchesCanonicalTerminalChunks` in the existing cross-module test target.
- Silence and its following PCM form one stdin queue item, under the existing ordered writer lock. The full
  prefix is permitted beside the configured PCM backlog budget (normally 65,536 bytes); pending storage is
  therefore bounded by that budget plus at most 96,000 bytes. The writer retains a reserve equal to its
  largest prefix for the child's lifetime, so an ordinary segment following a capped fill cannot immediately
  evict it by shrinking the budget. Oldest-whole-item eviction still applies at this bound; streams without
  holes keep the original budget. No unbounded queue, blocking write or new worker is introduced. Existing age and
  pipe-failure handling still applies. This fills holes upstream of the pipeline; it does not reconstruct
  later stdin-backlog losses.
- No-gap PCM is byte-identical. Raw, unsequenced pipeline callers retain their existing behavior.
- Each accepted prefix emits `ambient_gap_filled missing=N filled_ms=M capped=true|false`, with no session,
  endpoint, stream identity, text or audio. It counts enqueued fills, not proof that an overloaded child heard them.

## Privacy choice

Suppressed segments do not advance the last-forwarded sequence. If forwarding resumes in that same child,
its gap can include the suppressed interval, but the fill is still capped at three seconds. If no segment
was forwarded before suppression, the first later segment gets no fill. No silence is enqueued while privacy
is on, even after privacy is confirmed. When the existing privacy proof gate suppresses PCM, neither PCM nor
silence is enqueued. A park, lockdown or refusal that prevents an active pipeline from accepting a segment
cannot create silence through this path.

The existing confirmed-private in-memory PCM path for recognizing the owner's exit command is preserved.
Privacy mode is not a blanket microphone-to-child mute in the existing architecture: confirmed-private
children may hear PCM in RAM. This change does not remove that behavior or weaken its existing assertions.
Confirmed-private accepted segments update the sequence without adding silence; public forwarding after
unconfirmed suppressed segments uses the capped policy above.

## Synthetic coverage

All new captures use the existing fake RightyO and ambient test support. Gate actor returns acknowledge event
handling; the F4 dispatch park acknowledges entry and release; worker completion and EOF/reaped child tasks
acknowledge complete output. No sleep decides test ordering.

| Expectation | Test |
| --- | --- |
| Single and multiple gaps; final immediately after gap | `AmbientGapFillTests.orderedPCMAndTokenOnlyCounts` |
| Exactly 3 s, above cap, `Int.max`, and a capped fill followed by contiguous PCM | Same test, with the default 64 KiB stdin backlog |
| No-gap byte-identical control and no trailing fill after final | Same test |
| New stream after a gap, no cross-stream prefix | `AmbientGapFillTests.newStreamStartsFreshAfterAGap` |
| Privacy proof suppression; capped resume; no prefix before first forwarded PCM | `AmbientGapFillTests.privacySuppressionWritesNeitherPCMNorSilenceAndResumeIsCapped` |
| Confirmed-private exit PCM unchanged; no private silence | `AmbientGapFillTests.confirmedPrivateExitAudioDoesNotSynthesizeSilence` |
| Actual F4 eviction through gate, router, pipeline and fake stdin; equivalent phone hole | `AmbientGapFillTests.hostPumpEvictionAndPhoneHoleReachRightyoWithIdenticalSilence` |
| Refused and reply audio start no child and emit no fill | `AmbientGapFillTests.refusedAndReplyAudioNeverStartAChildOrFill` |
| Host duration matches the terminal | `AmbientGapFormatTests.hostGapDurationMatchesCanonicalTerminalChunks` |

The pump test parks dispatch, sends sequences 0 through 36 with a protected final, and proves five evictions.
Both host and phone-hole paths produce exactly 118,400 bytes: 32 original chunks plus five silent chunks.

| Existing tests touched | KEPT | TIGHTENED | WEAKENED |
| --- | --- | --- | --- |
| None; all existing test files and assertions remain unchanged | All | None | None |

## Verification status

Validation ran on the Dev Work VM, Swift 6.3.3, from a fresh GitHub clone at baseline `1ec93244`, synchronized
by a bundle containing `origin/main..HEAD`. Every run waited for the shared lane to become idle. Commands
ran through SSH with stdin closed, with at most four build workers; shared helpers were not modified.

| Final-source check | Result |
| --- | --- |
| Targeted ambient, gate, privacy-audio, receive-pump and format suites | 63 tests in 7 suites passed |
| Ambient, WebSocket, Listener, HostSession, Rightyo and Reply regression suites | 932 tests in 165 suites passed |
| Changed gap-fill and format suites, three additional runs | 7 tests in 2 suites passed in each run |
| `python3 -m unittest discover -s Tests/ReplyCLITests` | 124 tests passed; exit 0 |
| Warnings-as-errors build of package and tests | Build result 0; helper exit 0 |
| Host strict SwiftLint on all 7 changed Swift files | 0 violations |
| Host non-comment 120-column check on all 7 changed Swift files | No output |
| Production-file count using the PR-shape checker's exclusions and rename handling | 3 of 4 allowed; 8 files total |

The broad run's five known issues are intentional `withKnownIssue` timeout/cancellation expectations in the
unchanged `ReplyRecipientHandoffWaitTests`, not new failures. The warnings-as-errors build succeeded while
CLT emitted diagnostics about missing cached Apple framework PCM files; it is not described as warning-free.

Across development, the targeted command ran five times: three passes and two failures in newly added fake
startup fixtures, both corrected before the final pass. The broad command ran twice and passed both times.
The three changed-suite repetitions, CLI suite and warnings-as-errors build above ran after the final source
changes. No existing assertion was weakened. The final documentation update records those completed results.

Host work was limited to editing and strict SwiftLint/line-length checks. No host build or test, simulator,
physical-device capture, live speech/VAD proof, installed-build replacement, upload or push is part of this evidence.

A separate physical check remains deferred: create a real capture hole, verify a break in RightyO's VAD and
transcription, and exercise privacy/park/lockdown transitions on the phone. Synthetic byte equality proves
the PCM boundary, not physical microphone behavior or recognition quality.
