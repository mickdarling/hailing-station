#!/usr/bin/env bash
# Single source of truth for verification. CI runs this same script (#19, #24).
set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-all}"

# When xcode-select points at CommandLineTools, Swift Testing lives inside Xcode. CI selects Xcode explicitly.
# Warnings are errors in the packages too, not only in the app target (review of #53).
SWIFT_FLAGS=(-Xswiftc -warnings-as-errors)
if ! xcodebuild -version >/dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
  XCODE_FW=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
  SWIFT_FLAGS+=(-Xswiftc "-F$XCODE_FW" -Xlinker "-F$XCODE_FW" -Xlinker -rpath -Xlinker "$XCODE_FW")
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

tools() {
  echo "== tools"
  swift --version 2>&1 | head -1
  xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo "xcodebuild: unavailable (set DEVELOPER_DIR)"
  echo
  swiftlint version | sed 's/^/swiftlint /'
  xcodegen --version
}

build() { echo "== build"; swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}; }
# Suites with wall-clock deadlines or real subprocesses (#208) miss their deadlines when they compete with the
# parallel lane on a loaded runner. They run serially in their own lane until each family gets injected clocks.
# This changes scheduling only: every test still runs and gates, and no assertion is relaxed.
TIMING_SUITES=(
  OwnedReply OwnedStdioChild CodexStdio ProviderObservedSession ProviderInputCoordinator LocalReplyEndpoint
  TmuxDeliveryCommit AmbientWiring RightyoInput RightyoChildProcess SFSpeechRecognizerTranscriber
  TmuxPrePaste TmuxStaleInput TmuxCursorInput TmuxSubmitConfirmation TmuxIntegration TmuxPasteAgent TmuxPasteEnter
  CoachingTransportRegression AmbientSharedAudit CoachingStartupEvent DiagnosticComposition CodexAppServer
)
TIMING_PATTERN="($(IFS='|'; echo "${TIMING_SUITES[*]}"))"
CORE_PATTERN='^HailCoreTests\.'

# A lane whose Swift Testing event stream stays silent this long is stalled (#449): it is stopped and fails at once,
# naming the tests that started and never ended, instead of hanging until the CI job's timeout. The event stream is
# written per event; the captured console output is block-buffered and would lose its tail when the lane is stopped.
STALL_SECONDS="${HAIL_TEST_STALL_SECONDS:-300}"
[[ $STALL_SECONDS =~ ^[1-9][0-9]{0,5}$ ]] || {
  echo "HAIL_TEST_STALL_SECONDS must be a positive integer of at most 6 digits" >&2
  exit 2
}
LANE_PID=""

# Prints a process and every descendant, deepest first.
process_tree() {
  local child
  for child in $(pgrep -P "$1" || :); do process_tree "$child"; done
  echo "$1"
}

# Stops a process and its descendants: TERM, then KILL whatever is left after 5 s, so `wait` cannot block forever.
stop_tree() {
  local pid alive tries pids=()
  while IFS= read -r pid; do pids+=("$pid"); done < <(process_tree "$1")
  kill -TERM "${pids[@]}" 2>/dev/null || :
  for (( tries = 0; tries < 50; tries++ )); do
    alive=0
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    (( alive )) || return 0
    sleep 0.1
  done
  kill -KILL "${pids[@]}" 2>/dev/null || :
}

# Interrupting verify.sh must not leave a test lane running behind it.
stop_lane_and_exit() {
  [[ -z $LANE_PID ]] || stop_tree "$LANE_PID"
  exit 130
}

# The test functions the event stream shows as started without having ended or been skipped.
unfinished_tests() {
  python3 - "$1" <<'PY'
import json, sys
started = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        payload = json.loads(line)["payload"]
    except (ValueError, KeyError, TypeError):
        continue  # A record cut off when the lane was stopped.
    test, kind = payload.get("testID"), payload.get("kind")
    if not test or "/" not in test:
        continue  # Suites and the run itself.
    if kind == "testStarted":
        started[test] = started.get(test, 0) + 1
    elif kind in ("testEnded", "testSkipped") and started.get(test):
        started[test] -= 1
for test in sorted(t for t, n in started.items() if n > 0):
    print("  " + test)
PY
}

# Whether an event stream (JSON Lines, one event each) records a test function starting, not only a suite. One awk,
# no pipeline: under pipefail, `grep … | grep -q` fails when -q exits early and the first grep takes SIGPIPE.
started_a_test() {
  awk '/"kind" *: *"testStarted"/ && /"testID" *: *"[^"]*[.]swift:[0-9]+/ { found = 1; exit }
       END { exit !found }' "$1" 2>/dev/null
}

# A slow console consumer must not stall test reporting while deadlines run (#185): output goes to a private file
# and is replayed in full afterwards. A failed capture is kept, and neither failure masks the other.
run_captured() {
  local log events pid idle status=0 report=0 stalled=0 dir="${HAIL_TEST_CAPTURE_DIR:-${TMPDIR:-/tmp}}"
  # CI points HAIL_TEST_CAPTURE_DIR at a directory it uploads even when the job fails or times out (#264).
  mkdir -p "$dir"
  log="$(mktemp "$dir/hailing-swift-tests.XXXXXX")"
  events="$(mktemp "$dir/hailing-swift-events.XXXXXX")"
  trap stop_lane_and_exit INT TERM
  "$@" --experimental-event-stream-output "$events" --experimental-event-stream-version 0 > "$log" 2>&1 &
  pid=$!
  LANE_PID=$pid
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    idle=$(( $(date +%s) - $(stat -f %m "$events") ))
    if (( idle >= STALL_SECONDS )); then
      stalled=1
      stop_tree "$pid"
      break
    fi
  done
  wait "$pid" || status=$?
  LANE_PID=""
  trap - INT TERM
  cat "$log" || report=$?
  # `swift test` passes a selection that matches nothing (#704): a lane that started no test fails, so a renamed target
  # or pattern can never turn a lane silently green. A test's ID ends in its source location; a suite's does not, so a
  # selection that still matches an empty suite fails too.
  if (( !stalled && status == 0 && report == 0 )) && ! started_a_test "$events"; then
    printf 'No test started in this lane; an empty selection fails (#704): %s\n' "$*" >&2 || :
    status=65
  fi
  if (( stalled )); then
    status=124
    {
      printf 'Stalled: no test event for %s s; stopped (#449). Started and never ended:\n' "$STALL_SECONDS"
      unfinished_tests "$events"
    } >&2 || :
  fi
  if (( status || report )); then
    printf 'Preserved Swift test output: %s\nPreserved Swift test events: %s\n' "$log" "$events" >&2 || :
    (( status == 0 )) || return "$status"
    return "$report"
  fi
  rm -f -- "$log" "$events"
}

test_() {
  # Tests are built once, before the lanes, so each lane's event stream starts with the tests, not a build (#449).
  echo "== build tests"
  swift build --build-tests ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
  # HailCoreTests' waiters run in a process of their own (#704): the other targets' start-up burst once held every
  # cooperative thread, so a 5 ms poll overslept by 10-13 s. Every test still runs once, and a failing half stops the
  # script (set -e) before the next.
  echo "== test (parallel, HailCoreTests, #704)"
  run_captured swift test --skip-build --parallel --filter "$CORE_PATTERN" --skip "$TIMING_PATTERN"
  echo "== test (parallel, other targets)"
  run_captured swift test --skip-build --parallel --skip "$CORE_PATTERN" --skip "$TIMING_PATTERN"
  echo "== test (timing suites, serial, #208)"
  run_captured swift test --skip-build --no-parallel --filter "$TIMING_PATTERN"
}

lint()  { echo "== lint";  swiftlint lint --strict --quiet; }

trace_tests() (
  # The subshell scopes cleanup to this lane. Never install into managed/system Python.
  trace_python="${SPEC_TRACE_PYTHON:-}"
  if [[ -z "$trace_python" ]]; then
    trace_env="$(mktemp -d "${TMPDIR:-/tmp}/hailing-spec-trace.XXXXXX")"
    trap 'rm -rf -- "$trace_env"' EXIT
    python3 -m venv "$trace_env"
    trace_python="$trace_env/bin/python"
    "$trace_python" -m pip install -r scripts/spec-trace-requirements.txt
  fi
  "$trace_python" -m unittest scripts/tests/test_trace.py
)

scripts_() {
  echo "== scripts"
  local f dirs=(scripts)
  [[ -d bin ]] && dirs+=(bin)
  while IFS= read -r f; do
    bash -n "$f"
    shellcheck "$f"
  done < <(find "${dirs[@]}" -type f \( -name '*.sh' -o -name 'hail-*' \) | sort)
  scripts/tests/test-testflight.sh
  scripts/tests/test-host.sh
  trace_tests
  python3 -m unittest discover -s Tests/LocalIntentEvalTests
  python3 -m unittest scripts/tests/test_verify_test_output.py
  # `scripts` is also a standalone entry point; the CLI integration must not rely on `all` building first.
  swift build --product haild ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
  python3 -m unittest discover -s Tests/ReplyCLITests
  if command -v actionlint >/dev/null; then actionlint; else echo "actionlint not installed; skipped"; fi
}

audit_cli() { echo "== audit CLI"; scripts/tests/test-audit-cli.sh; }

sim() {
  echo "== simulator build-for-testing (Hail-iOS)"
  xcodegen generate --quiet
  xcodebuild build-for-testing -project HailingStation.xcodeproj -scheme Hail-iOS \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | pretty
}

mac() {
  echo "== macOS build (Hail-macOS, #266)"
  xcodegen generate --quiet
  xcodebuild build -project HailingStation.xcodeproj -scheme Hail-macOS \
    -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | pretty
}

pretty() {
  if command -v xcbeautify >/dev/null; then xcbeautify --quiet; else cat; fi
}

all() { tools; build; test_; audit_cli; lint; scripts_; echo "== verify: OK"; }

case "$cmd" in
  tools) tools ;;
  build) build ;;
  test) test_ ;;
  lint) lint ;;
  scripts) scripts_ ;;
  sim) sim ;;
  mac) mac ;;
  all) all ;;
  *) echo "usage: scripts/verify.sh {tools|build|test|lint|scripts|sim|mac|all}"; exit 2 ;;
esac
