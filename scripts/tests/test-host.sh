#!/usr/bin/env bash
# scripts/host.sh against a scratch tree: fake binary, fake launchctl, no real LaunchAgent touched (#246).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/hailing-station-host-test.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

export HAIL_HOST_ROOT="$scratch/root" HAIL_CONFIG_DIR="$scratch/config" HAIL_LAUNCH_AGENTS="$scratch/agents"
export HAIL_LOG_DIR="$scratch/logs" HAIL_BIN_DIR="$scratch/bin" HAIL_READY_SECONDS=3
export HAIL_LAUNCHCTL="$scratch/launchctl"
host="$repo_root/scripts/host.sh"
mkdir -p "$HAIL_CONFIG_DIR"

expect_failure() {
  local why="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "expected failure: $why" >&2; exit 1; fi
}

# A launchctl that records calls and, on bootstrap, writes the readiness line the real daemon would.
cat > "$HAIL_LAUNCHCTL" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$scratch/launchctl.calls"
if [[ "\$1" == bootstrap ]]; then echo '{"event":"listener_ready"}' > "$HAIL_LOG_DIR/haild.err.log"; fi
if [[ "\$1" == print ]]; then [[ "\$2" == *com.hailingstation.haild ]] && [[ -f "$scratch/loaded" ]]; fi
exit 0
FAKE
chmod +x "$HAIL_LAUNCHCTL"

make_binary() { printf '#!/bin/sh\n# %s\n' "$1" > "$scratch/haild-$1"; chmod +x "$scratch/haild-$1"; }
make_binary one
make_binary two
make_binary three

# Nothing installed or configured yet.
expect_failure "plist without an install" "$host" plist
"$host" install --binary "$scratch/haild-one" >/dev/null
first="$(readlink "$HAIL_HOST_ROOT/current")"
[[ -x "$first/haild" && ! -w "$first/haild" ]] || { echo "release is not an immutable executable" >&2; exit 1; }
[[ "$(readlink "$HAIL_BIN_DIR/haild")" == "$HAIL_HOST_ROOT/current/haild" ]] || { echo "PATH link wrong" >&2; exit 1; }
expect_failure "plist without host.json" "$host" plist

# A minimal config: absent optional keys add nothing (plutil reports a missing key on stdout).
echo '{"bind": "127.0.0.1", "port": 8765}' > "$HAIL_CONFIG_DIR/host.json"
"$host" plist > "$scratch/minimal.plist"
[[ "$(plutil -extract ProgramArguments raw -o - "$scratch/minimal.plist")" == 7 ]] \
  || { echo "minimal config produced extra arguments" >&2; exit 1; }
if plutil -extract EnvironmentVariables raw -o - "$scratch/minimal.plist" >/dev/null 2>&1; then
  echo "minimal config produced an environment" >&2; exit 1
fi

# Config validation.
echo '{"bind": "127.0.0.1"}' > "$HAIL_CONFIG_DIR/host.json"
expect_failure "missing port" "$host" plist
echo '{"port": 8765}' > "$HAIL_CONFIG_DIR/host.json"
expect_failure "missing bind" "$host" plist
echo '{"bind": "localhost", "port": 8765}' > "$HAIL_CONFIG_DIR/host.json"
expect_failure "bind that is not an IP literal" "$host" plist
printf '%s\n' '{"bind": "127.0.0.1\n--bind\n0.0.0.0", "port": 8765}' > "$HAIL_CONFIG_DIR/host.json"
expect_failure "newline smuggling an extra argument" "$host" plist
echo '{"bind": "127.0.0.1", "port": 8765, "ambient": {"rightyo": "/r", "config": "/c", "target": "--reply-socket"}}' \
  > "$HAIL_CONFIG_DIR/host.json"
expect_failure "target that is a flag" "$host" plist
echo '{"bind": "127.0.0.1", "port": 8765, "hostID": "bad host"}' > "$HAIL_CONFIG_DIR/host.json"
expect_failure "invalid host ID" "$host" plist
echo '{"bind": "127.0.0.1", "port": 70000}' > "$HAIL_CONFIG_DIR/host.json"
expect_failure "out-of-range port" "$host" plist
echo '{"bind": "127.0.0.1", "port": 8765, "ambient": {"rightyo": "rel/rightyo", "config": "/c", "target": "t"}}' \
  > "$HAIL_CONFIG_DIR/host.json"
expect_failure "relative ambient path" "$host" plist
echo 'not json' > "$HAIL_CONFIG_DIR/host.json"
expect_failure "invalid JSON" "$host" plist

# A full config becomes exactly these daemon arguments, with the host ID in the environment.
cat > "$HAIL_CONFIG_DIR/host.json" <<'JSON'
{"bind": "127.0.0.1", "port": 8765, "hostID": "studio.local", "singleTerminalReplyFallback": true,
 "deviceDiagnostics": false, "ambient": {"rightyo": "/opt/rightyo", "config": "/opt/r.json", "target": "tmux:t"}}
JSON
"$host" plist > "$scratch/agent.plist"
plutil -lint -s "$scratch/agent.plist" >/dev/null
arguments=()
count="$(plutil -extract ProgramArguments raw -o - "$scratch/agent.plist")"
for (( i = 0; i < count; i++ )); do arguments+=("$(plutil -extract "ProgramArguments.$i" raw -o - "$scratch/agent.plist")"); done
expected=("$first/haild" run --bind 127.0.0.1 --port 8765 --personal-terminal --single-terminal-reply-fallback
  --ambient-rightyo /opt/rightyo --ambient-rightyo-config /opt/r.json --ambient-target tmux:t)
[[ "${arguments[*]}" == "${expected[*]}" ]] || { echo "unexpected arguments: ${arguments[*]}" >&2; exit 1; }
[[ "$(plutil -extract EnvironmentVariables.HAIL_HOST_ID raw -o - "$scratch/agent.plist")" == studio.local ]] \
  || { echo "host ID not in environment" >&2; exit 1; }

# Restart replaces the legacy job and the managed one, then waits for readiness.
"$host" restart >/dev/null
grep -q "bootout gui/$(id -u)/com.mickdarling.hailing-station-session" "$scratch/launchctl.calls"
grep -q "bootstrap gui/$(id -u) $HAIL_LAUNCH_AGENTS/com.hailingstation.haild.plist" "$scratch/launchctl.calls"
touch "$scratch/loaded"
"$host" status >/dev/null

# A newer install without a restart is reported as drift.
"$host" install --binary "$scratch/haild-two" >/dev/null
[[ "$(readlink "$HAIL_HOST_ROOT/current")" != "$first" ]] || { echo "second release not current" >&2; exit 1; }
set +e; "$host" status >/dev/null; drift=$?; set -e
[[ "$drift" == 3 ]] || { echo "expected drift status 3, got $drift" >&2; exit 1; }

# An interrupted install leaves a read-only partial copy; the next install of that digest still succeeds.
digest="$(shasum -a 256 "$scratch/haild-three" | cut -c1-16)"
mkdir -p "$HAIL_HOST_ROOT/releases/$digest.tmp"
cp "$scratch/haild-three" "$HAIL_HOST_ROOT/releases/$digest.tmp/haild"
chmod 0555 "$HAIL_HOST_ROOT/releases/$digest.tmp/haild"
"$host" install --binary "$scratch/haild-three" >/dev/null
[[ -x "$HAIL_HOST_ROOT/releases/$digest/haild" && ! -e "$HAIL_HOST_ROOT/releases/$digest.tmp" ]] \
  || { echo "stale partial install was not recovered" >&2; exit 1; }
[[ "$(stat -f %Lp "$HAIL_LOG_DIR")" == 700 ]] || { echo "log directory is not private" >&2; exit 1; }

# A daemon that never reports ready fails the restart.
printf '#!/usr/bin/env bash\nexit 0\n' > "$HAIL_LAUNCHCTL"
expect_failure "no readiness" "$host" restart
echo "test-host: OK"
