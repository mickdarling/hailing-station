# Local Mac RightyO input consumer

Implementation slice [#183](https://github.com/mickdarling/hailing-station/issues/183), part of
[#136](https://github.com/mickdarling/hailing-station/issues/136), extended for enrolled speakers and
unbounded stream time by [#188](https://github.com/mickdarling/hailing-station/issues/188) items 2 and 5.
This consumes the producer's version-one JSONL contract from RightyO #43/#40. The RightyO website is a test/demo rig; applications consume the tool
interface independently of that website.

## Try the contract without a target

Build the local Mac CLI with the existing Swift/Xcode toolchain:

```sh
swift build --product haild
.build/debug/haild rightyo --session tool-demo --dry-run < fixtures/rightyo/tool-events.jsonl
```

The authored fixture has ordinary speech, an attended complete request, preceding Speaker A context,
and clean shutdown. Dry run validates the same lifecycle/request contract and prints one request
validation receipt. It does not construct a host, discover targets, capture audio, invoke models or send
input. The copied fixture is byte-identical to RightyO's `examples/tool-events.jsonl`; update both sides
when changing the shared contract. `fixtures/rightyo/enrolled-speakers.jsonl` is a Hail-authored companion:
an `enrolled` session whose owner request arrives at twenty minutes of stream time with a participant turn as
context (`--session enrolled-demo`).

## Opt into one explicitly selected local target

Use `haild targets` to identify the target and its existing policy. Allowing, confirming, locking or
revoking that target remains Hailing Station's responsibility. The receiving application must accept one
compact JSON prompt containing `request_id`, the complete `request`, `decision` and diarized `context`.
It is not a shell-command interface. No target is selected from a transcript, speaker label or model
confidence.

```sh
rightyo tool-replay --input examples/synthetic-turns.json |
  /path/to/haild rightyo <selected-target-id> --session synthetic-demo --allow-synthetic
```

This second command really submits to the explicit target if its current policy permits delivery.
Use dry run first. The synthetic flag permits invented/replayed input; ordinary dispatch otherwise
requires `live-microphone` request provenance. Provenance is descriptive data, not authentication.
For consented live capture, generate one UUID and pass it to both sides:

```sh
rightyo_session_id=$(uuidgen)
rightyo listen --config /path/to/local-config.json --mode microphone --session-id "$rightyo_session_id" --use-jev --allow-hosted |
  /path/to/haild rightyo <selected-target-id> --session "$rightyo_session_id"
```

Only explicitly starting RightyO starts microphone capture. The live command opts into hosted Jev; run it
only after the separate hosted-text consent and local credential configuration. Hail does not read,
request or forward model credentials. No raw audio is sent through this consumer.

## Ownership, bounds and refusal

The consumer pins the supplied producer session and the target's opaque binding at startup. Version,
capabilities, lifecycle, monotonic sequence and stream time are checked. Sequence gaps are allowed
because producer cancellation may discard queued plaintext. Changed duplicates, wrong sessions,
future context, partial turns, invalid timing and events following termination are refused. EOF without
a terminal session event also refuses; it does not synthesize a final request. A producer error yields
a nonzero exit even if it follows earlier successful delivery. Terminal metadata permits a bounded
five-second watchdog scheduling grace.

Only an `attend`/`system` request matching a previously admitted immutable final transcript and attention
record can submit. Transcript and attention
events alone do not send. Unknown or overlapping speakers remain context data. Prior turns must finish
before the request starts and match previously admitted finalized transcript records; context is never silently truncated. Capabilities must advertise finalized-turn
activation (or `disabled`), retained context, no partial transcript stream and `speakers` of either
`anonymous` or `enrolled`; any other speakers value is refused at start. Transcription-only streams
may advertise activation `disabled`; the consumer accepts their transcripts and refuses any request.

An `enrolled` session may put an optional `role` on each turn and decision: `owner`, `trusted`,
`participant` or `unknown`. An `anonymous` session may only omit it or say `unknown`. The role is part of
the fingerprinted turn/decision record, so a request must repeat exactly what the transcript and attention
events said. The prompt JSON carries the advertised `speakers` value and each role through unchanged so the
receiving session can see who is who. Role is descriptive producer data: it never selects a target, bypasses
policy, tiers, confirmation or lockdown, and a `known_speaker` recipient still cannot submit a request.
Owner override and formed requests are later #188 slices, not this consumer.

Each JSONL record is limited to 1,200,000 bytes, context to 1 MiB/1,000 turns and each text to 4,000
characters. Stream time (`emitted_at_ms`) must be non-negative and never decrease, with no ceiling by
default so ambient listening can run for hours; `RightyoInputConsumer(streamBudgetMs:)` is an optional
explicit budget and the CLI does not yet expose it. The local RightyO command alone uses an
explicit 1,200,000 character/byte whole-prompt sanitizer cap; other CLI and mobile input retain their
existing limits. Original turn text must already satisfy control/escape/newline sanitization so JSON
escaping cannot hide dangerous-pattern spelling. The ordinary host sanitizer, fresh policy, target
binding, guards, tiers and rate limits still apply.

A confirmation-required result is refused and its pending token is cancelled. This command never
confirms on the person's behalf. Request identities and bounded SHA-256 event fingerprints are reserved
before awaited submission. Failed, partial or uncertain writes never cause an automatic retry; an
error terminates the command. Fingerprints, not transcripts, are retained for duplicate detection.
The receipt excludes transcript content. Closing this foreground process does not roll back a completed
write; use host controls to stop consequential activity.

Hailing Station owns responses, acknowledgments, filler recordings, voice selection, application
routing and agent actions. This adds no mobile audio transport, authenticated listener, on-device model,
continuous background capture, automatic reconnect or provider-output loop. There is no physical
microphone-to-real-target proof in this slice. External contribution policy is unchanged.

## Verification

`RightyoInputConsumerTests` uses invented turns and the real guarded HailHost path with synthetic
adapters. It covers exact binding, confirmation/lock/guards, complete request and bounded context,
ordered lifecycle, sequence gaps, duplicates, cancellation, schema/session/timing refusal, legacy-cap
exceedance under the explicit local cap, synthetic opt-in, unknown/overlapping speakers and control
spelling. The shared JSONL fixture is also consumed without a target. `RightyoInputSpeakersTests.swift`
(#188) adds enrolled roles reaching the prompt, an anonymous request at twenty minutes, named roles refused
on anonymous sessions, invalid speakers/role values, `known_speaker` requests still refused, the explicit
stream budget and the enrolled fixture both dry and delivered. Synthetic success is not evidence
of live recognition accuracy, measured speech-end latency or a real application round trip.

On the completed implementation, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- `scripts/verify.sh all` passed: 744 Swift tests in 115 suites (17 RightyO tests), 45 trace checker
  tests, five intent tests, 26 CLI tests (six RightyO dry-run tests), audit CLI, strict lint and scripts.
- `scripts/verify.sh sim` passed Simulator build-for-testing; this is not UI execution or device proof.
- `python3 scripts/spec_trace.py --spec-body <issue-183-body> --tree .` passed three named expectations
  and zero problems. Presence is distinct from execution.
- `git diff --check` passed. Producer/consumer fixture SHA-256 is
  `47a16fc4383db1d141f6f8b215c621ba84750bcb6c6aa128dfc47567eb6c8311`.

On the #188 enrolled-speakers slice (items 2 and 5), with the same `DEVELOPER_DIR`, `scripts/verify.sh all`
passed: 770 Swift tests in 122 suites (24 RightyO tests, seven new), 45 trace checker tests, five intent
tests, 27 CLI tests (seven RightyO dry-run tests), audit CLI, strict lint and scripts. The shared fixture
SHA-256 above is unchanged. All input is authored; no device, microphone or real target was used.

Independent preflight inspection found that Foundation's buffered stdin read could wait for 4 KiB or
EOF before handling an attended request. The CLI uses an available-chunk POSIX read and an unbuffered
receipt write instead. The streaming CLI regression writes a complete request prefix smaller than
4 KiB and requires its receipt while stdin remains open, before sending the terminal record. All test
input is authored and no actual application target was used. Source marketing version is 0.1.52; no
archive, upload, installation, existing capture state or active checkout was changed.
