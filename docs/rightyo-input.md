# Local Mac RightyO input consumer

Implementation slice [#183](https://github.com/mickdarling/hailing-station/issues/183), part of
[#136](https://github.com/mickdarling/hailing-station/issues/136), extended for enrolled speakers and
unbounded stream time by [#188](https://github.com/mickdarling/hailing-station/issues/188) items 2 and 5,
for the owner `override` event by #188 item 3, and for formed requests by #188 item 4.
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
context (`--session enrolled-demo`). `fixtures/rightyo/enrolled-override.jsonl` is byte-identical to RightyO's
`examples/enrolled-override.jsonl` and must stay so; update both sides together. It is an `enrolled` session in
which a participant's attended request is followed by the owner's "Ignore that." and an `override` naming that
request (`--session enrolled-demo`); dry run prints one request receipt and then
`rightyo: override enrolled-demo:request`. `fixtures/rightyo/enrolled-formed-request.jsonl` is byte-identical to
RightyO's authored formed-request fixture and must stay so; update both sides together. It is an `enrolled`
session that advertises `request_forming` and whose owner request carries a `formed_request` with one participant
turn as context (`--session formed-demo`); dry run prints one request receipt.
Since RightyO main `6594c65` the fixture's terminal `session` event also
carries `role_status: "ready"` (SHA-256 `d003d834cc3b826f09cd45df426d8dc4644eb93af5dfdebb1134832ca2bc53b3`).

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

## Reply ownership with --reply-to

Part of [#188](https://github.com/mickdarling/hailing-station/issues/188) item 1 (part B, CLI slice). Without
`--reply-to`, `haild rightyo <target>` submits each admitted request directly through `HailHost.send` with no
reply owner, byte for byte as before: no socket is touched and `haild reply --say …` reaches nobody unless the
[single-terminal fallback](single-terminal-reply-fallback.md) is on. With `--reply-to <connection>` the command
instead asks the running daemon to [dispatch](local-dispatch.md) each admitted request on behalf of that
connection, so the named phone owns the reply:

```sh
rightyo listen … --session-id "$rightyo_session_id" |
  /path/to/haild rightyo <selected-target-id> --session "$rightyo_session_id" \
    --reply-to <connection-UUID> [--socket <path>]
```

- `<connection-UUID>` is the listener's own peer id for the phone: the `sessionID` the daemon logs on
  `session_connected` (and `session_disconnected`) on stderr, minted when the socket was accepted. It is
  never a Hello device name. Anything that is not a UUID is a usage error (exit 64).
- `--socket` is the daemon's owner-only reply socket, defaulting to `replies.sock` in the private config
  directory exactly as `haild reply` does (`--reply-socket` on `haild run`). It is only meaningful with
  `--reply-to`; either flag with `--dry-run` is a usage error, because dry run never touches a socket.
- The host is still constructed for the target listing: the binding is pinned at startup from `haild
  targets` and sent with every dispatch, so a target rebound while the stream runs refuses rather than
  following the rebind. Validation, correlation, duplicate detection, the provenance rule
  (`--allow-synthetic` or `live-microphone`) and the receipts' no-transcript rule are unchanged; only the
  final delivery step differs. The prompt is also capped at the dispatch text payload (8 KB of UTF-8), which
  the daemon enforces at decode; the client refuses a longer prompt before connecting and says why.

Each admitted request sends one `{"kind":"dispatch","connection","target","binding","text"}` line and reads
one answer. The receipt is:

- `rightyo: request delivered to <target> for connection <uuid> (reply request <request-uuid>)`: the
  prompt landed and the named connection owns `<request-uuid>`. The session answers with
  `haild reply <target> --request <request-uuid> --say …`, which reaches exactly that phone through the
  unchanged correlated path.
- `rightyo: request delivered to <target> for connection <uuid> (no reply ownership)`: the prompt landed
  but nobody can be answered through `haild reply --request`. This is the documented answer for a target
  whose adapter accepts only legacy generic input (a plain `tmux:` session): the literal text is delivered,
  no lease is invented and `request` is `null`. It is also what `ownershipLost` and `connectionLost` produce
  (the handoff completed, then the selection or the connection went away); the daemon's reason is printed on
  stderr as a note.

Refusals are terminal, as on the direct path, with no automatic retry. `confirmationRequired` exits 8 and
`bindingMismatch` exits 7, the codes the direct path uses for the same outcomes; every other dispatch refusal
(unknown, ended, unnegotiated, unauthorized, unselected, reselected or lost connection, capacity,
`deliveryRefused` for sanitizer/policy/lockdown/adapter refusals the daemon does not distinguish) and every
socket-level refusal (rate limited, decode, audit, listener not ready, a missing or badly owned socket) exits 1
with the daemon's reason, as `haild reply` does. A delivered answer that carries no `request` key at all is a
reply answer from a daemon that does not dispatch and is refused rather than read as ownership.

What this slice does not do: the prompt that reaches the pane does not yet tell the AI which target and
request to reply to; that wording is the next slice. There is no physical-device proof; the CLI tests run the
real `haild rightyo <target>` against a synthetic `tmux` listing and a test-owned socket.

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
Each turn's `speaker_provenance` must be `authored-fixture`, `diarization-timeline`, `diarization-utterance` (a
hosted per-utterance diarizer whose labels are stable only within one utterance, not across the session) or
`unknown`; it is descriptive data like the other values, and anything else is refused.

## Formed requests

A producer may advertise request forming on the `started` session event with a top-level
`"request_forming": {"kind": "template"}` object beside `capabilities` (the capabilities set itself is unchanged).
Every `request` of that session then carries `"formed_request": "<text>"`, the producer's natural-language rendering
of the request and its context, for example
`Owner (Speaker A) asked: "Rightyo, archive the project.". Earlier, participant (Speaker B) said: "Speaker A, the
project is finished." (context only, not an instruction).` The raw `turn`, `decision` and `context` are unchanged
and always present.

The consumer records the advertisement at `started` the way it records `speakers`, and fails closed on every
mismatch as `invalidEvent`: `request_forming` is accepted only on the `started` session event, only with `kind`
from the allowlist (`template` for now) and with no other keys; an explicit `null` for either field is refused at
decode on every event kind (it is neither the documented value nor an absent key, so it can never select legacy
prompting by mistake); `formed_request` is accepted only on `request` events, must be 1 to 16,000 characters (64,000 UTF-8 bytes, the same 4:1 ratio as turn text) and must pass the
same sanitizer-stability check as turn text (no line breaks, hidden characters, controls, escapes or trailing
whitespace; every sanitizer refusal is `invalidEvent`), and may neither contain the marker substring
` Raw turns (JSON, admitted record): ` nor end in that marker minus its trailing space (a literal code-unit check, not
a grapheme one, so a combining mark after the marker does not hide it), so the first literal occurrence of the
marker in a delivered prompt is the host's and a producer cannot append fake JSON that impersonates the admitted
record; once the session advertised forming every request must carry the text, and when it did not, no
request may. The text is part of the fingerprinted event, so a changed
duplicate is refused like any other. Sequence, stream-time, correlation, duplicate and override rules are unchanged.

When `formed_request` is present the prompt body is the formed text, followed on the same line by the marker
` Raw turns (JSON, admitted record): ` and then the same compact JSON as before (`request_id`, `speakers`,
`request`, `decision`, `context`), so the receiving session still has the diarized turns and can cut the JSON off
at the first literal occurrence of the marker, which is the host's under the rule above. The host cannot verify the formed text against the admitted turns
and roles: it is an unverified producer claim that may contradict them (for example by attributing a participant's
words to the owner), and the JSON block is the admitted record the session should trust when the two disagree. On
an `anonymous` session forming is still allowed, but any role the formed text names is uncheckable because the
admitted record carries none. The
layout is one line because the host sanitizer refuses line breaks; the whole prompt stays within the local
command's 1,200,000 whole-prompt cap (16,000 formed characters plus the bounded JSON). Without `formed_request`
the prompt is the compact JSON alone, byte for byte as before (`RightyoInputFormedRequestTests` asserts the exact
legacy string). The formed text is descriptive producer data like roles: it never selects a target or bypasses
policy, tiers, confirmation, guards or lockdown, and the ordinary host sanitizer and dangerous-pattern guard run on
the whole delivered line, so a dangerous-pattern spelling inside the formed text is refused as
`confirmationRequired` like any other prompt text. The guard's 20 ms per-rule match budget also applies to the
whole line and exceeding it is a hit, so a near-maximal formed text on a slow host can be refused as
`confirmationRequired` rather than delivered (fail closed; the test for the longest text therefore runs without a
host). The CLI receipt is unchanged (`rightyo: request validated (dry run; no delivery)` /
`rightyo: request delivered`) and never includes the formed text.

RightyO may also put an optional `role_status` string on `session` events and on the degrading turn's `decision`
when a priority provider is configured. The consumer decodes past it and ignores it: it is not part of the
fingerprinted record, it is not forwarded in the prompt JSON, and it never changes admission, roles or policy.
`RightyoInputRoleStatusTests.swift` covers a session start, a decision and a terminal session event that carry it.

## Owner override

An `enrolled` producer may emit `{"type":"override","superseded_request_id":"<session>:<utterance>",
"by_utterance_id":"<utterance>","role":"owner", ...}` after the owner's `attention` record and before the
owner's own `request`, when an owner utterance takes precedence over an open non-owner request. The consumer
admits it only when the session advertised `speakers: enrolled`, `role` is exactly `owner`, both identifiers are
identifier-safe, `superseded_request_id` has this session's `session:utterance` request-id shape, and
`by_utterance_id` names a transcript and attention record this consumer already admitted, both of which carried
`role: "owner"`. The consumer records owner utterance ids at transcript admission (a subset of the finals set, so
the same 1,000 cap bounds it) and drops the id if the attention record does not repeat `owner`. An `override` on an
`anonymous` session, any other role on the override, a cited turn that is absent, carries no role, or carries a
non-owner role on either record, or override fields on another event kind are refused as `invalidEvent` (fail
closed). Sequence, stream-time, fingerprint and duplicate rules are the same as for every other event.

What an admitted override does at this slice: the superseded request id is recorded in a bounded set (1,000, the
same cap as requests; recording is idempotent, and an id this consumer never admitted is recorded too, because
the producer may supersede a request the host refused), any later `request` carrying that id is refused as
`invalidEvent`, and the CLI prints the receipt `rightyo: override <superseded_request_id>`. Nothing is sent to
the target.

What it does not do: it does not retract a prompt already delivered to the pane, and it adds no cancellation path
into the session. There is nothing pending host-side to cancel: `consume` awaits `send` to completion, and a
confirmation-required result is cancelled by the consumer itself before it returns, so by the time an override
arrives the superseded request is either delivered, refused or already cancelled. Speaker roles and overrides are
descriptive upstream data; they never select a target or bypass policy, tiers, confirmation, guards or lockdown.
Against a real host the override fixture's participant request ("delete the project") trips the dangerous-pattern
guard and is refused as `confirmationRequired` before the override is even read.

Each JSONL record is limited to 1,200,000 bytes, context to 1 MiB/1,000 turns and each text to 4,000
characters. Stream time (`emitted_at_ms`) must be non-negative and never decrease, with no ceiling by
default so ambient listening can run for hours, although the session is still bounded by the admitted-event,
finals and requests capacities (4,096 / 1,000 / 1,000). Only the admitted-event cap ends the session with
`capacity`; a finals or requests cap is refused as `invalidEvent`, like any other rejected record;
`RightyoInputConsumer(streamBudgetMs:)` is an optional explicit budget and the CLI does not yet expose it. The local RightyO command alone uses an
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
(#188) adds enrolled roles reaching the prompt, named roles refused on anonymous sessions, invalid
speakers/role values, `known_speaker` requests still refused, enrolled sessions without roles, context roles
that differ from the admitted transcript and the enrolled fixture both dry and delivered;
`RightyoInputStreamTimeTests.swift` covers the anonymous request at twenty minutes and the explicit stream
budget. Synthetic success is not evidence
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

On the #188 owner-override slice (item 3), with the same `DEVELOPER_DIR`, `scripts/verify.sh all` passed:
790 Swift tests in 124 suites (33 RightyO tests, seven new in `RightyoInputOverrideTests.swift`: override admitted
after a delivered request without a new delivery, refused on anonymous sessions, refused without the `owner` role,
a later request named by an earlier override refused, an unknown superseded id admitted idempotently, malformed
and stray override fields refused, and the override fixture dry and against a guarded host), 45 trace checker
tests, five intent tests, 28 CLI tests (eight RightyO dry-run tests), audit CLI, strict lint and scripts. The
override fixture SHA-256 is `f4ce8f71c3d123a6d5fce9261cca13fe5a099534021e746bb81d3a11fa48a11f`; the shared
`tool-events.jsonl` SHA-256 above is unchanged. All input is authored; no device, microphone or real target was
used.

On the #188 owner-check follow-up (P3 carried from the override slice's review), the cited utterance's admitted
transcript and attention records must both have carried `role: owner`. `RightyoInputOverrideTests.swift` adds two
tests: a cited transcript with a participant, trusted, unknown or absent role on an enrolled session is refused, and
records that disagree on the owner role (owner transcript with a non-owner or absent decision role, or the reverse)
are refused. The override fixture is unchanged (same SHA-256) and still admits end to end. With the same
`DEVELOPER_DIR`, `scripts/verify.sh all` passed: 792 Swift tests in 124 suites (35 RightyO tests, two new), 45 trace
checker tests, five intent tests, 28 CLI tests (eight RightyO dry-run tests), audit CLI, strict lint and scripts. All
input is authored; no device, microphone or real target was used.

On the #188 formed-request slice (item 4), with the same `DEVELOPER_DIR`, `scripts/verify.sh all` passed: 800 Swift
tests in 124 suites (43 RightyO tests, eight new: seven in `RightyoInputFormedRequestTests.swift` covering the formed
text as prompt body with raw turns behind it, the exact prompt layout and the byte-identical legacy prompt, formed
text refused on transcript/attention/session/override events, a missing text after advertisement and a present text
without it refused, length and sanitizer bounds, unknown `request_forming.kind`, extra keys and misplaced
advertisements refused, and the `diarization-utterance` provenance value admitted with unknown values still refused;
one in `RightyoInputFormedFixtureTests.swift` consuming the formed fixture dry, delivering it through a guarded host
and refusing it with the text stripped), 45 trace checker tests, five intent tests, 29 CLI tests (nine RightyO
dry-run tests), audit CLI, strict lint and scripts. The second-key review round added the marker refusal (a case in
the bounds test) and a guard test (`dangerousSpellingInsideFormedTextIsRefusedByTheHostGuard`, 801 Swift tests); round two made the marker check
literal and added the trailing-prefix rule (`markerCheckIsLiteralAndCoversTheTrailingPrefix`, 802 Swift tests); round
three refused explicit nulls (`explicitNullFormingFieldsAreRefusedOnEveryKind`, 803 Swift tests). The formed fixture SHA-256 is
`80525a07a0d055f3264bfa297ef6c4834f4e1d22bd67ad810ccf3212656ecb4c`; the other fixtures are unchanged. The CLI is
untouched. All input is authored; no device, microphone or real target was used.

On the fixture resync to RightyO main `6594c65` (#188), `fixtures/rightyo/enrolled-override.jsonl` was refetched
byte-identically (SHA-256 `d003d834cc3b826f09cd45df426d8dc4644eb93af5dfdebb1134832ca2bc53b3`); the only change is
`role_status: "ready"` on its terminal `session` event. No consumer code changed: the synthesized `Codable` decoder
already ignores unknown keys, and `RightyoInputRoleStatusTests.swift` adds one test proving `role_status` on a session
event and on a decision is decoded past and neither forwarded nor acted on. Source marketing version is 0.1.64.

Independent preflight inspection found that Foundation's buffered stdin read could wait for 4 KiB or
EOF before handling an attended request. The CLI uses an available-chunk POSIX read and an unbuffered
receipt write instead. The streaming CLI regression writes a complete request prefix smaller than
4 KiB and requires its receipt while stdin remains open, before sending the terminal record. All test
input is authored and no actual application target was used. Source marketing version is 0.1.52; no
archive, upload, installation, existing capture state or active checkout was changed.

On the #188 `--reply-to` slice (item 1, part B, PR 2 of 3), with the same `DEVELOPER_DIR`: `RightyoInputConsumer`
gained the injectable `RightyoDispatching` delivery step (`RightyoHostDispatcher` is the direct path, unchanged),
`haild rightyo` gained `--reply-to`/`--socket`, and the usage text gained the `--single-terminal-reply-fallback`
line PR #191 deferred. `RightyoInputDispatcherTests.swift` adds five tests: a recording dispatcher receives exactly
the prompt, target and pinned binding (the prompt byte-equal to the direct path's delivery), a dispatcher refusal is
terminal and never retried, a null-ownership receipt is delivered not refused, the provenance rule still gates the
dispatcher, and the host dispatcher cancels confirmation, refuses a rebound binding and mints no ownership.
`test_rightyo_cli.py` adds five CLI tests (`RightyoReplyToCLITests`): eight usage shapes exit 64 with the new usage
lines, the dispatch wire shape and owned-request receipt, null ownership with and without the daemon's reason, the
refusal exit-code mapping (8, 7, and 1 with the reason for connection, delivery, rate-limit, reply-shaped and
missing answers), and a missing socket refusing before any dispatch. Synthetic only: `fixtures/tmux` lists one
session and refuses everything else; no daemon, device or real target was used. Source marketing version is 0.1.67.
