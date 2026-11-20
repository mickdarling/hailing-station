#!/bin/sh
# Opt-in for this clone only; preserve existing hook configuration (#1270).
set -eu
force=false
case "$#:$*" in
  0:) ;;
  1:--force) force=true ;;
  *) echo "Usage: scripts/install-hooks.sh [--force]" >&2; exit 2 ;;
esac
root=$(git rev-parse --show-toplevel)
cd "$root"
if current=$(git config --get core.hooksPath); then
  if [ "$current" != scripts/hooks ]; then
    echo "Refusing to replace existing core.hooksPath; integrate scripts/hooks/pre-push into your hooks manually." >&2
    exit 1
  fi
  echo "Enabled scripts/hooks for this clone."
  exit 0
fi
hooks_dir=$(git rev-parse --git-common-dir)/hooks
active_hooks=
for hook in "$hooks_dir"/* "$hooks_dir"/.[!.]* "$hooks_dir"/..?*; do
  [ -f "$hook" ] && [ -x "$hook" ] || continue
  case "$hook" in *.sample) continue ;; esac
  active_hooks="$active_hooks
  ${hook##*/}"
done
if [ -n "$active_hooks" ] && [ "$force" = false ]; then
  echo "Refusing to bypass active hooks in the clone's hooks directory:$active_hooks" >&2
  echo "Integrate them manually, or use --force to enable scripts/hooks anyway." >&2
  exit 1
fi
git config --local core.hooksPath scripts/hooks
echo "Enabled scripts/hooks for this clone."
