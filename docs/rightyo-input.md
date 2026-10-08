# Local Mac RightyO input consumer

Implementation slice [#183](https://github.com/mickdarling/hailing-station/issues/183), part of
[#136](https://github.com/mickdarling/hailing-station/issues/136), extended for enrolled speakers and
unbounded stream time by [#188](https://github.com/mickdarling/hailing-station/issues/188) items 2 and 5,
for the owner `override` event by #188 item 3, and for formed requests by #188 item 4.
This consumes the producer's version-one JSONL contract from RightyO #43/#40. The RightyO website is a test/demo rig; applications consume the tool
interface independently of that website. Every delivered prompt ends with a [reply block](#the-reply-block)
that tells the receiving session how to answer so the phone hears it (#188 item 1).

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
compact JSON prompt containing `request_id`, the complete `request`, `decision` and diarized `context`, followed on
the same line by the [reply block](#the-reply-block). It is not a shell-command interface. No target is selected from a transcript, speaker label or model
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
  final delivery step differs.
- **Prompt cap.** The daemon sanitises a dispatched prompt under the same 1,200,000-character/byte
  whole-prompt policy as the direct path (`HailHost.localPromptSanitizing`,
  [#200](https://github.com/mickdarling/hailing-station/issues/200)); the larger cap is bound only for the
  local-socket `dispatch` handoff, and phone text frames keep the default 2,000 characters / 8,192 bytes. Only
  the length cap differs: the newline rule, the whole-prompt dangerous-pattern guard (including its 20 ms
  per-rule budget, see [Formed requests](#formed-requests)), tier, binding, rate limit and lockdown give the
  direct path's outcome. The socket accepts a dispatch line of up to `2 × 1,200,000 + 4,096` bytes so JSON
  escaping cannot push a capped prompt over it; reply frames keep their existing frame cap. The client
  applies a tighter, deadline-derived prompt cap before connecting (see the time bound below) and says why
  when a prompt is larger. **Which targets this reaches:** a generic `tmux:` target receives the whole
  prompt as one tmux paste (assembled in a buffer by 400-character `set-buffer` calls, then `paste-buffer -p`,
  #304), with `request: null` (no reply ownership), exactly as the direct path delivers it. A `tmux-reply:` bridge target cannot grant a reply-binding lease, so a dispatch to it is
  refused `deliveryRefused` before any text is sent, at any size; the Codex app-server adapter is not
  registered by `haild run`. **Time bound and the commit point:** the daemon
  answers a dispatch within its 10-second socket submission deadline, and each tmux call (measured for `send-keys`,
  the same single invocation as a `set-buffer` fill) costs about 5.5 ms per 400-character chunk, so a 1 MiB prompt (about 2,600 chunks) cannot be typed in time. The client therefore
  caps a `--reply-to` prompt at `RightyoSocketDispatcher.maxPromptBytes` = 133,200 bytes, what fits in the 2 s
  left of the deadline after up to 3 s waiting for stale input to clear, the 4 s paste-acceptance wait and 1 s of
  margin, at 6 ms per chunk (333 chunks, #304), and refuses a longer prompt before connecting, with the reason
  (exit 1). The direct path keeps 1,200,000. The cap budgets one delivery: the tmux adapter types one delivery
  at a time, so concurrent dispatches queue, and a queued one can still reach the deadline.
  If the deadline (or any caller cancellation) fires, the tmux adapter's submit decision is one atomic step,
  taken right before Enter:
  - **Before the commit point:** the delivery is abandoned. No further chunk is typed and Enter is not sent.
    A delivery abandoned while queued types nothing. Text already typed stays in the pane's input line,
    unsubmitted. There is no rollback, because no key clears input in every application.
  - **Tainted pane:** if anything was typed, the tmux adapter marks that pane tainted (a failed Enter does
    too). Every later delivery to it refuses before typing, whether it was already queued or arrives later,
    because it would otherwise append to the leftover text and submit a concatenation no guard evaluated. The
    adapter's refusal reads `unsubmitted text left in pane <target>; clear it and restart haild before delivering
    again`, and a dispatch sees it as `deliveryRefused`. The taint lives in that `haild` process only. Clear the
    pane's input line by hand, then restart the daemon (`haild run`) to deliver to it again. A delivery
    abandoned before its first chunk does not taint the pane.
  - **After the commit point:** the Enter is sent and the prompt runs, even though the daemon's answer is lost.

  Either way the client gets no answer, and it reports that the outcome is unknown: the prompt may have run,
  or it may sit unsubmitted in the input line. Check the pane before retrying (exit 1). Covered by
  `LocalReplyEndpointTests.timedOutDispatchNeverPressesEnterAndARetryRefusesOnTheTaintedPane`, `TmuxDeliveryCommitTests`
  and `TmuxTaintedPaneTests`. The [reply block](#the-reply-block) (311 characters plus
  the target id) counts toward every cap.

Each admitted request sends one `{"kind":"dispatch","connection","target","binding","text"}` line and reads
one answer. The receipt is:

- `rightyo: request delivered to <target> for connection <uuid> (reply request <request-uuid>)`: the
  prompt landed and the named connection owns `<request-uuid>`. The bridge behind the target answers with
  `haild reply <target> --request <request-uuid> --say …` using the UUID it retained from the envelope, which
  reaches exactly that phone through the unchanged correlated path; the prompt's
  [reply block](#the-reply-block) asks the session only for a brief spoken answer.
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

There is no physical-device proof; the CLI tests run the real `haild rightyo <target>` against a synthetic `tmux`
listing and a test-owned socket.

## The reply block

Part of [#188](https://github.com/mickdarling/hailing-station/issues/188) item 1 (part B, PR 3 of 3). Every prompt
`haild rightyo` delivers, in both layouts, ends with one block that tells the receiving session how to answer so
the phone hears it. For the target `tmux:demo` it is, byte for byte (it begins with a space):

```
 Reply: answer briefly; it is spoken aloud. The host plays any acknowledgement itself, so send no acknowledgement of your own. If no reply bridge publishes this session's output, run haild reply tmux:demo --say '<spoken answer>' (single-quote the answer and keep it free of single quotes; single-terminal fallback only).
```

- What it asks: a short spoken answer. On a conforming programmatic bridge (a `tmux-reply:` target,
  [request-origin-routing.md](request-origin-routing.md)) the bridge parses the envelope, keeps its request UUID
  outside the model prompt, submits only `text` to the session and publishes the session's output itself through
  `haild reply <target> --request <UUID>`; the session runs no command and never sees, selects or echoes the
  UUID, which is why the block names none. On the live plain `tmux:` pane path there is no envelope and no
  bridge: the only route is the request-less `haild reply <target> --say '<spoken answer>'`, which reaches a
  phone only when the daemon runs with [`--single-terminal-reply-fallback`](single-terminal-reply-fallback.md)
  and exactly one connection selects the target; otherwise it reaches nobody (`noRecipient`), as before. The
  block tells the session to single-quote the answer and keep it free of single quotes: inside double quotes a
  shell would expand `$()`, backticks, `$VAR` and backslashes in the spoken text, and a double quote would end
  the argument. The block itself contains no double quote.
- Layout: the block is the tail of the prompt, after the compact JSON (legacy layout) or after the formed text,
  the marker and the JSON (formed layout). The session cuts the prompt at the **last** occurrence of
  ` Reply: answer briefly; `. A formed text that carries that prefix, or ends in it minus its trailing space, is
  refused as `invalidEvent` under the same literal code-unit rule as the raw-turns marker
  (`carriesReplyPrefix`), so a producer cannot put a fake instruction in front of the JSON. Raw turn text is not
  checked: it rides JSON-escaped inside a string value of the data block, where a quote is `\"` and the object
  closes with `}` before the host's block, so a prefix inside a turn never reaches the top level of the prompt;
  the last occurrence is still the host's and the body cut there still parses (tested).
- Target: `tmux:demo` stands for the real target id the command was started with (the listed id whose binding
  was pinned at startup); it appears once and is the block's only variable part. Because the block quotes it
  verbatim into a shell-shaped instruction, the id must match the allowlist `[A-Za-z0-9][A-Za-z0-9._:-]{0,95}`
  (every `kind:name` shape the adapters list, such as `tmux:demo`, `tmux-reply:main.0` and `tmux:dev.2:0`, and
  nothing a shell could read as syntax: no whitespace, quotes, `;`, `|`, `$`, slashes or non-ASCII). Anything
  else is refused at startup (`RightyoTargetError.unsafeIdentifier`; for a listed target `haild rightyo` exits 1
  with `target id must match [A-Za-z0-9][A-Za-z0-9._:-]{0,95} to be named in the reply block`, the id itself not
  echoed; an unlisted one is still refused first by the binding lookup, exit 8, as before). tmux
  session names may legally contain spaces or `;`; such a target is unusable for `haild rightyo` until it is
  renamed. The block built for the id is also matched against the default dangerous-pattern rules at startup, so
  an authorized name carrying a guarded word (`tmux:sudo`) is refused as `RightyoTargetError.guarded` (`target
  name would trigger the content guard (sudo)`) instead of turning every otherwise benign request into
  `confirmationRequired`; a daemon policy with additional custom guard patterns can still require confirmation,
  which is refused per request as before. The block is ASCII, one unbroken line, 311 characters plus the target
  id, never contains the raw-turns marker, and passes the host sanitizer and the default guard unchanged
  (`RightyoInputReplyBlockTests`).
- The block counts toward every prompt bound: the local command's 1,200,000 whole-prompt cap (arithmetic under
  [Formed requests](#formed-requests)), which with `--reply-to` is also the daemon's dispatch cap
  ([#200](https://github.com/mickdarling/hailing-station/issues/200)).
- Dry run (`--dry-run`) validates and prints receipts; it forms no prompt, so no block exists and the fixture
  dry-run output is unchanged. No receipt includes the prompt or the block.

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
record; the same rule refuses the [reply block](#the-reply-block)'s prefix ` Reply: answer briefly; ` in a formed
text; once the session advertised forming every request must carry the text, and when it did not, no
request may. The text is part of the fingerprinted event, so a changed
duplicate is refused like any other. Sequence, stream-time, correlation, duplicate and override rules are unchanged.

When `formed_request` is present the prompt body is the formed text, followed on the same line by the marker
` Raw turns (JSON, admitted record): `, then the same compact JSON as before (`request_id`, `speakers`,
`request`, `decision`, `context`), then the [reply block](#the-reply-block), so the receiving session still has
the diarized turns and can cut the JSON off at the first literal occurrence of the marker, which is the host's
under the rule above, and at the last occurrence of the block's prefix. The host cannot verify the formed text against the admitted turns
and roles: it is an unverified producer claim that may contradict them (for example by attributing a participant's
words to the owner), and the JSON block is the admitted record the session should trust when the two disagree. On
an `anonymous` session forming is still allowed, but any role the formed text names is uncheckable because the
admitted record carries none. The
layout is one line because the host sanitizer refuses line breaks; the whole prompt stays within the local
command's 1,200,000 whole-prompt cap: 16,000 formed characters, the 36-character marker, the JSON (the context's
1 MiB cap is measured with camel-case keys, so the snake-case prompt keys add at most 7 bytes per turn, 7,000 for
1,000 turns, plus a request turn of at most 16,000 bytes, a decision and two bounded identifiers, about 1,075,000
bytes at the extreme) and the reply block (311 characters plus the target id), which together stay under
the cap by about 100,000 characters and, with a 64,000-byte formed text, by about 60,000 bytes;
`RightyoInputReplyBlockTests` builds a 16,000-character, 64,000-byte text over a context one turn short of its cap
and asserts the sum in both units. Without `formed_request` the body is the compact JSON
alone, byte for byte as before, followed by the same block (`RightyoInputFormedRequestTests` asserts both exact
strings). The formed text is descriptive producer data like roles: it never selects a target or bypasses
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
`RightyoInputConsumer(streamBudgetMs:)` is an optional explicit budget and the CLI does not yet expose it. The local RightyO command and the daemon's
local-socket `dispatch` path (#200) alone use an explicit 1,200,000 character/byte whole-prompt sanitizer cap;
other CLI and mobile input retain their existing limits. Original turn text must already satisfy control/escape/newline sanitization so JSON
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

## Natural dismissal (rightyo#98)

RightyO's natural dismissal ([mickdarling/rightyo#98](https://github.com/mickdarling/rightyo/issues/98), contract in
RightyO's `docs/tool-api.md` "Natural dismissal and barge-in") is off unless RightyO's configuration has
`"dismissal": {}`. When on, `started` carries a top-level `{"dismissal": {"version": 1, "window_ms", "cooldown_ms",
"cooldown_min_confidence"}}` beside the unchanged capability set, and the producer may then emit `dismiss`:
the speaker told the assistant to stop, go away, or that it was not addressed. The consumer parses the object
only on `started`, with exactly those four keys, `version` 1 and RightyO's documented ranges; anything else,
including `null`, refuses the session as `invalidEvent`. Without it, `dismiss` is refused as before.

An admitted `dismiss` must cite an admitted transcript (a stop phrase's `dismiss` follows its own `transcript`,
before its `attention`) and carries `utterance_id`, `speech_end_ms` (not after `emitted_at_ms`), an
identifier-safe or null `speaker_id`, `role` under the same rules as a turn's, a non-empty set drawn from
`playback`, `pending_request` and `engagement` as `scope`, at most 32 unique `withdrawn_request_ids` in this
session's `session:utterance` shape, `reason` `stop-phrase` with a null `confidence` or `decision` with a
probability, and an optional `cooldown_until_ms` only with `engagement` and not before the speech end. It may
not carry a turn, decision, context or request id, and `scope`, `withdrawn_request_ids` and `cooldown_until_ms`
are refused on every other kind.

What it does: nothing is delivered and `consume` returns false; `lastDismissal` holds a receipt with the
reason, scope and two counts. A listed id this consumer already delivered stays delivered (withdrawal is
advisory; there is no rollback, as for an override). Any other listed id, including one never seen, which is how
RightyO names a request it withheld while its decision was pending, is recorded (bounded at 1,000) and a later
request with it is dropped without delivery and counted (`withdrawnDropped`), so the session keeps going. That
drop comes after the duplicate and live-provenance refusals, and a repeat of a dropped id is still a duplicate. There
is nothing host-side in flight to cancel: `consume` awaits each delivery to completion. Ambient listening
logs `ambient_dismissed` with tokens and counts only, for example `reason=stop-phrase
scope=playback+pending_request withdrawn=0 delivered=1 playback=stopped`, and keeps listening; a dismissal
never ends the stream.

Stopping playback ([#309](https://github.com/mickdarling/hailing-station/issues/309)): with `playback` in scope,
the dismissing connection stops every reply whose audio is mid-stream on it. Their remaining frames are refused
(`replyStopped`, which `haild doctor` does not count as a delivery fault) on every connection, even after the
stopping device disconnects once the stop has reached the listener, so the rest of a stopped reply never moves to another device selecting its target.
`haild reply --say` then stops and retires its renderer, and a device that advertised
`stop_playback` is sent that command to cancel its player at once and drop queued reply audio
([reply-protocol.md](reply-protocol.md)). The `playback` token says what happened: `stopped` (the device was told),
`cut` (frames refused only: an older device, or the send failed), `idle` (nothing mid-stream and no device stop),
`no_connection`, or `none` when the scope did not ask. A reply whose audio had not started yet is not stopped.
`engagement` changes nothing because the host has no engaged state beyond ambient listening; RightyO applies the
cool-down itself. The CLI prints no receipt for a `dismiss`.
An `attention` with `label: attend` and no `request_id` is admitted on any session and records nothing, so no
request can cite it. RightyO keeps the `attend` label on a turn it dismissed, withdrew, superseded or held as a stop
phrase, but forms no request for it; refusing that attention ended ambient on most model-judged dismissals.
`fixtures/rightyo/dismissal-events.jsonl` is byte-identical to RightyO's `examples/dismissal-events.jsonl` at
rightyo PR #99 head `0abd969e4c1e7bbc3fdcd793211ec90af162231c` (`--session dismissal-demo`; unchanged since
`73e4db86`). The three `dismissal-producer-*.jsonl` fixtures are streams RightyO emits at that head in its own
`tests/test_dismissal.py`, captured verbatim (`--session dismissal-test`): a model-judged "Go away." with
engagement and a cool-down, a late stop phrase withdrawing a pending request, and an enrolled session with two
decision dismissals.

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

On the #188 reply-block slice (item 1, part B, PR 3 of 3), with the same `DEVELOPER_DIR`: `prompt(speakers:target:)`
appends `RightyoInputEvent.replyBlock(target:)` to both layouts and the consumer threads its own target into it;
`validateTarget` refuses at startup an id outside the allowlist `[A-Za-z0-9][A-Za-z0-9._:-]{0,95}` or one whose
block would match a default guard rule, each with a diagnostic that never echoes the id, and a formed text carrying
the block's prefix is refused like the marker (the review rounds: the block names no request UUID, because a
conforming bridge retains and attaches its own). `RightyoInputReplyBlockTests.swift` adds four tests: the block is
one ASCII line without the marker, a `--request` or a double quote (the answer placeholder is single-quoted so a
shell expands nothing inside it), passes the sanitizer and guard, is the exact golden string for
`tmux:demo`, the pre-block part of each layout is byte-identical to the previous golden prompts, and the host's
block is the last occurrence of its prefix; the consumer names its own target (a `tmux-reply:` bridge target
through a recording dispatcher, `tmux:demo` through a real host), refuses twenty unsafe ids (the review's
`tmux:demo;touch${IFS}/tmp/pwn`, pipes, tabs, spaces, expansions, quotes, slashes, non-ASCII, a bad first character,
97 characters) and the guarded `tmux:sudo` and `tmux:delete`, and accepts six plain ids up to 96 characters; a formed
text carrying the prefix literally, with a combining mark after it, or as its own trailing end minus the space is
refused, a near miss is admitted, and a raw turn whose text carries the prefix is admitted JSON-escaped inside the
data block with the host's block still last and the body still parsing; and the whole prompt at every maximum (a
16,000-character, 64,000-byte formed text over 245 turns of 4,000 characters, one turn short of the 1 MiB context
cap, which the 246th turn trips as `capacity`) stays under 1,200,000 in characters and bytes with the sum asserted.
`RightyoInputFormedRequestTests` asserts both exact strings with the block; the other suites and the CLI dispatch
test cut the block at the last occurrence of its prefix before parsing the JSON. `scripts/verify.sh all` passed:
846 Swift tests in 129 suites (four new), 45 trace checker tests, five intent tests, 34 CLI tests, audit CLI,
strict lint and scripts; all four fixtures dry-run with unchanged receipts and unchanged SHA-256s. All input is
authored; no device, microphone, daemon or real target was used. Source marketing version is 0.1.68.

## Ambient child and pipeline (#203, library only)

`RightyoChildProcess` runs `<exe> listen --mode stdin --provenance live-microphone --session-id hail-<uuid>
--config <cfg>` through `posix_spawn`. It uses the exact absolute path with no shell, and the environment is a fixed
`PATH` plus `HOME`/`TMPDIR`. Only stdio crosses (CLOEXEC_DEFAULT). Every catchable signal is reset to default, and the
working directory is the config's directory. The executable, after symlinks, must be:

- a regular executable file
- owned by the daemon's user or root
- not group- or world-writable
- in directories, from its parent up to `/`, that are owned by the daemon's user or root and not group- or world-writable


stdin is a bounded, non-blocking writer: 64 KB or 2 s, dropping the oldest whole chunks with a gap counter. stdout
lines are capped at 1.2 MB each and 4 MB in total while untaken (bytes only, no line-count cap). Past either cap the stream ends fail-closed. stderr is
drained, and only its byte count is kept.

Stopping closes stdin, then sends SIGTERM after 3 s, then SIGKILL after 2 s. Dropping the last reference closes stdin
and sends SIGKILL. Signals go to the child's pid only, not to a process group, so a descendant that RightyO itself
forks is not killed with it. This matches the repo's other stdio children.

`RightyoAmbientPipeline` feeds the child's lines through `RightyoInputEvent.decode` and `RightyoInputConsumer`. It
hands admitted requests to a `RightyoAmbientDispatching` (`LocalDispatchRequest`). Any error ends the stream, and
nothing restarts it.

The consumer still ends a session after 4,096 events, so a long ambient stream stops there. Raising or windowing that
cap is separate work. Audio and transcript content are never logged.
