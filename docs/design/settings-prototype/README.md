# Local settings design prototype

This is a documentation-only, synthetic interaction study for [settings on every Hailing Station app](../settings-design.md). It is not an HS app or a settings backend. It cannot change live configuration, contact haild/RightyO, use the microphone, generate speech, grant permission or alter audio routes. Proposed settings and simulated effective/activation states must not be mistaken for implemented or physically validated behavior.

Open [index.html](index.html) directly from this checkout in a local browser. The prototype is self-contained: no package installation, app build, development server, third-party preview service or upload is needed. Do not upload the checkout or private reference material for previewing. All examples are synthetic; do not paste real endpoints, credentials, identifiers, transcripts or configuration into the page.

The [design gallery](../settings-design.md#all-24-section-frames) links all eight settings sections on Mac, iPad and iPhone. The [inventory](../settings-inventory.md) identifies which source behavior exists today; the design and prototype illustrate the proposed complete catalog and editors. A visible setting does not imply current app/host support.

Review the same common and Advanced settings on each platform, including search by human label and exact technical key. Warnings, role restrictions, unavailable reasons, defaults, configured/effective differences, activation requirements and reviewed changes belong to the setting rather than to a platform-specific editor. An unavailable control remains visible and disabled with its reason.

The platform contracts are:

- **iPhone:** exactly Station, Sessions, Devices and Settings tabs. The existing Settings entry opens a native-sheet-style form. The shell's dock remains above the tab bar; no fifth tab or second audio owner is introduced.
- **iPad:** adaptive split layout, collapsed sidebar at narrow width, and optional inspector presented as a sheet when compact. Resizing preserves the draft and setting context.
- **Mac:** sidebar and toolbar, with the optional inspector closed by default. Settings entry points share the coordinator instead of establishing permanent third-column ownership.
- **Aa:** Smaller, Larger, Reset, current value and a live synthetic conversation preview. Reset means this app's platform default; OS text settings and other control sizes remain unchanged.
- **Audio:** existing input preference and system output picker affordances only. The prototype demonstrates these affordances and unavailable reasons; it does not invoke the actual OS picker, custom routing controls or route probes.

Inspect the before/after review and explicit activation choices rather than treating a control's changed appearance as a saved or active receipt. Sensitive settings and actions require the proposed owner-authorized visual path; synthetic permission screens do not provide security. Presets must show their precise field changes, and resetting/reverting must not silently broaden privacy or authority. No backend behavior, accessibility conformance, data persistence guarantee or production lifecycle result is established by this offline study.

## Catalog and interactions

### Consolidated layout

Mac and iPad use full-width directly editable rows, with control, Reset, favorite star and Info together. Page capacity is measured from the available height and actual wrapped rows; it is not capped at six. Scope, search, group reset and attention presets stay fixed above the rows; page position and review/undo remain fixed below. Narrow layouts stack the same row contents. Info toggles the optional inspector or compact sheet; technical sources, full help, defaults, bounds and effective values stay there instead of repeating below each field. The station header and voice dock remain compact, with the dock above the existing four iPhone tabs.

Favorites is a navigation entry directly below Settings, also available in the compact category selector. Stars reference the same setting IDs and drafts, work offline, and do not grant edit permission. They remain in memory in this synthetic prototype. Resetting the favorite set reviews field changes and never removes stars.

The HTML embeds **504 descriptors**: Listening 49, Privacy 82, Voices 70, Notifications 36, Targets 34, Audio 28, Appearance 7, Advanced 198. This count includes expanded object members, invocation fields and operation composers, plus explicitly disabled system-owned and fixed/library-only entries. Each carries public source/default/range/role/risk/activation metadata and inventory-row provenance. It is not a claim that 504 persistent preferences exist in production. The 24 static frames show the full-pane settings rows, Favorites entry and persistent command/review areas; their fixed dimensions illustrate one viewport rather than prescribe a fixed page size.

Use the Host and Role selectors to see offline and insufficient-role states. Developer (demo) is a cumulative all-role laboratory shortcut; production development-profile access must remain separate from owner/admin authority. In the listening category, the initial **synthetic** profile has the cue requirement on (code default off), so **Pay attention to me** produces a visible change. It changes only `conversation.require_cue`; choose Review, simulate owner authorization, then save pending or simulate activation. Configured/effective values and activation status remain separate. Field bounds illustrate source rules; complete authoritative filesystem, trust and cross-schema validation belongs to the future host implementation.

Aa keeps separate in-memory choices for each platform; switching layouts does not reset an unfinished size choice. Reset uses 14 pt on Mac or 17 pt on touch platforms. Group reset respects the selected scope and excludes credentials, grants, identity bindings and required fields with no default. Undo apply stages a reversal for review without consuming history or discarding unrelated drafts before confirmation. Undo edit records only the affected IDs with their platform; another platform's Aa draft is never imported, and ineligible history remains available when switching back. Drafts are revalidated against the illustrated types, ranges, relationships and platform Aa choices before review/apply. Credential editors keep only a synthetic set/unset marker, not their entered content; no values are persisted.

## Verification limits

The inline JavaScript was syntax-parsed in the orchestration environment without executing it on the Mac. Source-only editorial review covered role/offline states, reset/undo, Aa, activation and the absence of network/media/storage calls. No local builds or test suites ran. Automated local browser opening was blocked by its URL security policy, so interactive browser and rendered visual qualification are **not completed**. Open the local file manually to review behavior; native device, VoiceOver and audio verification remain future implementation work.
