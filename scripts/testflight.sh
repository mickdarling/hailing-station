#!/usr/bin/env bash
# Create and deliberately upload a Hailing Station archive to TestFlight.
set -euo pipefail

cd "$(dirname "$0")/.."

private_temp_dir=""
cleanup() {
  if [[ -n "$private_temp_dir" && -d "$private_temp_dir" ]]; then
    rm -rf -- "$private_temp_dir"
  fi
}
trap cleanup EXIT

ensure_private_temp_dir() {
  if [[ -z "$private_temp_dir" ]]; then
    umask 077
    private_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hailing-station-release.XXXXXX")"
  fi
}

usage() {
  cat <<'EOF'
usage: scripts/testflight.sh <archive|upload|release> [options]

Commands:
  archive   Verify and create a signed Release archive.
  upload    Upload an existing archive to TestFlight Internal Only.
  release   Archive and upload in one deliberate operation.

Options:
  --version VERSION       Marketing version (default: project.yml value).
  --build NUMBER          App Store build number (default: UTC timestamp).
  --archive-path PATH     Archive to create or upload.
  --skip-verify           Skip the local verification suite before archiving.
  --confirm-upload        Required for upload or release.
  -h, --help              Show this help.

Signing:
  Set HAIL_DEVELOPMENT_TEAM to the local Apple team ID. If it is unset and
  exactly one team is represented by installed provisioning profiles, the
  script uses that team without printing or persisting its identifier.

Authentication:
  Upload uses the Apple account configured in Xcode. Never commit Apple account,
  signing, or deployment values to the repository.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

project_marketing_version() {
  awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml
}

resolve_team_id() {
  if [[ -n "${HAIL_DEVELOPMENT_TEAM:-}" ]]; then
    printf '%s\n' "$HAIL_DEVELOPMENT_TEAM"
    return
  fi

  local existing profile team_id
  local -a team_ids=()
  local -a profile_dirs=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
  )

  while IFS= read -r -d '' profile; do
    team_id="$(security cms -D -i "$profile" 2>/dev/null | \
      plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null || true)"
    [[ -n "$team_id" ]] || continue
    for existing in "${team_ids[@]-}"; do
      [[ "$existing" == "$team_id" ]] && continue 2
    done
    team_ids+=("$team_id")
  done < <(find "${profile_dirs[@]}" -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) \
    -print0 2>/dev/null || true)

  if [[ ${#team_ids[@]} -eq 1 ]]; then
    printf '%s\n' "${team_ids[0]}"
    return
  fi

  if [[ ${#team_ids[@]} -eq 0 ]]; then
    fail "no local Apple development team found; set HAIL_DEVELOPMENT_TEAM"
  fi
  fail "multiple local Apple teams found; set HAIL_DEVELOPMENT_TEAM explicitly"
}

ensure_clean_checkout() {
  local checkout_status ignored_input
  checkout_status="$(git status --porcelain --untracked-files=all)"
  [[ -z "$checkout_status" ]] || \
    fail "tracked or untracked checkout changes exist; archive a reviewed commit"

  while IFS= read -r -d '' ignored_input; do
    fail "ignored file exists in a build-input root; remove it before archiving: $ignored_input"
  done < <(git ls-files -z --others --ignored --exclude-standard -- Apps/Hail-iOS Sources)
}

prepare_clean_checkout() {
  rm -f -- Apps/Hail-iOS/Hail.entitlements
  ensure_clean_checkout
}

default_build_number() {
  python3 -c 'import time; print(time.time_ns() // 100)'
}

run_verification() {
  scripts/verify.sh all
  scripts/verify.sh sim
}

archive_app() {
  local team_id="$1"
  local build_config
  mkdir -p "$(dirname "$archive_path")"
  xcodegen generate --quiet
  ensure_private_temp_dir
  build_config="$private_temp_dir/Release.xcconfig"
  printf 'DEVELOPMENT_TEAM = %s\nMARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' \
    "$team_id" "$marketing_version" "$build_number" > "$build_config"

  echo "Archiving Hailing Station ${marketing_version} (${build_number})..."
  xcodebuild -quiet archive \
    -project HailingStation.xcodeproj \
    -scheme Hail-iOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates \
    -xcconfig "$build_config"

  [[ -d "$archive_path" ]] || fail "Xcode reported success but did not create the archive"
  echo "Archive ready: $archive_path"
}

upload_archive() {
  [[ "$confirm_upload" == true ]] || fail "upload requires --confirm-upload"
  [[ -d "$archive_path" ]] || fail "archive not found: $archive_path"

  local export_options
  ensure_private_temp_dir
  export_options="$private_temp_dir/ExportOptions.plist"
  plutil -create xml1 "$export_options"

  /usr/libexec/PlistBuddy -c 'Add :method string app-store-connect' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :destination string upload' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :signingStyle string automatic' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :manageAppVersionAndBuildNumber bool false' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :testFlightInternalTestingOnly bool true' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :uploadSymbols bool true' "$export_options"

  echo "Uploading $(basename "$archive_path") to TestFlight Internal Only..."
  xcodebuild -quiet -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$private_temp_dir/output" \
    -exportOptionsPlist "$export_options" \
    -allowProvisioningUpdates
  echo "Upload accepted by App Store Connect. Processing continues on Apple's servers."
}

[[ $# -gt 0 ]] || { usage; exit 2; }
command_name="$1"
shift

case "$command_name" in
  archive|upload|release) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; fail "unknown command: $command_name" ;;
esac

marketing_version="$(project_marketing_version)"
build_number="$(default_build_number)"
archive_path=""
skip_verify=false
confirm_upload=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      marketing_version="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || fail "--build requires a value"
      build_number="$2"
      shift 2
      ;;
    --archive-path)
      [[ $# -ge 2 ]] || fail "--archive-path requires a value"
      archive_path="$2"
      shift 2
      ;;
    --skip-verify)
      skip_verify=true
      shift
      ;;
    --confirm-upload)
      confirm_upload=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) usage; fail "unknown option: $1" ;;
  esac
done

[[ "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail "version must use numeric major.minor.patch form"
[[ "$build_number" =~ ^[1-9][0-9]{0,17}$ ]] || \
  fail "build must be 1-18 digits and cannot start with zero"

if [[ -z "$archive_path" ]]; then
  archive_path="$PWD/artifacts/HailingStation-${marketing_version}-${build_number}.xcarchive"
elif [[ "$archive_path" != /* ]]; then
  archive_path="$PWD/$archive_path"
fi

case "$command_name" in
  archive)
    prepare_clean_checkout
    [[ "$skip_verify" == true ]] || run_verification
    team_id="$(resolve_team_id)"
    prepare_clean_checkout
    archive_app "$team_id"
    ;;
  upload)
    upload_archive
    ;;
  release)
    prepare_clean_checkout
    [[ "$skip_verify" == true ]] || run_verification
    team_id="$(resolve_team_id)"
    prepare_clean_checkout
    archive_app "$team_id"
    upload_archive
    ;;
esac
