# Explicit foreground provider options — source only (#268 / #225)

The foreground command's immutable configuration carries the explicit provider choice through its shared
child binder, existing CoachingChildTransport and existing RightyoChildProcess. No second transcript runtime,
network client, credential forwarding, ambient action/reply integration or implicit environment opt-in is added.
Mock remains the default. Explicit `--coaching-provider jev` requires all three additional choices:
`--coaching-allow-hosted-text`, `--coaching-max-requests 1..100` and `--coaching-advice-catalog` with an absolute
authored catalog path. Missing, duplicated, unknown or mixed options fail closed; selecting mock cannot retain
hosted consent, budget or catalog. Ordinary hosted-ASR flags remain refused. An explicit Jev choice never
silently falls back to mock, including when used with an incompatible sealed mock-only launcher.

Parsing/binding are inert. The transport checks readable regular bounded catalog metadata before child spawn;
Rightyo validates catalog semantics before provider work. Trusted local catalog stability is a precondition,
not an atomic snapshot against hostile same-account replacement. Participant-aware keyboard enable, actual
fixed private output/room-input qualification, measured activity, original deadlines, finite provider budget
and joined owned retirement remain separate unchanged gates. Constructor and status never enable coaching.

Tests parse/bind options and route them through the same command owner and an authored fake child that records
argv; they never execute native factories, query hardware, use credentials/network/models/Jev or real speech.
The qualified b244 executable proof remains mock-only. Dependencies and this final binding require their own
finished exact-head full verification and two independent reviews before qualification. This is unmerged,
inactive source, not device privacy, advice quality, hosted execution, installation or deployment proof.
