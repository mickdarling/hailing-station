# Voice routing

[#636](https://github.com/mickdarling/hailing-station/issues/636) lets the owner name the session a request goes to
("Voice Work, …", "Deck, …") or pick it in the app. The reply comes back labelled with the session that answered.
It is step 1 of [#225](https://github.com/mickdarling/hailing-station/issues/225). Several sessions listening at
once is out of scope.

## Status

| Slice | State |
| --- | --- |
| 1. Allow-list file and the opening-name parser (`VoiceRoutes`) | In source. Not wired to any input path, not deployed. |
| 2–8. Host listing, route-group authority, ambient routing, refusals, spoken and visual labels, app selector | Proposed; see the [plan on #636](https://github.com/mickdarling/hailing-station/issues/636). |

Nothing below changes the running daemon or installed builds until a later slice wires it in and it is deployed.

## The allow-list: `routes.json`

The owner writes one file on the Mac. Routing is off when the file is absent.

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
- **Names.** A `name` and each of up to eight `aliases` is 1–48 characters, at most three words, with no control
  characters. Names are compared as `RightyoAddressing.key` (case-folded ASCII letters and digits), so "Voice Work"
  and "voicework" are the same spelling. Every spelling must be unique across routes and must not be a greeting
  ("hey", "ok", "okay").
- **Trust.** The file decides where the owner's spoken requests go, so it is trusted exactly as `destinations.json`
  is. After symlinks it must be a regular file of at most 64 KB, owned by this user or root and not group- or
  world-writable, in directories up to `/` that no other user can write either.

## The opening-name parser

`VoiceRoutes.match(_:names:)` reads the start of a request.

1. It skips an optional greeting ("hey", "ok"). A route's spelling is tried first, then an optional addressing name
   from RightyO's advertised names (e.g. "Jarvis"), then a route's spelling again. So a route may share a spelling
   with an addressing name.
2. It looks for a route's name or alias of up to three words, longest first. The name must end at a space or the
   end of the text, after any of `, : ; . ! ? -`. So "Deck: add a slide" matches and "deck.md needs work" does not.
3. The outcome is one of:
   - `routed(route, text)`: the request goes to that route. `text` holds the words after the name, as said. The
     input paths are expected to send the whole request as heard, so the session sees how it was addressed.
   - `nothingToSay(route)`: the name alone, so there is nothing to send.
   - `unclear`: the opening words, followed directly by a comma, are within one edit per four letters of a spelling
     of at least five letters ("Voice Wok, …"). Nothing is sent: a misheard name must never land in the wrong
     session or fall back silently. A short name's misrecognitions ("Duck" for "Deck") belong in its `aliases`.
   - `unaddressed`: everything else, including a name in mid-sentence ("Can Voice Work look at this?"). The request
     goes unchanged to the target already chosen.

The parser decides nothing about who is speaking. The owner-only rule is applied by the input path that calls it
(slices 3 and 4).

Verification is synthetic only (`VoiceRoutesTests`, `VoiceRoutesFileTests`).
