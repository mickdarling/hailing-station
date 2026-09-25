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
test_() { echo "== test";  swift test --parallel ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}; }
lint()  { echo "== lint";  swiftlint lint --strict --quiet; }

scripts_() {
  echo "== scripts"
  local f dirs=(scripts)
  [[ -d bin ]] && dirs+=(bin)
  while IFS= read -r f; do
    bash -n "$f"
    shellcheck "$f"
  done < <(find "${dirs[@]}" -type f \( -name '*.sh' -o -name 'hail-*' \) | sort)
  scripts/tests/test-testflight.sh
  python3 -m unittest discover -s Tests/LocalIntentEvalTests
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
