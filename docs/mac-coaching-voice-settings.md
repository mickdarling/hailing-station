# Existing Mac coaching voice settings

Part of #524. The existing Mac speech-environment allow-list now uses the installed vbsay helper's
actual service keys: VOICEBOX_URL and VBSTREAM_URL. VBSAY_PROFILE, VBSAY_NOFALLBACK and PATH remain
supported. The previous VBSAY_API_BASE/VBSTREAMD_URL names were not read by that helper. This is a
configuration repair; no new renderer, capture adapter, service or route is introduced.

The local saved voice profile also did not exist in the already-running service. An isolated process
using the intended existing Jarvis main profile produced nonzero PCM successfully. Address-key repair
alone still failed with the absent profile, so local qualification must cover both configuration parts.
Do not commit service addresses, profile identifiers or local settings/receipts. No automatic service
selection or fallback is added. Ordinary user-visible playback and system defaults remain separate.

Verification must use the actual owned coaching renderer with the saved environment and report digital
PCM separately from physical audibility. The settings repair does not resolve unidentified ASR tails
(RightyO #184), prove the native property-listener crash cause or establish Superwhisper coexistence.
