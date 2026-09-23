#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/hailing-station-testflight-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/scripts"
cp "$repo_root/scripts/testflight.sh" "$fixture/scripts/testflight.sh"
chmod +x "$fixture/scripts/testflight.sh"

cd "$fixture"
git init --quiet
git config user.email test@example.invalid
git config user.name "Test Runner"
git config commit.gpgSign false
git add scripts/testflight.sh

write_version() {
  printf 'settings:\n  base:\n    MARKETING_VERSION: "%s"\n' "$1" > project.yml
}

commit_version() {
  write_version "$1"
  git add project.yml
  git commit --quiet -m "Version $1"
}

commit_version 0.1.0
commit_version 0.1.1
scripts/testflight.sh check-version >/dev/null

git commit --quiet --allow-empty -m "No version change"
if scripts/testflight.sh check-version >/dev/null 2>&1; then
  echo "expected an unchanged release version to be rejected" >&2
  exit 1
fi

commit_version 0.1.0
if scripts/testflight.sh check-version >/dev/null 2>&1; then
  echo "expected a decreasing release version to be rejected" >&2
  exit 1
fi

commit_version 0.2.0
if scripts/testflight.sh check-version --version 0.2.1 >/dev/null 2>&1; then
  echo "expected an untracked version override to be rejected" >&2
  exit 1
fi

scripts/testflight.sh check-version >/dev/null
echo "test-testflight: OK"
