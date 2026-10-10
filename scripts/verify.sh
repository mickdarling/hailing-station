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
)
TIMING_PATTERN="($(IFS='|'; echo "${TIMING_SUITES[*]}"))"

# A lane whose capture stays silent this long is stalled (#449): it is stopped and fails at once, naming the tests
# that started and never finished, instead of hanging until the CI job's timeout.
STALL_SECONDS="${HAIL_TEST_STALL_SECONDS:-300}"

# Stops a process and every descendant, deepest first.
stop_tree() {
  local child
  for child in $(pgrep -P "$1" || :); do stop_tree "$child"; done
  kill -TERM "$1" 2>/dev/null || :
}

# The tests (not test cases) the verbose capture shows as started without a matching pass, failure or skip.
unfinished_tests() {
  awk '
    /^◇ Test case / || /^◇ Test run / { next }
    /^◇ Test .* started\.$/ { name = substr($0, index($0, "Test ") + 5); sub(/ started\.$/, "", name); open[name]++; next }
    /^[✔✘↷] Test case / || / recorded an issue / { next }
    /^[✔✘↷] Test .* (passed|failed|skipped)/ {
      name = substr($0, index($0, "Test ") + 5)
      sub(/ (with [0-9]+ test cases? )?(passed|failed|skipped).*$/, "", name)
      if (open[name] > 0) open[name]--
    }
    END { for (name in open) if (open[name] > 0) print "  " name }
  ' "$1" | sort
}

# A slow console consumer must not stall test reporting while deadlines run (#185): output goes to a private file
# and is replayed in full afterwards. A failed capture is kept, and neither failure masks the other.
run_captured() {
  local log pid idle status=0 report=0 stalled=0 dir="${HAIL_TEST_CAPTURE_DIR:-${TMPDIR:-/tmp}}"
  # CI points HAIL_TEST_CAPTURE_DIR at a directory it uploads even when the job fails or times out (#264).
  mkdir -p "$dir"
  log="$(mktemp "$dir/hailing-swift-tests.XXXXXX")"
  "$@" > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    idle=$(( $(date +%s) - $(stat -f %m "$log") ))
    if (( idle >= STALL_SECONDS )); then
      stalled=1
      stop_tree "$pid"
      break
    fi
  done
  wait "$pid" || status=$?
  cat "$log" || report=$?
  if (( stalled )); then
    status=124
    {
      printf 'Stalled: no test output for %s s; stopped (#449). Started and never finished:\n' "$STALL_SECONDS"
      unfinished_tests "$log"
    } >&2 || :
  fi
  if (( status || report )); then
    printf 'Preserved Swift test output: %s\n' "$log" >&2 || :
    (( status == 0 )) || return "$status"
    return "$report"
  fi
  rm -f -- "$log"
}

test_() {
  # Tests are built first so the lanes' --verbose output names each test as it starts, not each compile (#449).
  echo "== build tests"
  swift build --build-tests ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
  echo "== test (parallel)"
  run_captured swift test --skip-build --verbose --parallel --skip "$TIMING_PATTERN"
  echo "== test (timing suites, serial, #208)"
  run_captured swift test --skip-build --verbose --no-parallel --filter "$TIMING_PATTERN"
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
  all) all ;;
  *) echo "usage: scripts/verify.sh {tools|build|test|lint|scripts|sim|all}"; exit 2 ;;
esac
