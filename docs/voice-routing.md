# Voice routing

[#636](https://github.com/mickdarling/hailing-station/issues/636) lets the owner name the session a request goes to
("Voice Work, …", "Deck, …") or pick it in the app. The reply comes back labelled with the session that answered.
It is step 1 of [#225](https://github.com/mickdarling/hailing-station/issues/225). Several sessions listening at
once is out of scope.

## Status

| Slice | State |
| --- | --- |
| 1. Allow-list file and the opening-name parser (`VoiceRoutes`) | Merged (#646). Not deployed. |
| 2. Host listing: route names, offline routes and `--voice-routes` | Merged (#678, #686). Not deployed: `host.sh` does not pass the flag yet (slice 8). |
| 3. Tap-to-talk routing and reply return (route group) | Merged (#688). Not deployed. |
| 4a. Ambient dispatch may address a covered route (host authority) | Merged (#691). Not deployed. |
| 4b. Ambient routing by the owner's own turn (RightyO consumer) | In review. Not deployed; needs route names in RightyO `addressing.names`. |
| 5–8. Refusals, spoken and visual labels (7a model merged in #666), app selector | Proposed; see the [plan on #636](https://github.com/mickdarling/hailing-station/issues/636). |

Nothing below changes the running daemon or installed builds until a later slice wires it in and it is deployed.

## The allow-list: `routes.json`

The owner writes one file on the Mac, by hand. The daemon only reads it and never writes, creates or rewrites it.
Routing is off when haild runs without `--voice-routes`. With the flag, a missing file refuses startup (#686).

```json
{"version": 1, "default": "tmux:hailing-test", "routes": [
  {"target": "tmux:hailing-test", "name": "Hailing Scratch", "aliases": ["Scratch"]},
  {"target": "tmux:voice-work", "name": "Voice Work", "aliases": ["Voice Walk"]},
  {"target": "tmux:deck", "name": "Deck"}]}
```

The example is synthetic.

- **The file only names targets.** It grants nothing. A route still needs its own target policy entry and binding
  in `policy.json`. A route without them will be treated as offline, never trusted. No target is discovered from a
  listing or added automatically.
- **Strict.** `version` is 1. No other keys are allowed at the top level or in a route. There are 1 to 16 routes.
  Each `target` is an exact `kind:name` id that `haild rightyo` accepts (`RightyoInputConsumer.validateTarget`).
  Targets are unique, and `default` must be one of them.
- **Names.** A `name` and each of up to eight `aliases` is 1–48 characters with no control characters. It must also
  be sayable as the parser hears it: one to three of its words (runs of letters, digits and apostrophes), separated
  by whitespace alone, each wholly ASCII letters, digits and apostrophes, the first not a greeting. So "Voice-Work",
  "One-Two-Three-Four", "Okay Deck", "Café" and "東京 Deck" are refused. Names are compared as `RightyoAddressing.key` (case-folded ASCII letters and digits), so "Voice Work"
  and "voicework" are the same spelling. Every spelling must be unique across routes and must not be a greeting
  ("hey", "ok", "okay").
- **Trust.** The file decides where the owner's spoken requests go, so it is trusted exactly as `destinations.json`
  is. After symlinks it must be a regular file of at most 64 KB, owned by this user or root and not group- or
  world-writable, in directories up to `/` that no other user can write either.

## The opening-name parser

`VoiceRoutes.match(_:names:)` reads the start of a request.

1. It skips an optional greeting ("hey", "ok").
2. The request must then open with a route's name or alias of up to three words, longest first, followed by `,`,
   `:` or `-` and then a space or the end. So "Deck: add a slide" and "Voice Work, check the build" route. "Deck is
   still stopped", "Deck-building is next" and "deck.md needs work" do not: without the mark a name is just a word.
   A name's words never span a mark either: with routes "Voice" and "Voice Work", "Voice, Work, status" addresses
   Voice, and only "Voice Work, status" addresses Voice Work.
3. A request that opens with an addressing name from RightyO's advertised names (e.g. "Jarvis") is addressed to
   that name, and nothing after it re-routes it. "Jarvis, Deck, add a slide" goes where "Jarvis" goes, and
   "Jarvis, deck is stopped" stays a request. A route may still use an addressing name as its own spelling, because
   route spellings are tried first.
4. The outcome is one of:
   - `routed(route, text)`: the request goes to that route. `text` holds the words after the mark, as said. The
     input paths are expected to send the whole request as heard, so the session sees how it was addressed.
   - `nothingToSay(route)`: the name alone ("Deck", "Deck?", "Deck:"), so there is nothing to send.
   - `unclear`: the opening words, followed directly by a comma, are within one edit per four letters of a spelling
     of at least five letters ("Voice Wok, …"). Nothing is sent: a misheard name must never land in the wrong
     session or fall back silently. A short name's misrecognitions ("Duck" for "Deck") belong in its `aliases`.
     An addressing name is never unclear.
   - `unaddressed`: everything else, including a name in mid-sentence ("Can Voice Work look at this?"). The request
     goes unchanged to the target already chosen.

The parser decides nothing about who is speaking. The owner-only rule is applied by the input path that calls it
(slices 3 and 4).

Verification is synthetic only (`VoiceRoutesTests`, `VoiceRoutesFileTests`).

## The device's target list

With `haild run --personal-terminal --voice-routes <absolute path>`, the daemon loads `routes.json` at startup and
logs `voice_routes` with the route count. A file that is missing or fails to load refuses startup and logs
`voice_routes error=…`. Without that, routing would be silently off and a request naming a session would go to whichever
target was already chosen.

The `targets` list a device receives changes in two ways:

- A listed, allowed and bound target that is a route shows the route's `name` instead of its session name. Its id
  is unchanged.
- A route that is not listed, not allowed by policy or no longer at its allowed binding is still listed, with its
  name, as `alive: false`. The device can show it as offline instead of hiding it. `select` reads the policy-filtered
  listing without names, so an offline route cannot be selected (`not_allowed`). The routes file adds no target the
  policy does not allow.

Targets that are not routes are listed exactly as before.

**What the listing exposes.** The personal-terminal listener has no authentication (#7, #21). Any peer that
completes its handshake receives the target list, so with `--voice-routes` it sees every configured route's id and
name, offline routes and routes the policy does not allow included. Before routes, it saw only allowed targets.
Keep the listener on a trusted network, as for everything else it carries.

The device's remembered selection matches on id and name, so renaming a target forgets it once and the owner picks
it again.

Verification is synthetic only (`VoiceRouteListingTests`, `VoiceRouteOptionsTests`).

## Tap-to-talk routing and the reply (route group)

While a device selects one of the owner's routes, a final text frame it sends to that route can name another
route: "Deck, add a slide on pricing".

- **Before authorization.** `HostSession.voiceRoute` runs before the authorizer and `admit`. Only the frame's
  target changes; the text, including the name, goes as heard. So the authorizer, the paste gate, the sanitizer,
  input shape, policy, tier and binding all see the frame that is delivered, exactly as for any other input.
- **Owner.** Tap-to-talk has no speaker identity, so the device holding the connection counts as the owner, as it
  does for `select`. Speaker-checked routing is the ambient path's (slice 4).
- **One request.** The device keeps its selection and selection generation. Requests that name no route still go
  to the selected target.
- **Only host-routed frames.** A device cannot address another route itself. A frame whose target is not the
  selected one is refused as before (`select the destination before speaking`), unless the host routed that very
  frame. The task-local `HostSession.voiceRouted` (from, to) is bound only for that delivery, and admits the input
  only while the selection is still exactly `from`.
- **Lockdown and pastes.** During lockdown nothing is routed, so a named request meets the lockdown refusal as it
  is. A name with nothing spoken after it routes when a paste goes with it (#608), and the routed target's own
  paste gate then decides. A paste routed to an agent route is delivered there; one routed to a tmux pane is refused.
- **Authorizer first.** The authorizer judges the frame before any route answer, so a frame it would refuse gets
  `unauthorized`, never a route's liveness. The selected route's own name alone goes to it, as before routing. A
  policy that cannot be read refuses with "the target list is unavailable", not "offline". A tap route is bound to
  the selection generation it was made on.
- **Nothing falls back.** Each of these sends nothing to any target and keeps the connection open:

  | Case | Error frame |
  | --- | --- |
  | Route offline (not listed, allowed, bound and alive) | `unknown_target`: "voice route: Deck is offline; nothing was sent" |
  | A name alone | `malformed`: "voice route: nothing to send to Deck" |
  | A near miss (`unclear`) | `not_allowed`: "voice route: which session? Nothing was sent" |

  A device that advertises `request_refusals` (#665) gets `voice_route_refused` for each of these instead, which ends
  the request and keeps the connection. An older app treats any non-ambient error frame as fatal and reconnects.
  Showing the refusal on the device is slice 5b.
- **The reply comes back.** A delivered routed request makes this connection that route's last input device (#370),
  on its current selection generation. The selection *covers* a target when it is the selected target, or when both
  it and the selected target are routes. The reply checks (`holds`, request records, `recordOwner`, `selects`) use
  that, so while the claim holds Deck's reply reaches the device that asked and no other device. Selecting away, or
  away and back, ends the claim, as do the 10-minute last-input lifetime and a disconnect. After that the existing
  single-selector rule applies unchanged: Deck's reply can reach a device that selects Deck itself, never a device
  that selects Scratch.

Verification is synthetic only (`VoiceRouteDeliveryTests`): a fake tmux-kind adapter and never-started transports.
It is not device hearing, and the app does not yet show a routed reply in the selected destination's thread
(slice 7).

## Showing a refused request (slice 5b)

When the host refuses one request and sends nothing (any `ErrorCode.isRequestRefusal`, from #665's
`RequestRefusals.codes`: `paste_refused` and `voice_route_refused`), the app:

- keeps the connection, as #665 already does;
- adds the host's message as one system line in the thread selected when it arrived (`ConversationLog.noteRefusal`,
  shown with an exclamation-bubble icon, never as a reply); and
- announces it once through VoiceOver (`HostConnectionStore.onRequestRefusal`, wired in `RootView`).

This is the only chat line and the only announcement for any refusal code. Feature-specific UI, such as a paste kept
attached with its reason, adds neither. Verification is synthetic only (`RequestRefusalNoticeTests`), plus the iOS
Simulator build.

## Ambient dispatch authority (slice 4a)

The listener's ambient delivery step (`AmbientListenerDispatcher`) knows its stream's own target and the selection
generation the stream opened on (#695). Only a request the consumer's own route match chose
(`dispatch(_:routed: true)`) is dispatched bound to that route from the stream's target (`HostSession.voiceRouted`),
on that same generation. A request to another target without that decision binds nothing and is refused.

- **Pinned to the stream.** The session admits a routed request only while the stream's target is still exactly what
  the connection selects, on the generation the stream opened on. If the owner selects Deck mid-stream, or selects
  away and back, nothing from the old stream is admitted, routed or not.
- **No inherited route.** A dispatch that starts while a route is already bound, for example in a task an earlier
  routed delivery spawned, is refused (`notAuthorized`). The local socket's `dispatch` kind (`haild rightyo
  --reply-to`) always runs with no route bound, so it stays limited to the selected target.
- **Nothing else changes.** A target that is not a route is refused `targetNotSelected`. Every other local-dispatch
  check (exact binding, policy, sanitizer) is unchanged. A plain tmux route still gets its host-minted reply
  reference (#230) and last-input record (#370), so its reply comes back to the streaming device.

Slice 4b, below, makes the RightyO consumer choose a route from the owner's own turn on an enrolled session.
Verification is synthetic only (`VoiceRouteAmbientAuthorityTests`, `VoiceRouteRaceTests`).

## Ambient routing by the owner's voice (slice 4b)

With `--voice-routes`, each ambient stream's RightyO consumer gets the owner's routes. It reads them from the same
authorizer the listing uses, together with a binding lookup (`WebSocketListener.voiceRouteBinding`: listed, alive
and at the binding the policy allows).

- **Owner only.** Only a request whose turn both the transcript and the attention record call the owner's, on an
  enrolled session, can name a route. That is the same rule as spoken notes (#552). Anyone else's "Deck, …", and
  every turn on an anonymous session, is an ordinary request to the ambient target, exactly as before routing: every
  request RightyO forwards is typed there, whoever spoke. The routing decision comes only from the host's own
  `VoiceRoutes.match` on that owner turn, never from a field of RightyO's output. Only a dispatcher that binds the
  route (the listener's ambient step) carries a routed request; any other refuses it.
- **Only from a route.** Routing applies only while the ambient target is itself a route.
- **The prompt.** A routed request is typed into the named route with that route's own reply block, so its answer
  names that route. A plain tmux route gets a reply reference (#230) and a last-input record (#370) through slice
  4a, so the reply comes back to the streaming device.
- **No silent fallback.** An offline route, another route's name alone or a near miss is held back in
  `lastRouteRefusal`. Nothing is typed anywhere and the stream goes on. So does a routed dispatch the host refuses
  before its handoff (rebound or offline, policy, lockdown, rate), logged as `not_delivered`. Any other failure of a
  routed dispatch (audit, size, cancellation, listener stop) ends the stream, as it would for the ambient target. The
  listener logs `ambient_voice_route_refused` with `reason=not_delivered|nothing_to_say|unclear` only, never the name
  or the words. Slice 5 tells the owner. A refusal for the ambient target itself still ends the stream, as before.
  The ambient target's own name alone ("Hailing Scratch.") is typed there, as before routing and as tap-to-talk
  delivers it.
- **Announced only once sent.** A routed request is shown to the device (#318) and acknowledged only after its
  handoff, so a route that refuses it never looks sent. The stream's own requests still announce before typing.
- **RightyO must forward the turn.** RightyO forwards only turns addressed to the system. Because "Jarvis, Deck,
  …" never re-routes, each route's spoken name must also be in RightyO's `addressing.names`. That is a live config
  change, made only with Mick listening. The owner's own voice commands still come first: "Deck, mute." is the
  owner's mute (#404), not a request routed to Deck.

Verification is synthetic only: `RightyoInputVoiceRouteTests` and `RightyoInputVoiceRouteOwnerTests` (synthetic RightyO
events and a recording dispatcher, plus one test end to end through the listener), `RightyoAmbientRoutedAnnounceTests`,
`VoiceRouteAmbientAuditTests` and `VoiceRouteBindingTests`.
