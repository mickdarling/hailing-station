# Local voice stop: protocol and host evidence

Part of #1212, within #1211. This is PR 1a's protocol and haild slice. All fixtures and evidence here are synthetic;
there is no detector, app change, simulator or physical-device proof, live captured-output round trip, installation,
or upload. The remaining device and queue requirements of #1212 are deferred explicitly below.

## Implemented boundary

- `voice_stopped` carries only optional bounded integer `latency_ms` (0...60,000). Both encoding and decoding enforce
  the bound; decoding and schema reject unknown fields and explicit null. The host capability is `device_voice_stop`.
  A future PR needs `protocol:compatible` and `security:critical`; no GitHub metadata is changed by this work.
- Negotiation, matching protocol version, authorization, the reporting connection's active ambient stream and privacy
  off gate the host stop. Unready, inactive and private reports have content-free reason tokens.
- The handler reuses `WebSocketListener.stopReplyPlayback(connection:)`, including the existing in-flight reply
  retirement and stopped-reply ledger. No request is withdrawn. No confirmation is played for a device report.
- A per-connection monotonic timestamp suppresses only the #418 confirmation of a later RightyO playback dismissal
  for less than ten seconds. The timestamp is replaced on repeated accepted reports and removed at teardown.
  Dismissal effects, guard holds, target policy, confirmation tier, mute/unmute and reply queueing are unchanged.
- `AmbientRightyoRouter.replyPlayback(_:connection:)` already forwards admitted `reply_playback_end` and playback-error
  diagnostics to RightyO as ended. Local `ReplyPlaybackController.stopPlayback` clears active playback;
  `DeviceDiagnostics.watch` observes the busy-to-idle edge and emits `reply_playback_end`. This report does not
  synthesize another end, avoiding a second source of truth.

## Deterministic tests

`DeviceVoiceStopProtocolTests` covers frame round trips with omitted and boundary latency, invalid encoding and
wire values, unknown-key refusal, the closed schema rule, and a helper that sends nothing to a simulated legacy host.
`DeviceVoiceStopSessionTests` covers capability advertisement only with both gate and handler, unnegotiated/closed
reports with `reason=not_ready`, unwired/read-only ignores, authorization, and attribution to the negotiated
connection rather than payload data.

`DeviceVoiceStopTests` uses loopback WebSockets and a synthetic child held at an explicit release point. It covers
retirement of multiple in-flight replies, event latency, absence of a device-stop confirmation, privacy/inactive
refusals, another connection's inability to stop the active one, and unchanged later replies. Its injected monotonic
clock tests RightyO confirmation at 0, 9, 10 and 11 seconds. The privacy refusal test seeds the existing host
private-state slot directly; it does not claim a real privacy-entry exchange. Negative socket assertions follow
completed handler logs and ping/pong barriers; none use a settling delay or block a cooperative thread. The existing
`AmbientWiringStopConfirmationTests` remain part of the focused repeat selection.

## Deferred expectations and PR 1b hook

PR 1b must prevent detached `haild reply` jobs waiting on `reply-audio.lock` from starting audio after a stop. The
hook belongs at the existing connection stop boundary, `WebSocketListener.stopReplyPlayback(connection:)`, and the
CLI's `ReplyBackground.awaitAudioTurn(socket:target:)` lock-acquisition/admission boundary: the current stopped-reply
ledger covers replies whose audio has already entered flight, not a job that has not published audio yet. This PR deliberately adds no queue-job clearance.

Later device work must tap echo-cancelled capture before masking, enforce privacy and the setting, stop local
playback/queue before sending, and validate owner latency and self-trigger rejection physically before default-on.
Those detector, device queue, reply-text guard timing, battery and physical proof expectations are not claimed here.

## Verification

The Dev Work VM uses a fresh `vw1212a` workspace at the requested main base, with the local source delta copied
without a push. Phases run sequentially after the shared lane is idle. Each phase has a 590-second deadline and
signal/finally cleanup that terminates and kills its process group. Swift package concurrency is capped at four
jobs and each compiler at one worker. No synthetic load workers, dependency fetch, installation or upload are used.
The workspace build directories are deleted after verification.

The exact build/test argument prefix is:

```bash
flags=(
  -j 4 --disable-automatic-resolution -Xswiftc -j1
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
taskpolicy -b swift build --build-tests "${flags[@]}" -Xswiftc -warnings-as-errors
# Each selection below runs as a separate capped phase:
taskpolicy -b swift test --skip-build --no-parallel "${flags[@]}" --filter '<selection>'
taskpolicy -b python3 -m unittest discover -s Tests/ReplyCLITests
taskpolicy -b swift run --skip-build hail-protocol-gen
```

The existing `vw-werr.sh vw1212a` wrapper runs under the same outer 590-second process-group cap. An external
`swift` shim adds `-Xswiftc -j1 --disable-automatic-resolution` to the wrapper's four-job build, so its separate
warnings-as-errors package/test build respects the worker cap. The wrapper's `werr build=0` marker and its build log
are checked, since wrapper exit status alone does not prove a successful build.

Final source results (function counts are Swift Testing's summary; case executions include parameterized rows):

| Selection / phase | Runs | Functions / suites | Case executions per run | Result / seconds |
| --- | ---: | ---: | ---: | --- |
| `DeviceVoiceStop\|AmbientWiringStopConfirmation\|HostPlaybackStop` | 3 | 29 / 5 | 55 | pass; 7.177, 6.340, 7.035 |
| `HailProtocolTests` | 1 | 167 / 31 | 573 | pass; 0.307 |
| `HailDaemonKitTests\.Ambient[A-M]` | 1 | 134 / 25 | 207 | pass; 102.863 |
| `HailDaemonKitTests\.Ambient[N-S]` | 1 | 317 / 65 | 488 | pass; 336.532 |
| `HailDaemonKitTests\.Ambient[T-Z]` | 1 | 214 / 49 | 395 | pass; 134.498 |
| `HailDaemonKitTests\.Rightyo` | 1 | 186 / 17 | 228 | pass; 35.109 |
| `HailDaemonKitTests\.(WebSocketListener\|WebSocketPeer\|Listener\|HostReply\|Dismiss\|StopConfirm)` | 1 | 22 / 5 | 67 | pass; 0.868 |

The three ambient partitions exactly cover the requested `Ambient` family. Together with RightyO and the listener
partition, the requested broad daemon selection passed 873 functions and 1,385 case executions. Every selection
started tests. The final warnings-as-errors package/test build preceding these runs passed in 35.45 seconds.
SHA-256 comparison confirmed identical host and VM contents for all nine changed Swift files.

Initial build attempts exposed test-helper compile errors, and the first focused run exposed a private-state
fixture that could not enter privacy with its unsupported child. Those test setup errors were corrected before the
final runs above. A final ingress audit also added tokenized ignores for read-only/unwired sessions; all results
above were rerun after that correction.

The full Reply CLI command above passed **126 tests in 232.676 seconds**, exit 0. The VM generator regenerated
57 canonical fixtures and the v1 schema; only the schema changed. Host conformance checks then passed:

```bash
python3 scripts/check_schema.py
python3 -m unittest scripts/tests/test_check_schema.py
```

Results: **57 valid fixtures, 121 negative fixtures rejected, zero failures; 11 schema-checker unit tests passed**.

Host strict SwiftLint, the 120-column check and whitespace validation exited 0 and emitted no output for all nine
changed Swift files, including all tests and test support. Reproduce against the requested base after committing:

```bash
swift_files=( $(git diff --name-only f3f97bc71a3501db2fc59887f0af208d7af3a50f HEAD -- '*.swift') )
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict --quiet "${swift_files[@]}"
awk 'length($0)>120 {print FILENAME ":" FNR ":" length($0)}' "${swift_files[@]}"
git diff --check f3f97bc71a3501db2fc59887f0af208d7af3a50f HEAD
```

No added `#expect` chains string additions. No lint suppression was added; the existing receive method moved to
an extension to keep the actor within the configured type-body limit.

The PR-shape checker's exact exclusions yield **four production files**: `Control.swift`, `Schema.swift`,
`HostSession.swift` and `WebSocketListener.swift`. There are no renames. Tests, documentation and the canonical
schema JSON are excluded by that checker. The two listener files require `security:critical`; the capability-gated
v1 extension requires `protocol:compatible` for a future PR. No labels were changed.

The separate warnings-as-errors wrapper completed in **232.10 seconds**, reported **`werr build=0`**, and exited 0.
Its build log contains zero errors and 120 CLT debug-symbol warnings about missing module-cache files; all warning
lines belong to that category, with no other warnings. This is a successful Swift warnings-as-errors build, with
that toolchain debug-symbol limitation recorded rather than a claim of warning-free output.

A final SHA-256 comparison matched all nine changed Swift files and the canonical schema JSON between host and VM.
Both job build directories (the workspace `.build` and the separate wrapper build), plus the external compiler shim,
were deleted. No job build/test processes remained. No generated build product is included in the change.

No online PR-shape, CI check or independent review is claimed. Only the two authorized issue reads were made;
there was no push or PR.
