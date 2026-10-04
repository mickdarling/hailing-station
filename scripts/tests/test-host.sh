#!/usr/bin/env bash
# scripts/host.sh against a scratch tree: fake binaries and a stateful fake launchctl; no real LaunchAgent is
# touched (#246).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# Canonical (no /var -> /private/var symlink), so resolved links compare equal to scratch paths.
scratch="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hailing-station-host-test.XXXXXX")" && pwd -P)"
# Releases are read-only by design, so make the scratch tree writable before removing it.
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf -- "$scratch"' EXIT

# Spaces in the paths, like the real "Application Support", so path handling stays covered.
export HAIL_HOST_ROOT="$scratch/App Support/root" HAIL_CONFIG_DIR="$scratch/config" HAIL_LAUNCH_AGENTS="$scratch/agents"
export HAIL_LOG_DIR="$scratch/logs" HAIL_BIN_DIR="$scratch/my bin" HAIL_READY_SECONDS=2 HAIL_SETTLE_SECONDS=0
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
  bootout)
    # stuck-legacy: the legacy job ignores bootout, like a daemon that will not shut down.
    [[ "\$mode" == stuck-legacy && "\$2" == *hailing-station-session ]] || rm -f "$jobs/\${2##*/}" ;;
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
if plutil -extract EnvironmentVariables.HAIL_HOST_ID raw -o - "$scratch/minimal.plist" >/dev/null 2>&1; then
  fail "minimal config produced a host ID"
fi
[[ "$(plutil -extract EnvironmentVariables.HAIL_CONFIG_DIR raw -o - "$scratch/minimal.plist")" == "$HAIL_CONFIG_DIR" ]] \
  || fail "the daemon would not use the config directory this script checks"

# Config validation, all before anything runs.
bad_config() { printf '%s\n' "$2" > "$HAIL_CONFIG_DIR/host.json"; expect_failure "$1" "$host" plist; }
bad_config "missing port" '{"bind": "127.0.0.1"}'
bad_config "out-of-range port" '{"bind": "127.0.0.1", "port": 70000}'
bad_config "missing bind" '{"port": 8765}'
bad_config "bind that is not an IP literal" '{"bind": "localhost", "port": 8765}'
bad_config "newline smuggling an extra argument" '{"bind": "127.0.0.1\n--bind\n0.0.0.0", "port": 8765}'
bad_config "invalid host ID" '{"bind": "127.0.0.1", "port": 8765, "hostID": "bad host"}'
bad_config "host ID with a newline" '{"bind": "127.0.0.1", "port": 8765, "hostID": "a\nb"}'
bad_config "host ID that is a flag" '{"bind": "127.0.0.1", "port": 8765, "hostID": "-x"}'
bad_config "quoted boolean" '{"bind": "127.0.0.1", "port": 8765, "deviceDiagnostics": "true"}'
bad_config "bind that is an object" '{"bind": {"a": 1}, "port": 8765}'
bad_config "IPv4 octet over 255" '{"bind": "999.1.1.1", "port": 8765}'
bad_config "unspecified IPv4" '{"bind": "0.0.0.0", "port": 8765}'
bad_config "unspecified IPv6" '{"bind": "::", "port": 8765}'
bad_config "malformed IPv6" '{"bind": "1::2::3", "port": 8765}'
bad_config "IPv4-mapped IPv6" '{"bind": "::ffff:127.0.0.1", "port": 8765}'
bad_config "scoped IPv6" '{"bind": "fe80::1%en0", "port": 8765}'
bad_config "hex word that is not IPv6" '{"bind": "beef", "port": 8765}'
bad_config "port as a string" '{"bind": "127.0.0.1", "port": "8765"}'
printf '%s\n' '{"bind": "::1", "port": 8765}' > "$HAIL_CONFIG_DIR/host.json"
"$host" plist >/dev/null || fail "IPv6 loopback was refused"
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

# A failed first migration has nothing to restore; the failed agent is set aside so it cannot load at login.
mode never-ready
expect_failure "first restart that never becomes ready" "$host" restart
[[ -f "$HAIL_LAUNCH_AGENTS/com.hailingstation.haild.plist.failed" ]] || fail "failed first agent not set aside"
[[ ! -e "$HAIL_LAUNCH_AGENTS/com.hailingstation.haild.plist" ]] || fail "failed first agent left in LaunchAgents"
[[ ! -e "$HAIL_BIN_DIR/haild" ]] || fail "PATH haild set by a failed restart"
mode ok

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

# An interrupted restart (TERM while waiting for readiness) rolls back to the previous agent.
mode never-ready
HAIL_READY_SECONDS=30 "$host" restart >/dev/null 2>&1 &
restarting=$!
for (( waited = 0; waited < 50; waited++ )); do
  grep -q '^bootstrap' "$scratch/launchctl.calls" 2>/dev/null && break
  sleep 0.1
done
: > "$scratch/launchctl.calls"
sleep 0.5
# The new daemon is already started and never ready; the restored one comes up normally.
mode ok
kill -TERM "$restarting"
set +e; wait "$restarting"; interrupted=$?; set -e
[[ "$interrupted" != 0 ]] || fail "an interrupted restart reported success"
[[ "$(cat "$jobs/com.hailingstation.haild")" == "$(release_dir one)/haild" ]] || fail "interruption did not restore"
[[ "$(readlink -f "$HAIL_BIN_DIR/haild")" == "$(release_dir one)/haild" ]] || fail "interruption moved the PATH haild"
grep -q '^bootstrap' "$scratch/launchctl.calls" || fail "interruption did not start the restored agent"
mode never-ready

# A closed terminal (HUP) mid-restart also rolls back.
HAIL_READY_SECONDS=30 "$host" restart >/dev/null 2>&1 &
restarting=$!
: > "$scratch/launchctl.calls"
for (( waited = 0; waited < 50; waited++ )); do
  grep -q '^bootstrap' "$scratch/launchctl.calls" 2>/dev/null && break
  sleep 0.1
done
sleep 0.5
mode ok
kill -HUP "$restarting"
set +e; wait "$restarting"; hung_up=$?; set -e
[[ "$hung_up" != 0 ]] || fail "a hung-up restart reported success"
[[ "$(cat "$jobs/com.hailingstation.haild")" == "$(release_dir one)/haild" ]] || fail "HUP did not restore"
[[ "$(readlink -f "$HAIL_BIN_DIR/haild")" == "$(release_dir one)/haild" ]] || fail "HUP moved the PATH haild"
mode never-ready

# A legacy job that will not unload: nothing new is started, the managed daemon and its socket are left alone.
mode stuck-legacy
echo "legacy" > "$jobs/com.mickdarling.hailing-station-session"
touch "$HAIL_CONFIG_DIR/replies.sock"
managed_before="$(cat "$jobs/com.hailingstation.haild")"
"$host" restart > "$scratch/stuck.out" 2>&1 && fail "restart succeeded with a legacy job that would not unload"
[[ -e "$HAIL_CONFIG_DIR/replies.sock" ]] || fail "rollback removed the socket of a daemon that was never stopped"
[[ "$(cat "$jobs/com.hailingstation.haild")" == "$managed_before" ]] || fail "rollback touched the managed daemon"
grep -q "nothing new was started" "$scratch/stuck.out" || fail "rollback did not say nothing was started"
! grep -q "kept as" "$scratch/stuck.out" || fail "rollback claimed a failed agent it never started"
rm -f "$jobs/com.mickdarling.hailing-station-session"
mode never-ready

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

# A PATH haild that is missing or points elsewhere is a problem, even with a healthy daemon.
mode ok
"$host" restart >/dev/null
"$host" status >/dev/null || fail "healthy status before the PATH check"
mv "$HAIL_BIN_DIR/haild" "$HAIL_BIN_DIR/haild.moved"
set +e; "$host" status >/dev/null; code=$?; set -e
[[ "$code" == 3 ]] || fail "expected status 3 with no PATH haild, got $code"
ln -s "$scratch/haild-two" "$HAIL_BIN_DIR/haild"
set +e; "$host" status >/dev/null; code=$?; set -e
[[ "$code" == 3 ]] || fail "expected status 3 with a PATH haild for another binary, got $code"
rm -f "$HAIL_BIN_DIR/haild"; mv "$HAIL_BIN_DIR/haild.moved" "$HAIL_BIN_DIR/haild"

# Not running, or the legacy job loaded, is a problem.
mode ok
rm -f "$jobs/com.hailingstation.haild"
set +e; "$host" status >/dev/null; code=$?; set -e
[[ "$code" == 3 ]] || fail "expected status 3 when the daemon is not running, got $code"
echo "test-host: OK"
