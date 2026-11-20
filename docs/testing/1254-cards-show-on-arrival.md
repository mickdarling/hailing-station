# Cards and newest reply text on arrival (#1254)

Part of #1254. This record covers local synthetic verification of the amended single commit. Simulator and Mac checks compile only; physical Mac privacy/card and overlapping-reply checks remain deferred. No host daemon, wire protocol, installed build, version identifier, delivery, or upload changes are included.

## Behavior and review repairs

Display admission checks the current connection generation, negotiated card capability, and live listed target. Privacy, duck, media, and ambient recovery gate speech rather than visible content. Cards received through the socket before the first target list now enter the same bounded buffer used during reconnect-pending. Ready snapshots recheck admission without granting or renewing speech permission.

The buffer retains at most `ConversationLog.limit` (200) cards, coalesces exact duplicates, preserves arrival order, and evicts the oldest card at capacity. Generation replacement, endpoint replacement, explicit disconnect, and host removal discard held cards for the old connection. A target replacement or retirement discards its held cards; restoring that target cannot revive them. Eviction and invalidation logs contain fixed messages only, without card text, endpoint, target, update identity, or counts.

The shared iOS/Mac reply panel displays the newest received text while playback controls retain the playing reply. When these differ, “Latest reply” includes the displayed reply's own host, target, and status in both its visible text and accessibility label. The controls still identify their own source and status. Playback order and completion remain unchanged.

## Synthetic coverage

- `SessionUpdateDisplayBufferTests`: scripted WebSocket frames traverse the real connection loop and `receiveSessionUpdate`; cards arriving before targets, with and without reconnect-pending, wait and then appear once. Their denied speech permission stays denied after readiness and duplicates. Tests also cover all 201 arrivals at the 200-card bound, exact oldest eviction and display order, target replacement/retirement and restoration, automatic socket reconnection with a new generation, host replacement, explicit disconnect, and host removal. Every invalidation checks the exact content-free log.
- `HostConnectionSessionUpdateTests`: card and duplicate receipt, pending privacy, provenance/target rejection, and unnegotiated capability failure. The private/public duplicate assertion runs after the duplicate's callback completes.
- `CardsArrivalTests`: visible silent and spoken-card text under pending privacy, duck, and media; ready display during ambient recovery; speech still requires ambient listening and exact identity.
- `ReplyPanelArrivalTests`: different hosts/targets for the playing and newest replies; newest text/source is available immediately, controls retain the first source, all first-reply segments precede the second, and arrival never cancels playback.
- `ProactiveReceiptCapacityTests`: bounded visible history under privacy pressure, retained speech retirement and capacity checks, and ordinary audio behavior.

`ArrivalSocket.flush()` suspends on continuations and resumes when the connection asks for its next frame. The receive loop awaits its store callback first, so that next receive is an observed processing barrier, including for duplicates that do not change conversation count. Setup and privacy/failure waits use this barrier or Observation notifications. The added/changed tests and their arrival/capacity support have no sleeps, polling, or semaphores.

## Commands and isolation

Before each phase, the external host-slot gate and then the voice-quiet gate must succeed. Commands run sequentially at background priority with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `$SCRATCH` denotes external scratch; no private host paths are committed. Scratch redirects temporary files, Swift package caches/configuration, module caches, Xcode user state, package clones, and derived data. The scratch Xcode wrapper adds `-jobs 2`; repository scripts are unchanged.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
CHANGED_SUITES='CardsArrivalTests|SessionUpdateDisplayBufferTests|ReplyPanelArrivalTests|HostConnectionSessionUpdateTests|ProactiveReceiptCapacityTests'
taskpolicy -b swift build --build-tests -j 2 \
  --cache-path "$SCRATCH/cache" --config-path "$SCRATCH/config" --security-path "$SCRATCH/security"
# Mutation build/test uses the same cache flags and -j 2, and restores the source byte-for-byte.
taskpolicy -b swift test --skip-build --no-parallel -j 2 \
  --cache-path "$SCRATCH/cache" --config-path "$SCRATCH/config" --security-path "$SCRATCH/security" \
  --filter socketCardsBeforeTargetsWaitForReadinessWithoutRenewingSpeech
# Restored source is rebuilt before the serial run.
taskpolicy -b swift test --no-parallel -j 2 \
  --cache-path "$SCRATCH/cache" --config-path "$SCRATCH/config" --security-path "$SCRATCH/security" \
  --filter "$CHANGED_SUITES"
# Five sequential invocations in the gated parallel-repetition phase:
taskpolicy -b swift test --parallel --skip-build -j 2 \
  --cache-path "$SCRATCH/cache" --config-path "$SCRATCH/config" --security-path "$SCRATCH/security" \
  --filter "$CHANGED_SUITES"
# Every changed Swift file, including test support:
taskpolicy -b swiftlint lint --strict --no-cache \
  Apps/Hail-iOS/ReplyPlaybackView.swift \
  Sources/HailCore/Replies/ReplyPlaybackController.swift \
  Sources/HailCore/Transport/HostConnectionStore+ProactivePlayback.swift \
  Sources/HailCore/Transport/HostConnectionStore.swift \
  Tests/HailCoreTests/CardsArrivalTestSupport.swift \
  Tests/HailCoreTests/CardsArrivalTests.swift \
  Tests/HailCoreTests/HostConnectionSessionUpdateTests.swift \
  Tests/HailCoreTests/ProactiveReceiptCapacityTestSupport.swift \
  Tests/HailCoreTests/ProactiveReceiptCapacityTests.swift \
  Tests/HailCoreTests/ReplyPanelArrivalTests.swift \
  Tests/HailCoreTests/SessionUpdateDisplayBufferTests.swift
taskpolicy -b scripts/verify.sh sim
taskpolicy -b scripts/verify.sh mac
# This branch predates the checker; use main's copy without changing repository scripts.
git show origin/main:scripts/check-host-paths.py > "$SCRATCH/check-host-paths.py"
python3 "$SCRATCH/check-host-paths.py" origin/main~1..HEAD
```

## Results

Work durations exclude the preceding host-slot and quiet gates. All required phases passed both gates, ran sequentially at background priority, and used two build jobs.

| Check | Result |
| --- | --- |
| Initial review test build (`review-build.log`) | Exit 0; 116.374 seconds work. |
| Strict uncached lint (`review-lint.log`) | Exit 0; zero violations in all 11 changed Swift files; 0.778 seconds work. |
| Buffer-branch mutation (`review-mutation.log`) | Mutant build exit 0 (89.24 seconds); targeted test exit 1 as expected: one test, two argument cases, four issues, 0.065 seconds test; 100.961 seconds work for build/test/restoration. |
| Restored serial (`review-serial.log`) | Exit 0; 16 tests in five suites passed in 1.005 seconds; 60.167 seconds work including rebuild. |
| Changed suites, parallel (`review-parallel-1.log` through `review-parallel-5.log`) | 5/5 passed; 16 tests in five suites each. Work durations: 8.405, 6.706, 5.550, 5.612, 6.307 seconds; 32.713 seconds total phase work. |
| `taskpolicy -b scripts/verify.sh sim` (`review-sim.log`) | Exit 0; `Test Build Succeeded`; 55.754 seconds work; exactly one compile-only invocation. |
| `taskpolicy -b scripts/verify.sh mac` (`review-mac.log`) | Exit 0; `Build Succeeded`; 49.847 seconds work; exactly one compile-only invocation. |
| Main-copy host-path checker, `origin/main~1..HEAD` | Exit 0; one amended commit checked. |
| Scope and diff hygiene | Exactly four production files by the checker's exclusions; zero renames; `git diff --check` passed. |

Removing only the buffering branch in `receiveSessionUpdate` made both socket-driven arrival cases fail: without reconnect-pending and with reconnect-pending. Each case failed the held-card assertion and the post-readiness display assertion. The mutation source was restored byte-for-byte before the serial rebuild and all five parallel repetitions; no mutation remains.

The first review lint attempt exited 2 on a 122-character test setup line. Wrapping that line produced the zero-violation result above. No unit run required a retry. Simulator and Mac checks compiled only: no app launch, simulator test execution, physical check, installation, TestFlight operation, or upload occurred. Logs remain in external scratch; this record contains sanitized evidence only.

## Scope and remaining proof

Exactly four production files, zero renames, against `cc0bea45f3d2345ea35a73f08962b023b267d3dd`, using `scripts/pr-shape.py` exclusions. Seven test/support files and this record are excluded from that count. No security-critical paths, host code, protocol, scripts, workflows, installed builds, or version identifiers change. One local amended commit; no push or PR operation.

The owner's physical Mac privacy/card and overlapping-reply checks remain unperformed. Local synthetic tests and compile checks do not demonstrate live captured-output behavior or physical audio playback.
