#!/usr/bin/env bash
# Run from the fixture checkout on a Mac with Xcode and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/station-fixture-release.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcodegen generate --quiet

check_release() {
  local scheme=$1 destination=$2 product=$3 binary arch architectures
  binary="$scratch/Build/Products/$product"
  # Keep the Release optimizer and local symbols. Put the app code in the executable we inspect.
  xcodebuild -quiet -project HailingStation.xcodeproj -scheme "$scheme" \
    -configuration Release -destination "$destination" -derivedDataPath "$scratch" \
    CODE_SIGNING_ALLOWED=NO DEPLOYMENT_POSTPROCESSING=NO STRIP_INSTALLED_PRODUCT=NO \
    ENABLE_DEBUG_DYLIB=NO build

  architectures=$(xcrun lipo -archs "$binary")
  if [[ -z "$architectures" ]]; then
    echo "No architectures to inspect in $product" >&2
    return 1
  fi
  for arch in $architectures; do
    xcrun nm -arch "$arch" -U -j "$binary" | xcrun swift-demangle > "$scratch/symbols"
    if ! grep -Fq '.HailApp' "$scratch/symbols"; then
      echo "Missing app symbols in $product ($arch)" >&2
      return 1
    fi
    if grep -E 'StationScreenSeed|StationSeedConnector|StationSeedSocket' "$scratch/symbols"; then
      echo "Found station fixture symbols in $product ($arch)" >&2
      return 1
    fi
    echo "Checked $product ($arch)"
  done
}

check_release Hail-macOS 'generic/platform=macOS' 'Release/Hail-macOS.app/Contents/MacOS/Hail-macOS'
check_release Hail-iOS 'generic/platform=iOS' 'Release-iphoneos/Hail-iOS.app/Hail-iOS'
check_release Hail-iOS 'generic/platform=iOS Simulator' 'Release-iphonesimulator/Hail-iOS.app/Hail-iOS'
