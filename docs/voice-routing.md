# Voice routing

[#636](https://github.com/mickdarling/hailing-station/issues/636) lets the owner name the session a request goes to
("Voice Work, …", "Deck, …") or pick it in the app. The reply comes back labelled with the session that answered.
It is step 1 of [#225](https://github.com/mickdarling/hailing-station/issues/225). Several sessions listening at
once is out of scope.

## Status

| Slice | State |
| --- | --- |
| 1. Allow-list file and the opening-name parser (`VoiceRoutes`) | In source. Not wired to any input path, not deployed. |
| 2. Host listing: route names, offline routes and `--voice-routes` | In source. Not deployed: `host.sh` does not pass the flag yet (slice 8). |
| 3–8. Route-group authority, ambient routing, refusals, spoken and visual labels, app selector | Proposed; see the [plan on #636](https://github.com/mickdarling/hailing-station/issues/636). |

Nothing below changes the running daemon or installed builds until a later slice wires it in and it is deployed.

## The allow-list: `routes.json`

The owner writes one file on the Mac, by hand. The daemon only reads it and never writes, creates or rewrites it.
Routing is off when the file is absent.

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
  by whitespace alone, each keying to at least one ASCII letter or digit, the first not a greeting. So "Voice-Work",
  "One-Two-Three-Four", "Okay Deck" and "東京 Deck" are refused. Names are compared as `RightyoAddressing.key` (case-folded ASCII letters and digits), so "Voice Work"
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
logs `voice_routes` with the route count or `missing`. A missing file leaves routing off. A file that fails to load
refuses startup. Without that, routing would be silently off and a request naming a session would go to whichever
target was already chosen.

The `targets` list a device receives changes in two ways:

- A listed, allowed and bound target that is a route shows the route's `name` instead of its session name. Its id
  is unchanged.
- A route that is not listed, not allowed by policy or no longer at its allowed binding is still listed, with its
  name, as `alive: false`. The device can show it as offline instead of hiding it. `select` reads the policy-filtered
  listing without names, so an offline route cannot be selected (`not_allowed`). The routes file adds no target the
  policy does not allow.

Targets that are not routes are listed exactly as before. The device's remembered selection matches on id and name,
so renaming a target forgets it once and the owner picks it again.

Verification is synthetic only (`VoiceRouteListingTests`, `VoiceRouteOptionsTests`).
