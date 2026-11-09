# Ambient sequence gap fill (#1147)

This implementation preserves missing time before the next admitted ambient segment reaches RightyO.
It changes neither the gate nor its 40 KiB/s token bucket (409,600-byte burst), admission policy, phone queue,
F4 receive-pump eviction, or ambient event shape. Evidence below is synthetic; physical validation is deferred.

## Duration and cumulative bound

The shipping terminal splits PCM at `AmbientAudioFormat.chunkBytes` in
[`AmbientAudioStreamer.takeSegments`](../../Sources/HailCore/AmbientAudioStreamer.swift#L97-L110):
exactly 3,200 bytes per segment except the final tail. At 16 kHz mono PCM16 that is 100 ms, or 32,000 bytes/s.
The host retains that fixed size; a neighbouring frame's sender-controlled length cannot choose the fill size.
`AmbientGapFormatTests.hostGapDurationMatchesCanonicalTerminalChunks` pins the host constant to the terminal.

Each pipeline owns a fresh sequence and duration ledger. Its injectable `gapClock` returns
`ContinuousClock.Instant`, defaulting to `ContinuousClock.now`; elapsed time never uses `Date`.
Let `first` be the instant of its first successful sequence-aware write, and let:

```text
elapsed         = now - first
writtenDuration = (accepted real PCM bytes + accepted silence bytes) / 32,000 bytes/s
missing         = sequence - last - 1
available       = max(0, min(missing * 100 ms, 3 s, elapsed - writtenDuration))
fillSlices      = floor(available / 100 ms)
fillBytes       = fillSlices * 3,200
```

The implementation subtracts sequence numbers before multiplying, bounds duration to three seconds, and floors
using integer duration components. `Int.max` jumps are safe. Every successful enqueue charges both its PCM and
its prefix to the cumulative duration (31,250 ns/byte); a suppressed or refused write changes nothing.
The ledger conservatively retains charges for writer-backlog losses. It measures audio committed to the writer,
not proof of playback. A real PCM burst may already lead the clock; a fill cannot increase that lead. There is
no per-segment rounding credit: tiny positive elapsed times do not buy a whole 3,200-byte slice.

Concrete clock-driven cases:

- A frozen-clock flood of 1,000 two-byte frames, jumping 32 sequences each time, writes 2,000 real bytes,
  zero silence, and zero fill lines. With 1 ms between frames (999 ms total), it writes only nine slices
  (28,800 silence bytes), coalesced into one final line: `fills=9 missing=279 filled_ms=900 capped=9`.
- After the first 3,200 bytes, advancing one second and jumping over ten sequences fills 900 ms: the first
  real segment already consumed 100 ms. Allowing that first 100 ms to play before a one-second outage fills
  exactly 1,000 ms (32,000 bytes).
- Four immediate real chunks consume 400 ms. At 350 ms elapsed, a later gap fills zero; at 650 ms it fills
  200 ms, rounding the remaining 250 ms down. The next real chunk is then charged too.
- 128 chunks exhaust the gate's 409,600-byte burst at a frozen clock. Its next two chunks are dropped.
  After advancing 100 ms the gate admits another chunk, but the pipeline has already committed 12.8 s:
  the two-sequence gap fills zero. Gate drops receive the same cumulative bound as phone or pump holes.

Only a successful write advances `last = max(last ?? sequence, sequence)`. Direct pipeline duplicates and
reorders receive no fill and cannot move it backwards or wedge the next increasing sequence. The gate still
rejects non-increasing input and ends that stream without forwarding the rejected frame or synthesizing fill.
A fresh stream or replacement child, including reload on the same stream, starts with no prefix or old budget.
Final/ended input retains ordered EOF with no trailing silence; raw unsequenced callers retain their behavior.

## Queue, counters and logging

Silence and its following real PCM remain one queue item: neither can be reordered or evicted separately.
The pending-byte bound is `backlogBytes + largest currently queued prefix`, at most 65,536 + 96,000 bytes
with the default backlog. Removing a prefix through drain, eviction, expiry or abandonment removes its allowance.
After the last prefix leaves the queue, overload eviction is again the original PCM-only `backlogBytes` bound.
One in-flight item remains subject to the existing writer age, pipe-failure and abandonment rules.
Metadata and oldest-item removal remain O(1) amortised; there are at most 30 distinct nonzero prefix sizes.
For zero prefix the writer passes the original `Data` storage directly; it allocates no new concatenation.

Public `writtenBytes` and `droppedBytes` count **only real PCM**, including partial writes or expiry partway
through a prefixed item. Synthetic zeros are excluded. `droppedChunks` still counts evicted/expired real PCM
items, including an item with a prefix. The duration ledger separately charges accepted silence for budgeting.

`ambient_gap_filled` is coalesced per pipeline, at most once per elapsed second during input, with the remaining
aggregate flushed once on EOF/teardown. That final remainder may follow a periodic line within a second.
Its token-only fields are `fills=N missing=N filled_ms=M capped=K`: number of nonzero fills, sum of their
missing sequences, total enqueued silence milliseconds, and number reduced by either cap. Missing totals
saturate at `Int.max`. A zero-budget gap emits no line and contributes no fill totals. Repeated teardown cannot
emit the same remainder twice. Logs name no session, endpoint, device, text or audio, and count enqueues rather
than proof an overloaded child heard them. A separate log mutex supports flush; the sequence lock is used only
by sequence-aware `send`, never by `reportDuck`.

## Privacy and lockdown

When `mayHearAudio` is false, `send` writes neither PCM nor silence and advances neither sequence nor duration.
On resume, the gap may include suppressed sequences, still capped by **both** three seconds and the cumulative
wall-clock budget. If suppression preceded the first written segment, that first later segment gets no fill.
Silence may be queued in the same instant privacy turns on, just as PCM could on main; it carries no content.
There is no new sequence lock in `reportDuck` and no claim of atomic privacy-on versus enqueue ordering.

Confirmed-private children retain the existing in-memory PCM path to recognize the owner's exit command.
That PCM is real written audio and consumes duration; it advances the sequence but synthesizes no private silence.
Privacy mode is therefore not a blanket microphone-to-child mute after the child's privacy proof is confirmed.

Lockdown is not an ambient microphone gate in the current design:
[`HostSession` authorizes audio when ambient listening is configured](../../Sources/HailDaemonKit/Listener/HostSession.swift#L95-L104),
and [`ambient` routes admitted audio to the gate's sink without `HailHost.send`](../../Sources/HailDaemonKit/Listener/HostSession+Routing.swift#L74-L103).
[Lockdown instead denies delivery requests in `Policy.evaluateWithEvidence`](../../Sources/HailDaemonKit/Policy/Policy.swift#L158-L165).
This change does not invent a lockdown audio gate. A refused stream cannot reach the pipeline; privacy parks
and restores keep their existing admission and child-proof behavior.

## Synthetic traceability

Tests use the existing fake RightyO, gate, router, stdin writer and loopback listener. Clock advances choose
budgets without wall-clock sleeps. Actor returns, listener ping/pong barriers, worker synchronization and
EOF/reaped tasks acknowledge processing; bounded polling only awaits existing child I/O milestones.

| Expectation | Test in `AmbientGapFillTests` unless qualified |
| --- | --- |
| Single/multiple gaps, final after gap, 3 s cap, above cap, `Int.max`, contiguous/no-gap PCM | `orderedPCMAndTokenOnlyCounts` |
| Tiny two-byte jump flood; exact silence/log totals and zero frozen-clock amplification | `tinyJumpFloodHasCumulativeBudgetAndBoundedLogs` |
| One-second outage, including the first real chunk's duration | `realOutageFillsOnlyElapsedUnwrittenTime` |
| Ahead-of-clock burst, zero budget and whole-slice floor | `burstAheadOfClockCannotBuySilence` |
| Actual gate over-rate drop followed by bounded fill | `overRateDropCannotBuySilenceAfterABurst` |
| Direct pipeline duplicate/reorder and later progress | `duplicateAndReorderDoNotRegressOrWedgePipelineSequence` |
| Invalid write advances neither sequence nor duration | `refusedWriteDoesNotAdvanceSequenceOrConsumeBudget` |
| Gate non-increasing rejection produces no fill | `gateNonIncreasingRejectionProducesNoFill` |
| Fresh stream, no cross-stream fill | `newStreamStartsFreshAfterAGap` |
| Same-stream reload, no fill across child replacement | `reloadStartsFreshAcrossAnOpenHole` |
| Suppression, capped resume, suppression before first forwarded PCM | `privacySuppressionWritesNeitherPCMNorSilenceAndResumeIsCapped` |
| Initial PCM, open hole, privacy on through listener, suppressed frames, bounded resume through listener | `listenerPrivacyDuringHoleWritesNothingAndResumeHasBothBounds` |
| Confirmed-private exit PCM unchanged, no private silence | `confirmedPrivateExitAudioDoesNotSynthesizeSilence` |
| F4 pump eviction and equivalent phone hole, exactly 118,400 bytes | `hostPumpEvictionAndPhoneHoleReachRightyoWithIdenticalSilence` |
| Refused/reply audio starts no child and emits no fill | `refusedAndReplyAudioNeverStartAChildOrFill` |
| Ten fills per periodic line; zero-budget exclusion; EOF remainder flushed once | `logCoalescesEachSecondAndFlushesOnlyTheRemainder` |
| Drained prefix restores main's eviction and real-byte accounting | `RightyoStdinGapTests.drainedFillRestoresMainEvictionAndRealPCMCounters` |
| Evicted prefix excluded from dropped-real-byte count | `RightyoStdinGapTests.evictedPrefixDoesNotCountAsDroppedRealAudio` |
| Host constant matches shipping terminal chunks | `AmbientGapFormatTests.hostGapDurationMatchesCanonicalTerminalChunks` |

The listener privacy test holds the child's `started` proof until EOF. It forwards initial PCM, opens a hole,
switches privacy on through the real listener, and sends sequences 2, 20 and 49 while suppressed. No extra real
bytes and no fill appear. Privacy off resumes sequence 50. Exact final child bytes are initial PCM + 1,400 ms
silence + resumed PCM at 1,500 ms elapsed, or initial PCM + 3,000 ms silence + resumed PCM at 4,100 ms.
Each run records exactly 6,400 real written bytes and zero dropped real bytes: suppressed audio cannot enter
through the silence prefix or be charged as written duration.

| Existing test or support touched | KEPT | TIGHTENED | WEAKENED |
| --- | --- | --- | --- |
| `orderedPCMAndTokenOnlyCounts` | All exact child-byte, cap, final refusal and identity-free log assertions | Explicit monotonic advances provide the required budget; exact aggregate log fields replace per-gap fields | None |
| `newStreamStartsFreshAfterAGap` | Both exact child outputs and one fill line | Explicit monotonic outage before the existing gap | None |
| `privacySuppressionWritesNeitherPCMNorSilenceAndResumeIsCapped` | Every suppression, capped resume, exact child-byte and zero-drop assertion | Injected clock advances four seconds before resume | None |
| `hostPumpEvictionAndPhoneHoleReachRightyoWithIdenticalSilence` | Five pump evictions, both exact outputs, 118,400 bytes, log parity, one outstanding receive | Explicit outage on both paths; exact aggregate fields | None |
| `AmbientGapFillRig` | Existing fake capture, admission and teardown checks | Frozen injected clock, optional held startup proof, control descriptor for listener privacy | None |
| `AmbientPrivacyAudioGateTests.pipeline`, `ambientRig` | All existing test assertions, defaults and call sites | Optional injected monotonic clock; default remains real monotonic time | None |

All other existing assertions remain unchanged. New test files add coverage; no existing assertion is weakened.

## Verification status

Review-fix validation completed on the Dev Work VM, synchronized from GitHub main `72d9b44f` plus the branch
bundle. Every run waited for the shared lane to become idle and ran through blocking SSH with stdin closed.
Builds used at most four workers, including the warnings-as-errors build; shared helpers were unchanged.

| Final-source check | Result |
| --- | --- |
| Targeted gap, gate (including rate/identity), privacy-audio, receive-pump and format suites | 75 tests in 8 suites passed; build 0, test 0 |
| Changed gap-fill, privacy-audio, stdin-gap and format suites, three repetitions | 25 tests in 4 suites passed in each run; all builds/tests 0 |
| `HailDaemonKitTests\.(Ambient\|WebSocket\|Listener\|HostSession\|Rightyo\|Reply)` regression group | 946 tests in 167 suites passed; build 0, test 0; 5 known issues |
| `python3 -m unittest discover -s Tests/ReplyCLITests` | 124 tests passed; exit 0 |
| Package and test build with warnings as errors | Build 0; runner exit 0 |
| Host strict SwiftLint across all changed Swift files | 14 files, 0 violations; exit 0 |
| Host non-comment 120-column check across all changed Swift files | 14 files; no output |
| PR-shape source count using exact exclusions and rename handling | 3 of 4 allowed; 15 files total relative to main |

The broad run's five known issues are intentional timeout/cancellation expectations in the unchanged
`ReplyRecipientHandoffWaitTests`. The warnings-as-errors build passed while CLT emitted missing cached Apple
framework PCM diagnostics; this is not described as warning-free.

The first review-fix build found test compile errors in clock-injection call compatibility and a gate-helper
result assertion; both were corrected. An initial corrected targeted run passed 33 tests in 5 suites, before
the expanded 75-test targeted run and the final repetitions/regression checks above. No existing assertion
was weakened. Host lint and line-length checks cover the complete branch diff against main, including the
unchanged-in-this-batch cross-module format test.

Host work is limited to editing and strict SwiftLint/line-length checks. No host build or test, simulator,
physical-device capture, live speech/VAD proof, installed-build replacement, upload or push is part of this evidence.
A separate physical check remains deferred: create a capture hole, verify a break in RightyO's VAD/transcription,
and exercise privacy/park/lockdown transitions on the phone. Synthetic byte equality proves the PCM boundary,
not physical microphone behavior or recognition quality.
