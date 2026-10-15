# Mac coaching startup diagnostics

Part of #524. The foreground owner records only the stage where synchronous startup refused:
provider setup/start, selected-device setup, audio start, provider qualification, or final activation.
The original error and retirement path are preserved. This diagnostic never grants audio authority,
changes a route, launches a child by itself, or contains exception strings, paths, transcripts or credentials.

The native window maps that stage to fixed actionable text. Setup errors before command construction
remain distinct. Failure feedback survives Stop/Off cleanup and clears on a fresh explicit Start.
Unexpected asynchronous retirement has a generic session-ended message; this does not claim a specific
route/provider cause. A local setup error cannot reuse a previous controller's device failure message.

Authored regressions inject failure at every startup stage and verify exact owned resource retirement,
private error redaction, failure persistence and fresh-run clearing. These do not establish physical
microphone, headphone or provider behavior. Installed-app proof and the actual startup diagnosis are
recorded separately in #524. Conference/system audio remains #525.
