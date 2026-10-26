#!/usr/bin/env bash
# Create and deliberately upload a Hailing Station archive to TestFlight.
# Never trace deployment credentials, even when invoked with bash -x.
set +x
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
usage: scripts/testflight.sh <archive|upload|release|check-version> [options]

Commands:
  archive   Verify and create a signed Release archive.
  upload    Upload an existing archive to TestFlight Internal Only.
  release   Archive and upload in one deliberate operation.
  check-version
            Confirm that HEAD advances the tracked marketing version.

Options:
  --version VERSION       Marketing version (default: project.yml value).
  --build NUMBER          App Store build number (default: UTC timestamp).
  --archive-path PATH     Archive to create or upload.
  --skip-verify           Skip the local verification suite before archiving.
  --confirm-upload        Required for upload or release.
  --api-key-dir DIR       Private key directory (default: HAIL_ASC_KEY_DIR).
  --dry-run               Validate inputs and show a redacted plan; no build/upload.
  -h, --help              Show this help.

Signing:
  Set HAIL_DEVELOPMENT_TEAM to the local Apple team ID. If it is unset and
  exactly one team is represented by installed provisioning profiles, the
  script uses that team without printing or persisting its identifier.

Authentication:
  With --api-key-dir or HAIL_ASC_KEY_DIR, export locally then upload with altool.
  The owner-only directory outside the repo must contain exactly one
  AuthKey_*.p8 and non-empty key_id and issuer_id files (also owner-only).
  Otherwise upload uses the Apple account configured in Xcode. Never commit
  Apple account, signing, or deployment values to the repository.

Toolchain:
  An explicit DEVELOPER_DIR is preserved. Otherwise use the active Xcode or
  /Applications/Xcode.app/Contents/Developer when CommandLineTools is active.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

select_xcode() {
  [[ ${DEVELOPER_DIR+x} ]] && return
  local active
  active="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$active" == */Contents/Developer && -d "$active" ]]; then
    export DEVELOPER_DIR="$active"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    fail "Xcode not found; install Xcode or explicitly set DEVELOPER_DIR (CommandLineTools cannot archive)"
  fi
}

validate_api_key_dir() {
  # Metadata only: identifiers are read into shell variables below, never files/logs.
  python3 - "$api_key_dir" "$PWD" <<'PY' || fail "invalid API key directory"
import os
from pathlib import Path
import stat
import sys

def reject(message):
    print("error: " + message, file=sys.stderr)
    raise SystemExit(1)

try:
    directory = Path(sys.argv[1])
    repo = Path(sys.argv[2]).resolve()
    resolved = directory.resolve()
    if resolved == repo or repo in resolved.parents:
        reject("API key directory must be outside the repository")
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        reject("API key directory must be owned by the current user with owner-only permissions")
    keys = list(directory.glob("AuthKey_*.p8"))
    if len(keys) != 1:
        reject("API key directory must contain exactly one AuthKey_*.p8")
    for path in [keys[0], directory / "key_id", directory / "issuer_id"]:
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or not info.st_size or not os.access(path, os.R_OK)):
            reject("API key files must be non-empty, readable, owner-only regular files owned by the current user")
except (OSError, RuntimeError):
    reject("API key directory or required files are missing or unreadable")
PY
  local -a keys=("$api_key_dir"/AuthKey_*.p8)
  api_key_path="${keys[0]}"
  api_key_id="$(cat -- "$api_key_dir/key_id" 2>/dev/null)" || fail "cannot read API key identifier"
  api_issuer_id="$(cat -- "$api_key_dir/issuer_id" 2>/dev/null)" || fail "cannot read API issuer identifier"
  [[ -n "${api_key_id//[[:space:]]/}" && -n "${api_issuer_id//[[:space:]]/}" &&
     "$api_key_id" != *$'\n'* && "$api_issuer_id" != *$'\n'* ]] || \
    fail "API key identifiers must be non-empty single lines"
}

dry_run_plan() {
  echo "Dry run: no verification, signing, archive, export, or upload will run."
  echo "DEVELOPER_DIR=<redacted> (selected Xcode)"
  if [[ "$command_name" != upload ]]; then
    echo "Would require a clean reviewed commit with an increased marketing version."
    [[ "$skip_verify" == true ]] || echo "Would run scripts/verify.sh all and scripts/verify.sh sim."
    echo "Would resolve signing privately and archive version $marketing_version ($build_number)."
  fi
  if [[ "$command_name" != archive ]]; then
    if [[ -n "$api_key_dir" ]]; then
      echo "Would export Internal Only IPA (destination=export, automatic signing, version management=false, symbols=true)."
      echo 'xcodebuild -exportArchive -archivePath <redacted> -exportPath <temporary> -exportOptionsPlist <temporary> -allowProvisioningUpdates -authenticationKeyPath <redacted> -authenticationKeyID <redacted> -authenticationKeyIssuerID <redacted>'
      echo 'API_PRIVATE_KEYS_DIR=<redacted> xcrun altool --upload-app -f <temporary IPA> -t ios --apiKey <redacted> --apiIssuer <redacted>'
      echo "Would require UPLOAD SUCCEEDED; CREATE BUILD request timed out fails."
    else
      echo "Would export/upload Internal Only using the Xcode account (destination=upload)."
    fi
  fi
}

filter_upload_status() {
  local line succeeded=false create_build=false timed_out=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//"$api_key_id"/<redacted>}"
    line="${line//"$api_issuer_id"/<redacted>}"
    [[ "$line" != *'UPLOAD SUCCEEDED'* ]] || succeeded=true
    [[ "$line" != *'CREATE BUILD'* ]] || create_build=true
    [[ "$line" != *'timed out'* ]] || timed_out=true
    # Only emit fixed status messages: raw tool output can contain other identities/paths.
  done
  if [[ "$create_build" == true && "$timed_out" == true ]]; then
    echo "CREATE BUILD request timed out (details redacted)." >&2
    return 1
  fi
  [[ "$succeeded" == true ]] || return 1
  echo "UPLOAD SUCCEEDED (details redacted)."
}

project_marketing_version() {
  awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml
}

marketing_version_at_revision() {
  git show "$1:project.yml" 2>/dev/null | \
    awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }'
}

ensure_release_version_changed() {
  local tracked_version previous_version
  tracked_version="$(project_marketing_version)"
  [[ "$marketing_version" == "$tracked_version" ]] || \
    fail "--version must match project.yml ($tracked_version); commit the marketing-version change"

  previous_version="$(marketing_version_at_revision 'HEAD^')" || \
    fail "cannot read the preceding project version; archive a reviewed release commit"
  [[ -n "$previous_version" ]] || \
    fail "the preceding commit has no marketing version"

  python3 - "$previous_version" "$tracked_version" <<'PY' || \
    fail "MARKETING_VERSION must increase in the reviewed release commit ($previous_version -> $tracked_version)"
import re
import sys

versions = sys.argv[1:]
if not all(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) for version in versions):
    raise SystemExit(1)
raise SystemExit(0 if tuple(map(int, versions[1].split("."))) > tuple(map(int, versions[0].split("."))) else 1)
PY
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
  [[ -d "$archive_path" ]] || fail "archive not found"

  local export_options destination=upload
  [[ -z "$api_key_dir" ]] || destination='export'
  ensure_private_temp_dir
  export_options="$private_temp_dir/ExportOptions.plist"
  plutil -create xml1 "$export_options"

  /usr/libexec/PlistBuddy -c 'Add :method string app-store-connect' "$export_options"
  /usr/libexec/PlistBuddy -c "Add :destination string $destination" "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :signingStyle string automatic' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :manageAppVersionAndBuildNumber bool false' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :testFlightInternalTestingOnly bool true' "$export_options"
  /usr/libexec/PlistBuddy -c 'Add :uploadSymbols bool true' "$export_options"

  echo "Uploading archive to TestFlight Internal Only..."
  if [[ -n "$api_key_dir" ]]; then
    # Xcode diagnostics can echo authentication arguments. Discard them rather than
    # persisting a raw log; only our fixed error/status messages reach the terminal.
    xcodebuild -quiet -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$private_temp_dir/output" \
      -exportOptionsPlist "$export_options" \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$api_key_path" \
      -authenticationKeyID "$api_key_id" \
      -authenticationKeyIssuerID "$api_issuer_id" >/dev/null 2>&1 || \
      fail "API-key archive export failed (tool diagnostics suppressed to protect credentials)"

    local -a ipas=("$private_temp_dir/output/"*.ipa)
    [[ ${#ipas[@]} -eq 1 && -f "${ipas[0]}" ]] || fail "export must produce exactly one IPA"
    if ! API_PRIVATE_KEYS_DIR="$api_key_dir" xcrun altool --upload-app \
      -f "${ipas[0]}" -t ios --apiKey "$api_key_id" --apiIssuer "$api_issuer_id" 2>&1 | filter_upload_status; then
      fail "API-key upload failed or lacked UPLOAD SUCCEEDED; a CREATE BUILD timeout is not success"
    fi
  else
    xcodebuild -quiet -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$private_temp_dir/output" \
      -exportOptionsPlist "$export_options" \
      -allowProvisioningUpdates
  fi
  echo "Upload accepted by App Store Connect. Processing continues on Apple's servers."
}

[[ $# -gt 0 ]] || { usage; exit 2; }
command_name="$1"
shift

case "$command_name" in
  archive|upload|release|check-version) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; fail "unknown command" ;;
esac

marketing_version="$(project_marketing_version)"
build_number="$(default_build_number)"
archive_path=""
skip_verify=false
confirm_upload=false
api_key_dir="${HAIL_ASC_KEY_DIR:-}"
dry_run=false

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
    --api-key-dir)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "--api-key-dir requires a directory"
      api_key_dir="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) usage; fail "unknown option" ;;
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

if [[ "$command_name" != check-version ]]; then
  if [[ "$command_name" == upload || "$command_name" == release ]]; then
    [[ "$confirm_upload" == true ]] || fail "upload requires --confirm-upload"
  fi
  select_xcode
  if [[ -n "$api_key_dir" ]]; then
    # Resolve relative directories before tools use them from a different directory.
    [[ "$api_key_dir" == /* ]] || api_key_dir="$PWD/$api_key_dir"
    validate_api_key_dir
  fi
  if [[ "$dry_run" == true ]]; then
    dry_run_plan
    exit 0
  fi
elif [[ "$dry_run" == true ]]; then
  fail "--dry-run requires archive, upload, or release"
fi

case "$command_name" in
  archive)
    prepare_clean_checkout
    ensure_release_version_changed
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
    ensure_release_version_changed
    [[ "$skip_verify" == true ]] || run_verification
    team_id="$(resolve_team_id)"
    prepare_clean_checkout
    archive_app "$team_id"
    upload_archive
    ;;
  check-version)
    prepare_clean_checkout
    ensure_release_version_changed
    echo "Release version advances to $marketing_version."
    ;;
esac
