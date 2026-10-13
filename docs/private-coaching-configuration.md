# Foreground coaching configuration — inactive source (#269 / #268 / #225)

This prerequisite parses explicit owner-local choices for the future foreground haild command. It neither
queries nor selects devices or starts a child, speech service, engine, capture or playback. Device IDs must be
nonzero and distinct; names, remote targets, defaults, ambiguous values and repeated flags are rejected.
All supplied paths are absolute. The listener profile is loaded only through a bounded owner-private regular
file descriptor, rejecting symlink/FIFO, group/other permissions, oversized content and invalid profile shape.
No environment or ordinary ambient command implicitly opts into coaching or hosted text.

ApplePrivateCoaching supplies conservative activity evidence from its actual owned queue: queued, paused or
muted private PCM counts as pending playback until completion. Unknown/off/expired/invalidated observations
return unavailable, never idle. This read checks actual route and original deadlines after callback-capable observations
and final clock reads; it grants no route or qualification. Independent owner-mid-answer evidence still has to
come from trusted local controls, never transcript roles or model output.

Synthetic tests cover explicit configuration refusal and playback observations, including callback retirement.
The actual command, source-provider launch capability, complete reviews and physical operator choice/proof remain
separate requirements. Nothing here authorizes native factory execution, device queries, live audio, service
calls, public publication, installation, deployment or changes to an installed application.
