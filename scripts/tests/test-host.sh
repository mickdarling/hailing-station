#!/usr/bin/env bash
# scripts/host.sh against a scratch tree: fake binaries and a stateful fake launchctl; no real LaunchAgent is
# touched (#246).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# Canonical (no /var -> /private/var symlink), so resolved links compare equal to scratch paths.
scratch="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hailing-station-host-test.XXXXXX")" && pwd -P)"
# Releases are read-only by design, so make the scratch tree writable before removing it.
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf -- "$scratch"' EXIT

export HAIL_HOST_ROOT="$scratch/root" HAIL_CONFIG_DIR="$scratch/config" HAIL_LAUNCH_AGENTS="$scratch/agents"
export HAIL_LOG_DIR="$scratch/logs" HAIL_BIN_DIR="$scratch/bin" HAIL_READY_SECONDS=2 HAIL_SETTLE_SECONDS=0
export HAIL_LAUNCHCTL="$scratch/launchctl"
host="$repo_root/scripts/host.sh"
jobs="$scratch/jobs"
mkdir -p "$HAIL_CONFIG_DIR" "$jobs"
domain="gui/$(id -u)"

fail() { echo "test-host: $*" >&2; exit 1; }
expect_failure() {
  local why="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "expected failure: $why"; fi
}
mode() { echo "$1" > "$scratch/mode"; }

# Loaded jobs are files in $jobs holding the program path. `mode` decides what the next bootstrap does:
# ok (ready), never-ready, bootstrap-fails, or flapping (a new pid on every print).
cat > "$HAIL_LAUNCHCTL" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$scratch/launchctl.calls"
mode="\$(cat "$scratch/mode")"
case "\$1" in
  bootout) rm -f "$jobs/\${2##*/}" ;;
  bootstrap)
    [[ "\$mode" == bootstrap-fails ]] && exit 5
    label="\$(plutil -extract Label raw -o - "\$3")"
    plutil -extract ProgramArguments.0 raw -o - "\$3" > "$jobs/\$label"
    if [[ "\$mode" != never-ready ]]; then
      echo '{"event":"listener_ready"}' > "$HAIL_LOG_DIR/haild.err.log"
      touch "$HAIL_CONFIG_DIR/replies.sock"
    fi ;;
  print)
    job="$jobs/\${2##*/}"
    [[ -f "\$job" ]] || exit 113
    pid=42; [[ "\$mode" == flapping ]] && pid=\$RANDOM
    printf '\tstate = running\n\tprogram = %s\n\tpid = %s\n' "\$(cat "\$job")" "\$pid" ;;
esac
exit 0
FAKE
chmod +x "$HAIL_LAUNCHCTL"
mode ok

make_binary() { printf '#!/bin/sh\n# %s\n' "$1" > "$scratch/haild-$1"; chmod +x "$scratch/haild-$1"; }
for name in one two three; do make_binary "$name"; done
release_dir() { echo "$HAIL_HOST_ROOT/releases/$(shasum -a 256 "$scratch/haild-$1" | cut -c1-16)"; }

# Install only stages: nothing on PATH, nothing running.
expect_failure "plist without an install" "$host" plist
"$host" install --binary "$scratch/haild-one" >/dev/null
[[ "$(readlink "$HAIL_HOST_ROOT/current")" == "$(release_dir one)" ]] || fail "install did not stage release one"
[[ -x "$(release_dir one)/haild" && ! -w "$(release_dir one)/haild" && ! -w "$(release_dir one)" ]] \
  || fail "release is not immutable"
[[ ! -e "$HAIL_BIN_DIR/haild" ]] || fail "install changed the PATH haild before a restart"
"$host" install --binary "$scratch/haild-one" >/dev/null || fail "reinstalling the same release failed"
expect_failure "plist without host.json" "$host" plist

# A minimal config: absent optional keys add nothing (plutil reports a missing key on stdout).
echo '{"bind": "127.0.0.1", "port": 8765}' > "$HAIL_CONFIG_DIR/host.json"
"$host" plist > "$scratch/minimal.plist"
[[ "$(plutil -extract ProgramArguments raw -o - "$scratch/minimal.plist")" == 7 ]] \
  || fail "minimal config produced extra arguments"
if plutil -extract EnvironmentVariables raw -o - "$scratch/minimal.plist" >/dev/null 2>&1; then
  fail "minimal config produced an environment"
fi

# Config validation, all before anything runs.
bad_config() { printf '%s\n' "$2" > "$HAIL_CONFIG_DIR/host.json"; expect_failure "$1" "$host" plist; }
bad_config "missing port" '{"bind": "127.0.0.1"}'
bad_config "out-of-range port" '{"bind": "127.0.0.1", "port": 70000}'
bad_config "missing bind" '{"port": 8765}'
bad_config "bind that is not an IP literal" '{"bind": "localhost", "port": 8765}'
bad_config "newline smuggling an extra argument" '{"bind": "127.0.0.1\n--bind\n0.0.0.0", "port": 8765}'
bad_config "invalid host ID" '{"bind": "127.0.0.1", "port": 8765, "hostID": "bad host"}'
bad_config "non-boolean flag" '{"bind": "127.0.0.1", "port": 8765, "deviceDiagnostics": 1}'
bad_config "invalid JSON" 'not json'
ambient='"ambient": {"rightyo": "/opt/rightyo", "config": "/opt/r.json", "target": "tmux:t"}'
bad_config "ambient without the reply fallback" "{\"bind\": \"127.0.0.1\", \"port\": 8765, $ambient}"
bad_config "relative ambient path" \
  '{"bind": "127.0.0.1", "port": 8765, "singleTerminalReplyFallback": true,
    "ambient": {"rightyo": "rel", "config": "/c", "target": "t"}}'
bad_config "target that is a flag" \
  '{"bind": "127.0.0.1", "port": 8765, "singleTerminalReplyFallback": true,
    "ambient": {"rightyo": "/r", "config": "/c", "target": "--reply-socket"}}'

# A full config becomes exactly these daemon arguments, with the host ID in the environment.
printf '%s\n' "{\"bind\": \"127.0.0.1\", \"port\": 8765, \"hostID\": \"studio.local\",
  \"singleTerminalReplyFallback\": true, \"deviceDiagnostics\": true, $ambient}" > "$HAIL_CONFIG_DIR/host.json"
"$host" plist > "$scratch/agent.plist"
plutil -lint -s "$scratch/agent.plist" >/dev/null
arguments=()
count="$(plutil -extract ProgramArguments raw -o - "$scratch/agent.plist")"
for (( i = 0; i < count; i++ )); do arguments+=("$(plutil -extract "ProgramArguments.$i" raw -o - "$scratch/agent.plist")"); done
expected=("$(release_dir one)/haild" run --bind 127.0.0.1 --port 8765 --personal-terminal
  --single-terminal-reply-fallback --device-diagnostics
  --ambient-rightyo /opt/rightyo --ambient-rightyo-config /opt/r.json --ambient-target tmux:t)
[[ "${arguments[*]}" == "${expected[*]}" ]] || fail "unexpected arguments: ${arguments[*]}"
[[ "$(plutil -extract EnvironmentVariables.HAIL_HOST_ID raw -o - "$scratch/agent.plist")" == studio.local ]] \
  || fail "host ID not in the environment"

# Restart replaces the legacy job, then the managed one, then starts and waits; PATH follows the running release.
echo "legacy" > "$jobs/com.mickdarling.hailing-station-session"
mkdir -p "$HAIL_LOG_DIR"
echo "old run" > "$HAIL_LOG_DIR/haild.err.log"
: > "$scratch/launchctl.calls"
"$host" restart >/dev/null
grep -E '^(bootout|bootstrap)' "$scratch/launchctl.calls" > "$scratch/order"
printf '%s\n' "bootout $domain/com.mickdarling.hailing-station-session" "bootout $domain/com.hailingstation.haild" \
  "bootstrap $domain $HAIL_LAUNCH_AGENTS/com.hailingstation.haild.plist" | diff - "$scratch/order" >/dev/null \
  || fail "unexpected launchctl order: $(tr '\n' ';' < "$scratch/order")"
[[ "$(cat "$HAIL_LOG_DIR/haild.err.log.1")" == "old run" ]] || fail "previous log was not kept"
[[ "$(stat -f %Lp "$HAIL_LOG_DIR")" == 700 ]] || fail "log directory is not private"
[[ "$(readlink -f "$HAIL_BIN_DIR/haild")" == "$(release_dir one)/haild" ]] || fail "PATH haild is not the running release"
"$host" status > "$scratch/status" || fail "healthy status exited non-zero"
grep -q "running: $(release_dir one)/haild (running)" "$scratch/status" || fail "status did not report the daemon"

# Staging a new release changes nothing running and is reported as staged, not as drift.
"$host" install --binary "$scratch/haild-two" >/dev/null
[[ "$(readlink -f "$HAIL_BIN_DIR/haild")" == "$(release_dir one)/haild" ]] || fail "install moved the PATH haild"
"$host" status > "$scratch/status" || fail "a staged release is not a problem"
grep -q "staged and not started" "$scratch/status" || fail "status did not mention the staged release"

# A new release that never becomes ready is rolled back to the previous agent; PATH stays on release one.
mode never-ready
expect_failure "restart that never becomes ready" "$host" restart
[[ "$(cat "$jobs/com.hailingstation.haild")" == "$(release_dir one)/haild" ]] || fail "previous agent not restored"
[[ "$(readlink -f "$HAIL_BIN_DIR/haild")" == "$(release_dir one)/haild" ]] || fail "PATH moved to a failed release"

# A bootstrap that keeps failing fails the restart without moving PATH.
mode bootstrap-fails
expect_failure "bootstrap that fails" "$host" restart
[[ "$(readlink -f "$HAIL_BIN_DIR/haild")" == "$(release_dir one)/haild" ]] || fail "PATH moved after a failed bootstrap"

# A daemon whose pid keeps changing (crash loop) is not ready.
mode flapping
expect_failure "crash-looping daemon" "$host" restart

# Interrupted installs: an incomplete release directory is refused with a clear message.
mkdir -p "$(release_dir three)"
expect_failure "incomplete release directory" "$host" install --binary "$scratch/haild-three"

# Not running, or the legacy job loaded, is a problem.
mode ok
rm -f "$jobs/com.hailingstation.haild"
set +e; "$host" status >/dev/null; code=$?; set -e
[[ "$code" == 3 ]] || fail "expected status 3 when the daemon is not running, got $code"
echo "test-host: OK"
