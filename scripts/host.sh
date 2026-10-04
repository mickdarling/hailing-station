#!/usr/bin/env bash
# Install and supervise the Mac host daemon as one immutable release (#246).
# `install` only stages a release. `restart` switches the LaunchAgent and, once the new daemon is ready, the
# `haild` on PATH to that same release, so the daemon and `haild reply` never run different builds (#115).
# Settings come from one config file instead of ad-hoc flags.
set -euo pipefail

LABEL="com.hailingstation.haild"
# Ad-hoc job started by earlier sessions with `launchctl submit`; `restart` replaces it with the managed agent.
LEGACY_LABEL="com.mickdarling.hailing-station-session"
CONFIG_DIR="${HAIL_CONFIG_DIR:-$HOME/.config/hail}"
ROOT="${HAIL_HOST_ROOT:-$HOME/Library/Application Support/HailingStation}"
CONFIG="$CONFIG_DIR/host.json"
SOCKET="$CONFIG_DIR/replies.sock"
AGENTS="${HAIL_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
LOGS="${HAIL_LOG_DIR:-$HOME/Library/Logs/HailingStation}"
BIN="${HAIL_BIN_DIR:-$HOME/.local/bin}"
LAUNCHCTL="${HAIL_LAUNCHCTL:-launchctl}"
READY_SECONDS="${HAIL_READY_SECONDS:-20}"
SETTLE_SECONDS="${HAIL_SETTLE_SECONDS:-2}"
PLIST="$AGENTS/$LABEL.plist"
DOMAIN="gui/$(id -u)"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'USAGE'
usage: scripts/host.sh <install|plist|restart|deploy|status> [options]

  install [--binary PATH]  Build haild (release) or take PATH and stage it as an immutable release.
                           Nothing running changes until `restart`.
  plist                    Print the LaunchAgent plist generated from host.json for the staged release.
  restart                  Start the staged release under launchd, replacing any running haild job
                           (including the legacy ad-hoc job). Once it is ready, point ~/.local/bin/haild
                           at the same release. If it does not become ready, the previous agent is restored.
  deploy [--binary PATH]   install, then restart.
  status                   The staged release, the running daemon, the PATH haild, and any drift.

host.json: {"bind": "127.0.0.1", "port": 8765, "hostID": "optional", "singleTerminalReplyFallback": true,
            "deviceDiagnostics": false,
            "ambient": {"rightyo": "/abs/path", "config": "/abs/path", "target": "tmux:name"}}
Ambient listening requires "singleTerminalReplyFallback": true.
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }

# Config readers run in the calling shell and set VALUE. They are never called inside $(...): macOS bash 3.2 does
# not apply `set -e` inside command substitution, so a refusal there would be silently ignored.
VALUE=""
read_value() {
  local key="$1" type="$2" actual
  VALUE=""
  # plutil prints a missing-key error on stdout, so nothing is read unless the key exists.
  actual="$(plutil -type "$key" "$CONFIG" 2>/dev/null)" || return 0
  [[ "$actual" == "$type" ]] || fail "host.json \"$key\" must be a $type, not a $actual"
  VALUE="$(plutil -extract "$key" raw -o - "$CONFIG")"
}

# A string that is safe to pass as one daemon argument: no control characters, no leading dash.
read_string() {
  read_value "$1" string
  if [[ "$VALUE" == *[[:cntrl:]]* || "$VALUE" == -* ]]; then
    fail "host.json \"$1\" must not contain control characters or start with '-'"
  fi
}

# True only for a JSON true; absent means false.
read_flag() {
  read_value "$1" bool
  [[ "$VALUE" == true ]]
}

require_config() {
  [[ -f "$CONFIG" ]] || fail "missing $CONFIG; see scripts/host.sh --help"
  plutil -convert xml1 -o /dev/null "$CONFIG" >/dev/null 2>&1 || fail "$CONFIG is not valid JSON"
}

# The addresses the daemon's parseBindAddress accepts (WebSocketPeer.swift): a valid IPv4 or IPv6 literal that is
# not unspecified (0.0.0.0, ::) and not IPv4-mapped. Without a scope suffix (refused here; Network.framework drops
# an unknown one), every literal Python's ipaddress accepts, Network.framework accepts too, so this never passes
# something the daemon would reject after the old one is stopped. Isolated mode ignores PYTHON* settings.
is_ip_literal() {
  [[ "$1" != *%* ]] || return 1
  command -v python3 >/dev/null || fail "python3 is required to check \"bind\""
  python3 -I - "$1" <<'PY'
import ipaddress, sys
try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
mapped = isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None
sys.exit(1 if address.is_unspecified or mapped else 0)
PY
}

# The arguments after the executable, from host.json, in DAEMON_ARGS. Built as an array, never as joined text,
# so no config value can become an extra argument.
DAEMON_ARGS=()
load_daemon_arguments() {
  require_config
  local bind port rightyo rightyo_config target fallback=false
  read_string bind; bind="$VALUE"
  read_value port integer; port="$VALUE"
  # An IPv4 or IPv6 literal; a host name would make the listener's exposure depend on name resolution.
  is_ip_literal "$bind" || fail "host.json needs \"bind\" as an IP address literal"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "host.json needs a numeric \"port\" between 1 and 65535"
  fi
  DAEMON_ARGS=(run --bind "$bind" --port "$port" --personal-terminal)
  if read_flag singleTerminalReplyFallback; then
    fallback=true
    DAEMON_ARGS+=(--single-terminal-reply-fallback)
  fi
  if read_flag deviceDiagnostics; then DAEMON_ARGS+=(--device-diagnostics); fi
  read_string ambient.rightyo; rightyo="$VALUE"
  read_string ambient.config; rightyo_config="$VALUE"
  read_string ambient.target; target="$VALUE"
  if [[ -n "$rightyo$rightyo_config$target" ]]; then
    [[ "$rightyo" == /* && "$rightyo_config" == /* && -n "$target" ]] \
      || fail "ambient needs absolute \"rightyo\" and \"config\" paths and a \"target\""
    [[ "$fallback" == true ]] || fail "ambient listening requires \"singleTerminalReplyFallback\": true"
    DAEMON_ARGS+=(--ambient-rightyo "$rightyo" --ambient-rightyo-config "$rightyo_config" --ambient-target "$target")
  fi
}

# The optional host ID in HOST_ID, held to the form HostIdentity accepts, so a bad value fails here, not in a
# crash-looping daemon.
HOST_ID=""
load_host_id() {
  read_string hostID
  if [[ -n "$VALUE" ]] && ! [[ "$VALUE" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.?$ && ${#VALUE} -le 253 ]]; then
    fail "host.json \"hostID\" must be a host name: letters, digits, dots and hyphens"
  fi
  HOST_ID="$VALUE"
}

# The haild of the release a link points at.
release_of() {
  [[ -L "$ROOT/$1" ]] || return 1
  local target
  target="$(readlink "$ROOT/$1")"
  [[ -x "$target/haild" ]] && echo "$target/haild"
}

staged_release() { release_of current || fail "nothing installed; run scripts/host.sh install"; }

# Replace a symlink atomically: a reader sees the old target or the new one, never neither.
relink() { ln -sfn "$1" "$2.tmp" && mv -fh "$2.tmp" "$2"; }

install_release() {
  local binary=""
  while (( $# )); do
    case "$1" in
      --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  if [[ -z "$binary" ]]; then
    (cd "$REPO" && swift build -c release --product haild)
    binary="$REPO/.build/release/haild"
  fi
  [[ -x "$binary" ]] || fail "$binary is not an executable"
  local digest release staging
  digest="$(shasum -a 256 "$binary" | cut -c1-16)"
  release="$ROOT/releases/$digest"
  mkdir -p "$ROOT/releases"
  if [[ -e "$release" && ! -x "$release/haild" ]]; then
    fail "$release exists but is incomplete; remove it and install again"
  fi
  if [[ ! -e "$release" ]]; then
    staging="$(mktemp -d "$ROOT/releases/.staging.XXXXXX")"
    cp "$binary" "$staging/haild"
    chmod 0555 "$staging/haild"
    mv "$staging" "$release"
    # After the move: renaming a directory needs write permission on it.
    chmod 0555 "$release"
  fi
  relink "$release" "$ROOT/current"
  echo "staged release $digest; run scripts/host.sh restart to start it"
}

write_plist() {
  local out="$1" program="$2" argument
  load_daemon_arguments
  load_host_id
  rm -f "$out"
  plutil -create xml1 "$out"
  plutil -insert Label -string "$LABEL" "$out"
  plutil -insert ProgramArguments -array "$out"
  plutil -insert ProgramArguments -string "$program" -append "$out"
  for argument in "${DAEMON_ARGS[@]}"; do
    plutil -insert ProgramArguments -string "$argument" -append "$out"
  done
  plutil -insert RunAtLoad -bool true "$out"
  # Always restart: haild exits 0 when its listener fails, and a deliberate stop is a bootout, which unloads it.
  plutil -insert KeepAlive -bool true "$out"
  plutil -insert ProcessType -string Interactive "$out"
  plutil -insert StandardOutPath -string "$LOGS/haild.out.log" "$out"
  plutil -insert StandardErrorPath -string "$LOGS/haild.err.log" "$out"
  if [[ -n "$HOST_ID" || -n "${HAIL_CONFIG_DIR:-}" ]]; then plutil -insert EnvironmentVariables -dictionary "$out"; fi
  if [[ -n "$HOST_ID" ]]; then plutil -insert EnvironmentVariables.HAIL_HOST_ID -string "$HOST_ID" "$out"; fi
  # The daemon's config directory (policy, audit, reply socket) is the one this script reads and checks.
  if [[ -n "${HAIL_CONFIG_DIR:-}" ]]; then
    plutil -insert EnvironmentVariables.HAIL_CONFIG_DIR -string "$HAIL_CONFIG_DIR" "$out"
  fi
}

print_plist() {
  local tmp program
  program="$(staged_release)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/hail-plist.XXXXXX")"
  write_plist "$tmp" "$program"
  cat "$tmp"
  rm -f "$tmp"
}

# A field (`pid`, `program`, `state`) of a loaded job, or nothing when it is not loaded.
job_field() {
  # Everything after "key = ", so a path with spaces (Application Support) stays whole.
  { "$LAUNCHCTL" print "$DOMAIN/$1" 2>/dev/null || true; } \
    | awk -v key="$2" '$1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }'
}

# Unload a job and wait until launchd has let it go. Returns 1 on timeout so the caller can decide what to do.
stop_job() {
  "$LAUNCHCTL" bootout "$DOMAIN/$1" >/dev/null 2>&1 || true
  local waited=0
  # The daemon shuts down gracefully, so bootout can return while the job is still unloading.
  while "$LAUNCHCTL" print "$DOMAIN/$1" >/dev/null 2>&1; do
    (( waited++ < READY_SECONDS )) || return 1
    sleep 1
  done
}

start_job() {
  local attempt
  for attempt in 1 2 3; do
    "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 && return 0
    sleep "$attempt"
  done
  return 1
}

# Ready means: the listener reported ready, the reply socket exists, and the process is not restarting.
wait_ready() {
  local waited=0 pid
  until grep -q '"event":"listener_ready"' "$LOGS/haild.err.log" 2>/dev/null && [[ -e "$SOCKET" ]]; do
    (( waited++ < READY_SECONDS )) || return 1
    sleep 1
  done
  pid="$(job_field "$LABEL" pid)"
  sleep "$SETTLE_SECONDS"
  [[ -n "$pid" && "$(job_field "$LABEL" pid)" == "$pid" ]]
}

# Undo a restart that did not complete: unload the new agent, restore and start the previous one, and say honestly
# whether it is ready. Used on failure and on interruption, so the host is not left without a daemon.
IN_FLIGHT=false
# How far restart got, so roll_back undoes only what was done: "stopping" (old jobs being unloaded),
# "managed-stopped" (the previous managed agent is down), "started" (the new agent was handed to launchd).
STAGE=""
roll_back() {
  # Runs to completion: a second signal must not leave the restore half done.
  IN_FLIGHT=false
  trap '' INT TERM HUP
  trap - EXIT
  echo "error: $1; see $LOGS/haild.err.log" >&2
  rm -f "$PLIST.next"
  if [[ "$STAGE" == stopping ]]; then
    # Nothing new started and the managed agent untouched; a daemon still serving keeps its socket and log.
    echo "nothing new was started; any daemon still running was left as it was" >&2
    exit 1
  fi
  if [[ "$STAGE" == started ]]; then
    stop_job "$LABEL" || echo "error: the new haild did not unload" >&2
    # A crashed daemon can leave its socket behind, which would stop the restored one from starting; its log could
    # also still hold a readiness line, so it is set aside before the restore is judged.
    rm -f "$SOCKET"
    if [[ -f "$LOGS/haild.err.log" ]]; then mv -f "$LOGS/haild.err.log" "$LOGS/haild.err.log.failed"; fi
  fi
  if [[ -f "$PLIST.prev" ]]; then
    mv -f "$PLIST.prev" "$PLIST"
    if start_job && wait_ready; then
      echo "restored the previous LaunchAgent; it is ready" >&2
    else
      echo "error: the previous LaunchAgent was restored but is not ready; see $LOGS/haild.err.log" >&2
    fi
  elif [[ "$STAGE" == started && -f "$PLIST" ]]; then
    # Nothing to restore (first migration): keep the failed agent from loading at the next login.
    mv -f "$PLIST" "$PLIST.failed"
    echo "error: no previous LaunchAgent to restore; the failed one is kept as $PLIST.failed" >&2
  else
    echo "error: the legacy daemon was stopped and nothing new was started; run scripts/host.sh restart again" >&2
  fi
  exit 1
}

restart() {
  local program
  program="$(staged_release)"
  # Peer endpoints and session IDs are not for other local accounts.
  mkdir -p "$AGENTS" "$LOGS" "$BIN"
  chmod 0700 "$LOGS"
  # Everything that can be checked is checked before the running daemon is touched.
  write_plist "$PLIST.next" "$program"
  plutil -lint -s "$PLIST.next" >/dev/null
  # Only this run's previous agent may be restored, never a leftover from an earlier one.
  rm -f "$PLIST.prev"
  if [[ -f "$PLIST" ]]; then cp -p "$PLIST" "$PLIST.prev"; fi
  # From here until the switch is committed, an interruption (including a closed terminal) or any unexpected exit
  # rolls back instead of leaving the host half-changed.
  IN_FLIGHT=true
  STAGE=stopping
  trap 'roll_back "restart was interrupted"' INT TERM HUP
  trap 'if [[ "$IN_FLIGHT" == true ]]; then roll_back "restart stopped unexpectedly"; fi' EXIT
  stop_job "$LEGACY_LABEL" || roll_back "the legacy haild job did not unload within ${READY_SECONDS}s"
  STAGE=managed-stopped
  stop_job "$LABEL" || roll_back "the managed haild job did not unload within ${READY_SECONDS}s"
  # Keep the previous run's log for diagnosis; readiness is judged on a fresh one.
  if [[ -f "$LOGS/haild.err.log" ]]; then mv -f "$LOGS/haild.err.log" "$LOGS/haild.err.log.1"; fi
  rm -f "$SOCKET"
  STAGE=started
  mv -f "$PLIST.next" "$PLIST"
  if ! start_job || ! wait_ready; then roll_back "the new haild did not become ready"; fi
  # Commit point: the new daemon is ready, so finish the switch without interruption. Rolling back now would leave
  # the links on a release launchd no longer runs.
  IN_FLIGHT=false
  trap '' INT TERM HUP
  trap - EXIT
  relink "$(dirname "$program")" "$ROOT/running"
  relink "$ROOT/running/haild" "$BIN/haild"
  trap - INT TERM HUP
  rm -f "$PLIST.prev"
  echo "haild ready: $program"
}

status() {
  local staged running path_haild path_link program state code=0
  staged="$(staged_release)"
  running="$(release_of running || true)"
  path_link="$(readlink "$BIN/haild" 2>/dev/null || true)"
  # What target sessions actually run, through every link.
  path_haild="$(readlink -f "$BIN/haild" 2>/dev/null || true)"
  program="$(job_field "$LABEL" program)"
  state="$(job_field "$LABEL" state)"
  echo "staged:  $staged"
  echo "running: ${program:-not loaded} (${state:-no state})"
  echo "PATH haild: $BIN/haild -> ${path_link:-missing}"
  if [[ -n "$(job_field "$LEGACY_LABEL" state)" ]]; then
    echo "warning: legacy job $LEGACY_LABEL is still loaded; run scripts/host.sh restart"
    code=3
  fi
  if [[ "$state" != running ]]; then
    echo "problem: the managed daemon is not running"
    code=3
  elif [[ -z "$path_haild" || "$path_haild" != "$(readlink -f "$program")" ]]; then
    echo "problem: the PATH haild is missing or runs a different release from the daemon; run scripts/host.sh restart"
    code=3
  elif [[ "$program" != "$running" ]]; then
    echo "problem: the daemon runs a different release from the one recorded as running; run scripts/host.sh restart"
    code=3
  elif [[ "$program" != "$staged" ]]; then
    echo "note: a different release is staged and not started yet; run scripts/host.sh restart"
  fi
  return "$code"
}

case "${1:-}" in
  install) shift; install_release "$@" ;;
  plist) print_plist ;;
  restart) restart ;;
  deploy) shift; install_release "$@"; restart ;;
  status) status ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
