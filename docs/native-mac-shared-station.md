# Native Mac station and private coaching

Part of [#266](https://github.com/mickdarling/hailing-station/issues/266). The native
`Hail-macOS` target builds the same RootView, destination picker, chat, reply
controls and adaptive layout as the iPhone/iPad target. Platform adapters keep iOS
routing, keyboard, selection and accessibility behavior on iOS. Mac diagnostics
report the system default route; they do not change system defaults.

`HailCoaching` shares the existing coaching composition with `haild`. The app uses
one app-owned coaching controller, playback owner and capture admission across
closing/reopening its single window. Construction starts no microphone, child or
playback. Private coaching starts only from the local Start control, after device
selection and participant awareness. The same qualified fixed USB input/private
headphone output owner is used. Displayed device selections include an internal
UID and are rechecked before Start; numeric IDs are not persisted.

The Private coaching card provides microphone/headphone choices, Start, Stop,
status, and an explicit owner-listening control. A stopped or failed run cannot
restart until owned retirement joins. Capture admission covers permission,
construction and teardown waits for ambient, tap and private capture. Ordinary
reply playback is suppressed during private coaching. Each run gets a fresh token;
queued Stop calls compare controller revision, and delayed cleanup releases only
its captured token. Disappearance performs cleanup independently of view observation.
Unexpected ambient retirement reports completion after resource cleanup, so its
reservation can be released without admitting another capture prematurely.

## Local configuration

The owner-only `~/.config/hail/coaching-local/mac-app.json` contains `rightyo`,
`config`, `profile`, `rendererOutputRoot`, and `listener`. Optional `adviceCatalog`
and `maxRequests` select the existing Jev catalog provider with explicit hosted
text consent. The renderer root must already exist, be owner-only mode 0700 and
have no extended ACL. Profiles retain the existing private-file validation.

Optional `speechEnvironment` uses only PATH, VBSAY_PROFILE, VBSAY_NOFALLBACK,
VBSAY_API_BASE and VBSTREAMD_URL. Installation-specific identities, endpoints,
credentials, transcripts, models and generated artifacts stay outside Git.

Catalog coaching selects authored cues. It does not implement spoken goal
compilation or voice list/add/remove. Those remain
[Rightyo #178](https://github.com/mickdarling/rightyo/issues/178), with pure schema
and registry groundwork in its draft PR #179. Definitions are advice data and
confer no authority to execute host actions.

## Verification and limits

The native Mac and iOS simulator targets build. Strict lint passes. Synthetic
regressions cover no-start construction, awareness refusal, native-start failure
cleanup through fakes, session replacement, default-only route selection, opaque
UID identity, capture admission and actual ambient retirement completion. No
synthetic result establishes a physical window, permissions or useful live advice.

| Ordered boundary | Evidence |
| --- | --- |
| Construct; missing awareness; attempt Start | constructionAndMissingAwarenessAreInert |
| Pending ambient permission; private claim | pendingStartupAndRetirementHoldAdmission; source wiring |
| Pending streamer construction; close; private claim | joined startup task; source wiring |
| Tap permission pending; private claim | pre-await capture reservation; source wiring |
| Private active; stale tap/ambient action | shared admission and preflight; source wiring |
| Startup fails; old child retires; retry | failedStartupRetainsCleanupUntilExplicitStop |
| Stop joins; another Start arrives | olderConcurrentStopCannotClearReplacementOwner |
| Two Stop joins; replacement starts; old join returns | olderConcurrentStopCannotClearReplacementOwner |
| Old Stop queued; replacement begins; old Stop executes | queuedOldStopCannotStopTheNextSession |
| Old token cleanup; replacement token held | lateCleanupCannotReleaseAReplacement |
| Card disappears; join finishes after observation removal | explicit captured cleanup; source wiring |
| Same device number/name; different UID | reusedDeviceNumberDoesNotPreserveAChoiceOfAnotherDevice |
| Unexpected ambient end; release waits; private claim | unexpectedStopReleasesAdmissionOnlyAfterResourceCleanup |

The local window automation service failed before returning window state. Manual
visual/startup verification remains pending. Live TypeSafe requests and GUI audio
have not been qualified. Earlier bounded native audio evidence qualifies the
underlying private owner, not the GUI or dynamic coaching product. Drafts, pending
CI/review gates and unmerged foundation dependencies are not a release approval.
