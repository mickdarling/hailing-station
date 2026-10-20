# Pasted content (#608)

A device can send text the user pasted along with a spoken request ("compare this with GitHub" plus the paste), or on
its own. Pasted content is the user's data for the session to read. It is never treated as instructions. Text only
for now; links, images and files are later attachment kinds.

## Wire

A final text frame may carry an optional `pasted` object:

```json
{"type":"text","target":"tmux:claude-hail","payload":{"final":true,"text":"compare this with the open issues",
 "pasted":{"text":"Synthetic note:\nThe beta build fails on step 3."}}}
```

- `pasted.text` is required, non-empty and at most `PayloadLimits.maxPastedTextBytes` (32 KB) of UTF-8.
- `pasted` is allowed only on a final frame. The decoder and the schema both refuse it on a partial.
- `text` may be empty when `pasted` is present, for a paste sent on its own.
- JSON escaping can grow the paste, so a sender also checks the encoded frame against
  `PayloadLimits.defaultMaxFrameBytes` before it sends, and shows a clear error when it does not fit.
- A host that accepts pastes advertises `pasted_text` (`PastedText.capability`) in its `hello`. A device never
  sends `pasted` to a host without it. An older host ignores the unknown key and would deliver the spoken text
  alone, so the paste would be dropped without a word.

Two known differences between the schema and the decoder, both on the safe side: the schema's `maxLength` counts
code points while the decoder counts UTF-8 bytes (the decoder is the stricter cap), and `"pasted": null` decodes as
no paste while the schema refuses it. Senders omit the key when there is no paste.

Fixtures: `fixtures/frames/text-pasted.json`, `fixtures/frames/text-pasted-only.json`, and the negatives
`fixtures/invalid/text-pasted-*.json`.

**Compatibility:** one optional key, no protocol version bump (`protocol:compatible`). Frames without a paste are
byte-identical to before.

## Device side (HailCore)

- `PastedDraft` checks a paste before it is attached: visible text, at most 32 KB of UTF-8. Its `preview` and
  `isLong` (more than 4 lines or 280 characters) drive the collapsed transcript block, so a Mac client can reuse them.
- `HostConnection.sendFinalText(_:pasted:to:)` sends a paste only to a host that advertised `pasted_text`
  (`PastedDraft.Problem.unsupportedByHost` otherwise) and only when the encoded frame fits
  `PayloadLimits.defaultMaxFrameBytes` (`.tooLarge` otherwise). Nothing is sent in either case.
- `HostConnectionStore.acceptsPaste(host:)` tells the station whether to offer paste at all, and a sent paste joins the
  conversation as `ConversationEntry.pasted`, beside the spoken text (which may be empty).
- `Problem.message` gives the station's error sentence. The wording is a placeholder for Mick to approve.
