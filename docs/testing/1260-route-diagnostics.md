# Reading a reply route trace for #1260

**Host results pending. Physical iPhone and iPad results pending.** This change instruments the existing routing policy. The cause of the speaker report and the audible destination of a reply still require field evidence.

## Wire records

A collecting host advertises `device_diagnostics_route_snapshot` alongside `device_diagnostics`. The phone records while its diagnostics switch is on and checks the receiving host's capabilities at send time, including for buffered batches.

| Record | When the phone takes the sample | Fields to read |
| --- | --- | --- |
| `route_change phase=configure` | At a helper category write. The phone saves the route before the call and reads the category and options when the call returns or throws. | `pre_input`, `pre_output` and their counts describe the starting route. `policy_apply` distinguishes a policy effect from ordinary configure. `write_succeeded` reports the call outcome. |
| `route_change phase=change` | In the existing system notification observer. This observer also runs when the backend skips a nested notification. | `reason` is the AVAudioSession notification reason. `input` and `output` are current. `previous_input` and `previous_output` come from the notification. Each has a count. The legacy `route` is the current first input. |
| `route_change phase=change` with `decision` | After the reducer updates its state and before it performs any effects. | The same route and reason fields describe the policy sample. `decision` is the policy's verdict, `user_chose_built_in` its resulting latch, and `app_attributed` its reconfigure marker for this change. |
| `reply_playback_start` | When the existing playback observer sees the busy transition. It reads the session again. | The current pair and counts, plus `capture_owns_engine` when the player exposes its running capture-engine route. The legacy `route` is the current first output. |

Each sample includes `category` (`play_and_record`, `playback`, or `other`) and four actual option booleans, `default_to_speaker`, `allow_a2dp`, `allow_hfp`, and `mix_with_others`. The separate `hfp_preference` reads the owner's saved microphone setting. Standalone playback can inherit an HFP option that differs from the preference.

Every port uses the existing closed `route` vocabulary. Empty or unavailable lists yield `none` and zero. Unmapped ports yield `other`. Only the first port is reported. Counts saturate at 255. A count above one leaves the identities of subsequent ports unknown.

An older collecting host receives the original notification (`reason` and input `route`) and playback start (output `route` on iOS). The sender drops helper writes and supplementary policy decisions, strips snapshot fields, and skips a batch if this leaves it empty. Protocol v1 still accepts the original shapes. The strict decoder validates the new tokens, boolean types, counts, and positive sequence bounds.

## Reconstructing an episode

Use `haild diagnostics show <session-prefix> --json` on the collecting host. Within one continuous device logging session, order observations by `route_sequence`. It starts at one, survives batching and reconnects, and restarts when a fresh log starts or diagnostics are re-enabled. A configure gets its sequence and device timestamp before its write. Its completed record can arrive after a nested category notification with a higher sequence, even when both share a millisecond. A raw notification and a policy sample can describe one hardware transition. Use the presence of `decision` to identify the reducer's observation. Check for sequence gaps and `events_dropped` before inferring that a later observation never happened.

| Candidate ordering | Evidence to look for |
| --- | --- |
| Stale first configure | Ordinary configure sees zero outputs or a single speaker/receiver, succeeds with `default_to_speaker=true`, then playback starts on speaker. Check for any intervening observed external output or later policy apply that cleared the flag. An external first output at that configure points away from this sequence. |
| Built-in choice latched | A `repair_requested` decision and policy category write precede an `override` with a nonempty input, built-in output, `decision=user_choice_assumed`, and `user_chose_built_in=true`. Look for the latch through to a speaker start. Compare with a deliberate picker action in the field notes. iOS can report the same override for either origin. |
| HFP reconfigure | A configure with the saved preference on is followed by an app-attributed category/configuration change. Compare the resulting HFP option with the preference, then look for HFP input paired with speaker output at reply start. A later override can also latch the built-in choice. |
| Reply inherits another owner's session | Playback starts on speaker with `category=playback` and `mix_with_others=true` for keepalive, or with `capture_owns_engine=true` for the capture engine. Follow prior configure and change records to see when speaker first appeared. An absent ownership field means the player did not expose that state. |

Keepalive's own category set/restore writes and activation state at configure are deferred. A successful category write establishes the result of that API call. The playback sample establishes the route seen at the busy edge. Listen on hardware to establish where audio actually played.

## Host verification to run

From the worktree, use the real host gate directory. Keep the host load guard in effect. Run each phase only after the host slot and then voice quiet both succeed. Stop if either gate is unavailable. The commands below are pending.

```sh
(
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
gated() {
  "${HAIL_HOST_GATES:?Set HAIL_HOST_GATES to the installed gate directory}/hostslot-wait.sh" &&
    "$HAIL_HOST_GATES/voice-quiet.sh" &&
    taskpolicy -b "$@"
}

gated swift build -j 2 -Xswiftc -warnings-as-errors
gated swift test -j 2 --no-parallel --filter 'RouteSnapshot|AudioOutputRoute|BluetoothHFPRoute|DeviceDiagnostics|DiagnosticEvent|DiagnosticSession|LimitsAndNegatives|FixtureConformance|ReplyMasking'
gated python3 -m unittest scripts/tests/test_check_schema.py
gated python3 scripts/check_schema.py

# Compare generated canonical bytes in scratch space.
proof_dir=$(mktemp -d)
gated swift run -j 2 hail-protocol-gen "$proof_dir/frames"
cmp "$proof_dir/schema/frame-v1.schema.json" fixtures/schema/frame-v1.schema.json
diff -r "$proof_dir/frames" fixtures/frames

gated swiftlint lint --strict --quiet Sources/HailCore/AudioOutputSessionRouting.swift \
  Sources/HailCore/Diagnostics/DeviceDiagnostics.swift Sources/HailProtocol/Control.swift \
  Sources/HailDaemonKit/Listener/HostSession.swift Tests/HailCoreTests/RouteSnapshot*Tests.swift \
  Tests/HailCoreTests/DeviceDiagnosticsOutputRouteTests.swift Tests/HailCoreTests/HostConnectionTestSupport.swift \
  Tests/HailProtocolTests/DiagnosticEventTests.swift Tests/HailDaemonKitTests/DiagnosticSessionTests.swift

# Compile the iOS routing adapter with the repository's unsigned simulator scheme.
gated xcodegen generate --quiet
gated xcodebuild build-for-testing -jobs 2 -project HailingStation.xcodeproj -scheme Hail-iOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$proof_dir/DerivedData" CODE_SIGNING_ALLOWED=NO
)
```

Check that `routeSnapshotAtConfigureChangeAndPlaybackStart` preserves the configure's lower sequence through a nested notification, reports the applied options, and samples the playback owner at the busy edge. The macOS test scripts the notification callback. The iOS branch posts a synthetic category notification. `legacyHostReceivesCompatibleRouteEvents` compares the actual socket bytes and covers a batch containing only supplementary records. The protocol fixture exercises every gated field. The six route negatives cover phase, decision, port, count, sequence, and boolean kind. Host hello coverage checks a diagnostics sink, an ordinary host without one, and a connection probe. The sink test reads the full fixture back from temporary storage and compares every event. The positive snapshot example lives beside the schema so the existing canonical v1 diagnostic fixture remains a legacy peer example.

## Later physical check

With an owner-approved diagnostics-enabled host and app build, enable device diagnostics before the launch being studied. On iPhone and iPad, compare AirPods connected before launch, connected while listening or idle, and connected mid-reply. Repeat with HFP off and on, with capture running and with background keepalive. Exercise disconnect/reconnect and an explicit speaker pick. Match the first audible destination to the recorded output and note any interrupted reply. Repeat the one-AirPod plus wired-car ordering if available. Retain only type-level evidence for #1260. Deployment and field collection are separate from the pending host checks.
