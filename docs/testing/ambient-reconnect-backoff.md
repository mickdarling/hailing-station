# Ambient reconnect backoff

Part of #904 (ask 3 follow-up, after #968, #969 and #970). Based on main at
`3c4c86829d56178e1a0159ed40119797945268a5`, implementing Mick's 2026-10-27 rulings.

Transport recovery has no total deadline. The existing connection loop remains
the sole scheduler, including generation-checked selection-send flaps. Its ambient
waits start at 1.5 seconds, double to a named 60-second cap, and use the connection's
injected jitter source. Jitter spans 80–120% of the base, with a hard 60-second
maximum. Every retry wait uses `ambientSleep(for:injected:)`.

Pacing survives flaps and resets on network path changes, foreground activation,
or applied restoration. A reset replaces a pending wait with a fast wait; it does
not launch an unpaced parallel attempt. The default network connector installs a
path monitor; scripted connectors use the same explicit path-change entry point.
The monitor's initial path delivery is not treated as a change.

Owner off and privacy revoke the pacing owner and cancel its waiter. Cancelled
or obsolete waits cannot open another socket even when an injected sleeper
returns successfully. A cancelled recovery reports disconnected instead of
leaving a reconnecting transport with no running scheduler. Explicit connection
and destination actions remain owner actions.

The ambient card prioritizes “Reconnecting…” for the entire pending restore,
including negotiation, target selection and private confirmation. Capture stays
active and discards gap audio. Media mode already leaves capture active and does
not veto restoration. Microphone retries that construct fresh capture now wait
for the foreground, retaining the microphone pause reason and a foreground hint.
Foreground deferrals retain their retry slot. Microphone failures advance the
existing backoff to its repeating final delay; they never exhaust the owner's
listening intent. Returning to the foreground retries immediately.

A nil pacing-provider result clears the transport's cached ambient owner, both
when scheduling a wait and when resetting after a path/foreground nudge. Moving
listening to another host therefore leaves ordinary transport retry available
on the former host even after its previous ambient pacing has been cancelled.

The independent five-second privacy-confirmation window is unchanged. A private
handshake or unconfirmed restore never counts as successful restoration, never
resets pacing, and never resumes public audio. Timeout or failed reassertion still
fails closed. Explicit path/foreground reset triggers remain available.

Transport selection failures retain the existing retry mapping. Genuine
authorization refusals still stop with `reauthorizationNeeded`; changed identity,
target and unsupported protocol/capability checks retain their visible vetoes.
The separate refusal backstop retains its exact stream/binding proof and
60-second window, now measured from the restored stream rather than the original
drop. A long outage therefore cannot age out that stream's refusal protection.

## Verification

New synthetic tests cover the sequence, cap and jitter bounds; all three reset
triggers; repeated failures and persistent presentation; cancelled wait ownership;
owner off/privacy; private handshake flaps; and foreground-only microphone retry.
The fix-round regressions cover host A recovering before listening moves to host
B, nil-provider path/foreground nudges, foreground deferrals that preserve their
retry slot beyond the former finite schedule, and microphone failures that stay
paused beyond that schedule. They use injected, hand-stepped sleeps and assert
state and delay values rather than elapsed-time bounds.
Existing total-deadline cases now require recovery after long injected outages.
Existing five-second privacy deadline tests remain in place. Reference scenarios
were read from the supplied race-test checkout and adapted to the current
generation-checked transport loop.

- `swift build --build-tests`: blocked before source compilation. Manifest
  compilation cannot write the compiler module cache under the sandbox; output
  also reports an SDK/compiler version mismatch.
- `swift test --filter 'AmbientReconnect|AmbientListening|AmbientInterruption|HostConnectionStore'`:
  blocked at the same manifest step. No tests ran.
- `swiftc -frontend -parse` for all changed Swift files: passed (syntax only,
  without type checking or executing tests).
- `swiftlint lint --strict --quiet`: unavailable (`swiftlint` is not installed).
- `git diff --check`: passed.

No sandbox workaround, completed SwiftLint run, simulator build, physical-device test,
live host round trip, delivery, or GitHub operation was performed. The new code
and synthetic expectations remain uncompiled and unexecuted in this environment.
