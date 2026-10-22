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
- **Ambient requests name a reply reference** ([#230](https://github.com/mickdarling/hailing-station/issues/230)).
  An ambient request that the daemon dispatches in process to a plain legacy target (such as `tmux:`; never a
  contextual bridge) has its trailing block rewritten
  (`RightyoInputEvent.referencing`) to name a host-minted reference, for `tmux:demo`:

  ```
   Reply: answer briefly; it is spoken aloud. The host plays any acknowledgement itself, so send no acknowledgement of your own. If no reply bridge publishes this session's output, run haild reply tmux:demo --request 1b4e28ba-2fa1-41d2-883f-0016d3cca427 --say '<spoken answer>' (single-quote the answer and keep it free of single quotes; the request reference sends it to the device that asked).
  ```

  The UUID is lowercase, freshly minted for each request and the block's only other variable part. The block stays
  ASCII, one line and free of double quotes, and it passes the sanitizer and default guard
  (`AmbientWiringReplyBlockTests`). It ends in fixed text. Only an exact trailing request-less block for the
  target is rewritten. A prompt that the longer block would push past the 1,200,000-byte dispatch cap keeps its
  request-less block and gets no reference. `haild rightyo` (direct or `--reply-to`) still delivers the
  request-less block above. Routing and the doctrine change are in
  [request-origin-routing.md](request-origin-routing.md#ambient-reply-references-on-plain-tmux-targets-230).

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
nothing restarts it. The daemon's dispatcher mints each request's reply reference
([#230](#the-reply-block)), so the reply reaches the streaming device even when another device selects the target.

The consumer still ends a session after 4,096 events, so a long ambient stream stops there. Raising or windowing that
cap is separate work. Audio and transcript content are never logged.

### Ambient take-over (#366)

The daemon has one ambient stream, and the most recent device to start one holds it. When a second device's first
segment of a new stream passes every gate check (a negotiated session of this daemon whose authorizer admits
audio, the gate's target selected, the stream shape, a new id at sequence 0, and the daemon-wide rate), the gate
ends the current stream as `superseded` and opens the new one. The router retires the old stream's RightyO child
(EOF, then the usual stop) and starts a fresh child for the new stream. RightyO session state is not carried over.
A request the old child already admitted is still dispatched on behalf of the old device, so its reply reference
keeps reaching that device until it expires, while the new stream's requests and replies belong to the new device.

The old device's next segment is refused with `ambient moved to <class>` (see
[reply-protocol.md](reply-protocol.md#ambient-take-over-366)), and the new device, if it advertised
`ambient_takeover`, is sent `ambient_moved_here`. A refused start disturbs nothing. Another device can never
continue or restart the owner's own stream id. The gate remembers the last 64 take-overs, and forgets a device's
entries when it disconnects. Nothing is taken over across hosts: each daemon has its own gate and target.

A device's automatic restart after its stream failed (#373) marks its first segment `resume`. Such a start never
takes over. If another device started listening during the restart's backoff, the start is refused with that
device's `ambient moved to <class>`, before it costs any rate budget or uses up its stream id. So the device someone
moved to keeps listening. Only a start someone asked for (the toggle or "Listen here") takes over.

When the owner selects away and back while a stream is open (#636, PR #705), the host ends that stream at its next
segment with `not_allowed: ambient stopped: the destination was selected again`. The device treats this as transient
and opens a fresh stream on the new selection after its recovery backoff (1 s, then 3 s, then 10 s). Each such end
spends one of the device's three automatic restarts, and the count resets only once 120 s pass after the latest
restart, so a fourth within that time turns listening off ("Gave up after 3 restarts."). It fails closed.

Fast swaps (phone, pad, phone, pad) can leave retired children still stopping when the next start arrives. When
every child slot is taken (`maxLiveChildren`, or `maxRuns`), the router forces the oldest retired child out
before spawning the new one: EOF, SIGTERM after 0.5 s, SIGKILL after 0.5 s more, then up to 2 s to settle (about
3 s at most), plus up to 1 s for its run to return. It logs `ambient_retired_forced`. A dispatch that child had
not yet made is lost, which is acceptable because the speaker has moved device. Its run is never cancelled. Until
that start has its child, later gate events wait behind it in order, then are handled as usual. With nothing
waiting, events are handled at once, as before. The queue stays small whatever a client sends. Only the newest
start is kept: a newer start drops an older queued start with its audio and end. That newest start keeps at most
64 segments (oldest dropped). Only the newest start ever forces a child out or spawns, and a start the gate has
already ended (other than on its final segment) is skipped. A superseded child is forced out before one whose
stream ended normally, so a device's last utterance is not cut off. A start that still finds no slot (runs stuck dispatching) is refused as busy, as before. Shutdown lets a
forced stop in progress finish, then stops and drains every child. A take-over also drops the old stream from
its device's latest-stream record, so a forced-out child's failure is not reported to that device as a stop.

### Named guests (#434, rightyo#171)

When RightyO's `started` carries a top-level `speaker_names` object with a positive integer `max_scalars` (anything
else, such as `false` or `{}`, leaves naming off),
a `transcript` may carry a top-level `speaker_name` beside its `turn`: the display name of the enrolled non-owner
RightyO bound that voice to. It sits outside the turn, so turn fingerprints and the consumer's correlation are
unchanged, and both fields stay raw JSON, so a malformed value never refuses the stream. Only the overheard relay
reads them. A name is kept only when the session advertised `speaker_names` and the transcript's role is not
`owner`, and it is shown only if the turn is not reported as the owner's and its attention decision does not say
`owner` either (disagreeing records are uncertain, so unnamed). It must not be "You" in any case, and must pass `AmbientOverheard.name` (so
ZWJ emoji sequences and ZWNJ names fall back), the sanitizer's hidden-character rule, and contain at least one
visible letter, number, punctuation mark or symbol; anything else is reported unnamed, as "Someone". The name goes
only to the device that heard the turn, only if it advertised `ambient_overheard_names`
([reply-protocol.md](reply-protocol.md#overheard-remarks-398)), and is never logged.

### Owner voice status and input route (#490, rightyo#164, rightyo#172)

haild opts every RightyO child in with `RIGHTYO_OWNER_VOICE_EVENTS=1`, and passes `RIGHTYO_INPUT_ROUTE=<kind>` when the
device has named its input route with `ambient_input` (a route kind RightyO does not list goes as `other`). Only
`RIGHTYO_`-prefixed variables are added; PATH, HOME and TMPDIR stay as before. The device sends its route before its
stream's first segment, so it is normally known when the child starts; a route that arrives after the child started
is passed on that connection's next start or reload, and is logged at once as `ambient_input route=<kind>`.

When `started` carries `owner_voice` as an object with a numeric `threshold_s`, RightyO may emit
`{"type": "owner_voice", "state": "unrecognized" | "recognized"}`. The consumer validates its shape (a known `state`
and nothing a turn, decision or request carries; `owner_voice` itself only on `started`), and the owner-voice relay
reports `unrecognized` at most once and `recognized` at most once, only after it. An unadvertised, out-of-order or
replayed status is ignored, never refused. The status goes as `owner_voice` only to the device whose stream it is, only
if it advertised `owner_voice_status`, and is logged as `ambient_owner_voice state=<state> device=<outcome>` (`sent`,
`unsupported`, `failed` or `no_connection`): tokens only.

### A reply that asked a question (rightyo#199)
With reply control on, `haild` writes `{"reply":"started"}` and `{"reply":"ended"}` to the child's control descriptor when the phone reports that reply playback started or drained. When the latest final reply text it delivered ends with "?", the end says so: `{"reply":"ended","asked":true}`. RightyO then lets an answer-shaped follow-up ("yes", "go ahead") through its cue rule until the next reply starts. The phone plays replies in order and reports one end when its queue drains, so the flag describes the reply just heard. A RightyO without rightyo#211 skips that line, and attends as before. The `ambient_reply` log line carries `asked=true|false`, never the text.

### Media mode (#551, rightyo#195)

While the owner watches TV or videos, a show's dialogue can sound like a request. When the owner says a media phrase as a whole turn, `haild` turns media mode on for that device's stream. Examples are "Jarvis, media mode" and "I'm going to watch TV" (`VoiceMedia`). The phrases follow the same rules as the spoken mute (#404): an optional greeting and name, no other words, and on an enrolled session only the owner's turn counts. The phrase is never typed to the agent.

`haild` writes `{"media":true}` to the child's control descriptor (`--control-fd`, so reply control must be on). RightyO then attends only when the turn names the assistant and, with speaker roles, is in the owner's voice. It refuses every follow-up. A child started or reloaded while the mode is on is told at once.

The mode ends in three ways, each logged as `ambient_media on=… reason=… reported=…`:

- A spoken off phrase. While the mode is on, this needs the name, for example "Jarvis, done watching".
- After `mediaTimeout`, three hours by default.
- When the connection ends.

When the ack library has clips in the reserved `confirm-media-on/` and `confirm-media-off/` folders, the change is confirmed on the device. A RightyO without rightyo#195 skips the control line and attends as before.

The app control and the "Media mode" indicator on the ambient card are a later slice.

### Privacy mode (internally duck) (#735)

Privacy mode keeps nothing. While it is on, RightyO sends no transcript, attention or request, keeps nothing in memory and retains no audio (rightyo S-1). Its ASR runs in RAM only to hear the way back in. The wire and the code still say `duck`: the control line is `{"duck":true}`, the capability is `started.duck`, the device frame is `duck_mode`, and the log events are `ambient_duck*`.

#### Entry: intentional standalone commands (`PrivacyEntry`)

`haild` matches the entry deterministically and locally, with no model. Mick: "It needs to be really intentional"; "If I say them, they can count for privacy. If other people say them, they should not count."

A command counts only when it is the whole turn. It may follow a greeting and an assistant name ("Hey Jarvis, privacy mode."), or a single word set off by a comma ("Computer, stop recording."). Case and punctuation don't matter. Only these may surround it:

- **before:** fillers and discourse words, each with or without a comma: "ok", "okay", "um", "uh", "so", "please", "hey", "now", "just", "alright", "wait", "no", "well", "actually", "yeah", "yes", "listen", "fine", "oh", "right", "look", "and", "anyway", "sure", "hmm". A polite "can / could / would / will you" may also come first. Negations ("don't", "never") are never fillers;
- **after:** "please", "now", "thanks", "thank you", "right now", "for now", "for a minute / bit / while / sec / second", and the assistant's name.

The commands are:

- "privacy mode", "privacy mode on", "turn on", "enter", "start", "enable", "activate" or "switch to" privacy mode, and "put yourself in privacy mode";
- "go private";
- "stop recording", "stop listening" and "stop recordings", with up to two determiners in between ("stop the recording", "stop all the recordings");
- "stop listening to me", and "stop recording everything".

These don't count:

- a command mid-sentence, code dictation included ("we should go private", "set the flag to stop listening on 443");
- a question or mention ("what is privacy mode?"). A turn ending in "?" counts only in the polite form ("Can you stop recording?") or as a verb command of three words or fewer, which ASR may punctuate as a question ("Jarvis, go private?"). "Privacy mode?" stays a question;
- a leaving phrase ("privacy mode off", "end privacy mode").

They reach the agent as ordinary requests.

A standalone negated command ("don't stop recording", "Jarvis, do not go private") changes nothing and plays `confirm-still-recording/` ("Still recording."). A name said alone is no command, so a lone "Jarvis," followed by the command in the next turn enters on the second turn.

**Partial commands.** An owner *request* (a turn RightyO addressed to the assistant) that starts with an action command but goes on ("stop recording, my wife is here", "go private on github") is held back from the agent. It plays `confirm-privacy-hint/` ("To go private, say 'stop recording' on its own."), logged `hint`.

- Only actions count: "stop recording …", "stop listening …" and "go private …". A turn that starts with "privacy mode" and goes on is a mention ("privacy mode needs a longer timeout") and reaches the agent.
- A transcript that was never addressed to the assistant gets no hint and is not held, so talk to someone else ("go private with the beta") is untouched.
- A guest's partial turn is never held.

`AmbientPrivacyCorpusTests` holds the table:

- over 2,000 intentional forms;
- negations;
- partial commands;
- more than 150 turns that must not count.

A matching turn is checked in transcripts, so entry never waits for a request to be formed, and in requests. The request that carried it is always held back from the agent; the request path applies the same owner rule on its own. Only a live-microphone turn counts, and the assistant's own words heard back (the echo filter) never count.

**Owner only.** Mick: "only my registered voice should be able to turn privacy mode on." Entry has the same trust bar as the exit. It needs:

- an enrolled session;
- a turn RightyO attributed to the owner, in the transcript and, on the request path, in the attention record too;
- that attribution coming from a live voiceprint, as the transcript's top-level `"role_source": "voiceprint"` says. An inferred or label-configured owner does not qualify.

How a refusal sounds depends on who spoke:

- **The owner role without a live voiceprint** (label-only or inferred) is refused audibly, so the owner never believes privacy is on when it is not. It plays `confirm-privacy-refused/` ("I couldn't turn on privacy."), or `confirm-not-sent/` until that clip is recorded, and is logged `refused=unverified_owner`.
- **Anyone else** (a guest, a TV, an unlabelled turn, an anonymous session) is refused silently, logged `refused=not_owner`.

Either way the turn is held back from the agent and changes nothing, media mode included. Until RightyO sends `role_source`, every entry is refused: the host fails closed, audibly for the owner.

#### Fail closed against an older RightyO

`haild` writes `{"duck":true}` only to a child whose `started` advertised `duck` with an integer `version` of 2 or higher ("keeps nothing"). A v1 child still transcribes while ducked, and an older one would skip the line, so neither is written one. Privacy is not entered. The log shows `ambient_duck … reported=0 refused=unsupported` and `ambient_duck_confirmed on=true refused=unsupported_version`, and the speaker hears `confirm-not-sent/`. Without a control descriptor the result is the same.

RightyO does not advertise v2 for a coaching listener, a tool replay, or a session that uses a hosted transcriber or diarizer, since the private audio would still leave the host. These are refused the same way; the host cannot tell which applies.

A child that cannot keep privacy never ends it. Only the owner's voice exit does (Mick, round 4). If a child starts while the host is private without advertising v2 (an older RightyO after a reload, or a new stream):

- privacy stays on: no `setDuck(false)`, no off notice, no "Recording again.";
- the child is refused: its run ends, so nothing records;
- `ambient_privacy child=unsupported_version kept=true` is logged;
- `confirm-privacy-unavailable/` ("I can't listen privately right now.") plays, at most once per connection.

An entry while a child is between spawn and `started` is taken by that child. It is written `{"duck":true}` when it starts with v2, or refused then in the same way.

#### While private

Nothing reaches the agent. RightyO v2 sends no request, and one already in flight when privacy began is dropped. Words that still arrive before the child has read the control line reach only the consumer, which keeps hashes and holds every request. A `transcript`, `attention` or `request` reaches no relay then: nothing is shown as heard or overheard, and nothing is acknowledged.

Only RightyO's content-free events act. Both are admitted only on a session that advertised v2:

- **Exit.** `{"type": "privacy", "action": "exit"}`, with the usual `schema_version`, `session_id`, `sequence` and `emitted_at_ms` envelope, after the enrolled owner's voice said "<name>, I'm back", "<name>, start listening" or "<name>, privacy off". `haild` turns privacy off, tells the device, and plays `confirm-privacy-off/`.
  - The host does not re-check the owner: it has no words to check. RightyO's check is the gate: it matches the name and the exit phrase locally, for the named, enrolled owner's voice, never on an inferred label. A forged exit would need a compromised local RightyO, which could already transcribe anyway.
  - An exit while privacy is off (a stale one released after the off, or a duplicate) is ignored: no `setDuck`, no device notice and no clip. It is logged as `ambient_privacy exit=ignored state=off`.
- **Status.** `{"type": "privacy", "action": "status"}`, for "what mode am I in", "are you recording" or "are you listening", from any speaker. It plays `confirm-privacy-status/` while private, and nothing otherwise (S-3 answers every mode).

"Stop" does nothing while private, and RightyO sends no `dismiss` then. A `dismiss` that cites no admitted transcript ends the stream, as it always has. The decoder ignores keys it does not know. A `privacy` event carrying any content field the decoder knows (`turn`, `utterance_id`, `reason`, …), another `action`, or arriving on a session without v2, ends the stream. Only RightyO's `exit` (and, until it is removed, the auto-end below) or the connection's end leaves privacy. No stop-like phrase does, even one that slips through.

#### Playback, lifetime and media mode

When privacy is taken, a reply playing on the connection is stopped first, through the owner's stop path (`stop_playback` to a device that takes it; `playback=` in the log). Only then does the clip play. "Still on" (an entry while already private) silences in the same way, since nothing should be playing while private. A refused entry leaves playback alone. Replies the agent sends later, while private, are not yet dropped; that is a follow-up (S-2c).

Privacy ends on RightyO's exit, after `ambient.duckTimeout` in `host.json` (whole seconds, 60 to 14400; an hour by default, `--ambient-duck-timeout`), or when the connection ends. Mick has decided the only way out should be the owner's voice exit (and later the app switch, S-6). Removing the auto-end touches `WebSocketListener.swift`, `ConnectionProbeDaemon.swift` and `scripts/host.sh`, beyond this change's four files, so it follows separately. An entry while already private answers "still on" with `confirm-privacy-on/` and re-arms the timeout. Entering privacy leaves media mode, and entering media mode leaves privacy. A device that advertised `duck_mode` is told each change (`ambient_duck_device`), and sees "on" only once a child took it.

#### Clips

These reserved folders play nothing until Mick records them:

| Folder | Words | When |
| --- | --- | --- |
| `confirm-privacy-on/` | "Privacy on. I'm only listening for my name." | entry, and re-entry while on (so worded as a status) |
| `confirm-privacy-off/` | "Recording again." | RightyO's exit |
| `confirm-privacy-unavailable/` | "I can't listen privately right now." | a child that cannot keep privacy was refused (once per connection) |
| `confirm-privacy-status/` | "Privacy on. I'm only listening for my name." | RightyO's status event while private |
| `confirm-still-recording/` | "Still recording." | a negated entry |
| `confirm-not-sent/` | "Nothing was sent." | an entry no child could take |
| `confirm-privacy-refused/` | "I couldn't turn on privacy." | the owner role's entry without a live voiceprint (falls back to `confirm-not-sent/`) |
| `confirm-privacy-hint/` | "To go private, say 'stop recording' on its own." | an owner turn that starts with a command and goes on |

They replace H-2's `confirm-duck-on/` and `confirm-duck-off/`. H-2's named duck phrases ("Jarvis, duck mode", "let me think out loud", "done thinking") are gone and reach the agent as ordinary requests.

The microphone hears these clips, so none may be or start with an entry command ("privacy mode", "stop listening", "go private", "stop recording"), and none may contain an exit phrase ("I'm back", "start listening", "privacy off"). The hint names "stop recording" only mid-sentence, which never counts; `AmbientPrivacyCorpusTests` checks every clip's words. The host's echo filter (`hostPhrases.isEcho`) covers a clip only partly:

- the clip has a `<clip>.txt` with its words;
- its delivery reported `sent`;
- the heard turn repeats those words exactly, within the hold after the audio.

A clip heard merged with other speech, or without its text, is not caught, and RightyO's exit matcher never sees the host's echo filter at all.

### Spoken notes to configured destinations (#552)

The owner can say "Jarvis, add to Notes: buy oat milk" or "Jarvis, put this in Notes …" as a whole turn on an enrolled session. `haild` then saves the words, as said, wherever the owner configured that destination. The note is never typed to the agent.

- **Destinations** come from `--ambient-destinations <file>` (`"destinations"` in `host.json`'s `ambient` block). Each spoken name maps to exactly one handler and its target, for example:

  ```json
  {"Notes": {"markdown": "/Users/me/Obsidian/main/Inbox.md"},
   "Groceries": {"shortcut": "Hail to Groceries"}}
  ```

  - Handlers are haild's own code, reviewed and shipped like the rest of it. The file only picks one per name and gives its target. A new kind of destination (Apple Notes, Word, …) is a new handler in a PR, not a setting.
  - The file is read when haild starts. A new or changed file takes effect after `scripts/host.sh restart`.
  - A missing file leaves spoken notes off (`ambient_destinations missing`).
  - A malformed file is logged (`ambient_destinations error=…`) and also leaves them off. It never stops the daemon.
  - The file decides where a spoken name's words go, so it is trusted only as the RightyO executable is. After symlinks it must be a regular file of at most 64 KB, owned by you or root, and not group- or world-writable. The same goes for every directory above it. Otherwise it is `error=unsafe` and off.
  - Only names in the file are reachable.
  - Every destination only saves. Anything that sends waits for #89.
- **Who:** only the enrolled owner's turn counts. On an anonymous session, or for anyone else, the phrase goes to the agent as before. A destination name followed by `.` or `/` ("notes.md") also stays a request.
- **Handlers:**
  - `markdown`: the target is an absolute path ending `.md`, with no `.`, `..` or empty components. Each note is appended as one list item, `- yyyy-MM-dd HH:mm <words>` in local time, with line breaks in the words made spaces. If the file doesn't end in a newline, one is added first. An absent file is created `0600`, but its directory must already exist. The last path component is never followed as a symlink. Only a regular file you own, with a single hard link, is written (`open_failed` or `not_a_file` otherwise), so a file someone else made or linked in a shared folder never gets the words. A failed write is cut back to the earlier length. No macOS permission prompt is involved, as long as the file isn't in a protected folder such as `~/Documents`.
  - `shortcut`: `/usr/bin/shortcuts run <shortcut> --input-path <file>`, with no shell and a fixed `PATH` plus `HOME` and `TMPDIR`, never the rest of haild's environment. The words go only into a `0600` temporary file, which is removed afterwards. It times out after 30 s (SIGTERM, then SIGKILL). If haild exits during a run, the file is left behind and is removed at the next start once it is five minutes old. The Shortcut itself has to be built by hand in the Shortcuts app.
- **Confirmation:** only after the handler finishes does the device hear a clip from `confirm-saved/` ("Saved."), or from `confirm-not-saved/` when it failed.
- **Log:** `ambient_voice_note destination=… outcome=… bytes=… confirm=…`, with tokens and a byte count only, never the words.

Setup is the owner's: write the destinations file (mode `0600`), point `host.json` at it, and add the two clip folders.

Separately, an ambient request the owner addressed to a voice route that sent nothing plays a clip from the
reserved `confirm-not-sent/` folder ("Nothing was sent."), after the device's refusal line (#636, see
`docs/voice-routing.md`).
