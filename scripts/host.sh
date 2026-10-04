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

# Prints a config value, or nothing when the key is absent. plutil prints its error to stdout, so the value is
# used only when extraction succeeds.
config_value() {
  local value
  if value="$(plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null)"; then printf '%s' "$value"; fi
}

# A config string that is safe to pass as one daemon argument: no control characters, no leading dash.
checked_value() {
  local key="$1" value
  value="$(config_value "$key")"
  if [[ "$value" == *[[:cntrl:]]* || "$value" == -* ]]; then
    fail "host.json \"$key\" must not contain control characters or start with '-'"
  fi
  printf '%s' "$value"
}

# A JSON boolean, absent meaning false. Anything else (1, "yes") is refused rather than silently read as false.
flag_value() {
  local key="$1" value
  value="$(config_value "$key")"
  [[ -z "$value" || "$value" == true || "$value" == false ]] || fail "host.json \"$key\" must be true or false"
  [[ "$value" == true ]]
}

require_config() {
  [[ -f "$CONFIG" ]] || fail "missing $CONFIG; see scripts/host.sh --help"
  plutil -convert xml1 -o /dev/null "$CONFIG" >/dev/null 2>&1 || fail "$CONFIG is not valid JSON"
}

# The arguments after the executable, from host.json, in DAEMON_ARGS. Built as an array, never as joined text,
# so no config value can become an extra argument.
DAEMON_ARGS=()
load_daemon_arguments() {
  require_config
  local bind port rightyo rightyo_config target fallback=false
  bind="$(checked_value bind)"
  port="$(config_value port)"
  # An IPv4 or IPv6 literal; a host name would make the listener's exposure depend on name resolution.
  [[ "$bind" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$bind" =~ ^[0-9A-Fa-f:]+$ ]] \
    || fail "host.json needs \"bind\" as an IP address literal"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "host.json needs a numeric \"port\" between 1 and 65535"
  fi
  DAEMON_ARGS=(run --bind "$bind" --port "$port" --personal-terminal)
  if flag_value singleTerminalReplyFallback; then
    fallback=true
    DAEMON_ARGS+=(--single-terminal-reply-fallback)
  fi
  if flag_value deviceDiagnostics; then DAEMON_ARGS+=(--device-diagnostics); fi
  rightyo="$(checked_value ambient.rightyo)"
  rightyo_config="$(checked_value ambient.config)"
  target="$(checked_value ambient.target)"
  if [[ -n "$rightyo$rightyo_config$target" ]]; then
    [[ "$rightyo" == /* && "$rightyo_config" == /* && -n "$target" ]] \
      || fail "ambient needs absolute \"rightyo\" and \"config\" paths and a \"target\""
    [[ "$fallback" == true ]] || fail "ambient listening requires \"singleTerminalReplyFallback\": true"
    DAEMON_ARGS+=(--ambient-rightyo "$rightyo" --ambient-rightyo-config "$rightyo_config" --ambient-target "$target")
  fi
}

# The optional host ID, held to the same form HostIdentity accepts, so a bad value fails here, not in a
# crash-looping daemon.
host_id() {
  local value
  value="$(checked_value hostID)"
  if [[ -n "$value" ]] && ! [[ "$value" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.?$ && ${#value} -le 253 ]]; then
    fail "host.json \"hostID\" must be a host name: letters, digits, dots and hyphens"
  fi
  printf '%s' "$value"
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
  local out="$1" program argument host
  program="$(staged_release)"
  load_daemon_arguments
  host="$(host_id)"
  rm -f "$out"
  plutil -create xml1 "$out"
  plutil -insert Label -string "$LABEL" "$out"
  plutil -insert ProgramArguments -array "$out"
  plutil -insert ProgramArguments -string "$program" -append "$out"
  for argument in "${DAEMON_ARGS[@]}"; do
    plutil -insert ProgramArguments -string "$argument" -append "$out"
  done
  plutil -insert RunAtLoad -bool true "$out"
  # Restart after a crash, not after a clean stop.
  plutil -insert KeepAlive -dictionary "$out"
  plutil -insert KeepAlive.SuccessfulExit -bool false "$out"
  plutil -insert ProcessType -string Interactive "$out"
  plutil -insert StandardOutPath -string "$LOGS/haild.out.log" "$out"
  plutil -insert StandardErrorPath -string "$LOGS/haild.err.log" "$out"
  if [[ -n "$host" ]]; then
    plutil -insert EnvironmentVariables -dictionary "$out"
    plutil -insert EnvironmentVariables.HAIL_HOST_ID -string "$host" "$out"
  fi
}

print_plist() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/hail-plist.XXXXXX")"
  write_plist "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

# A field (`pid`, `program`, `state`) of a loaded job, or nothing when it is not loaded.
job_field() {
  { "$LAUNCHCTL" print "$DOMAIN/$1" 2>/dev/null || true; } | awk -v key="$2" '$1 == key && $2 == "=" { print $3; exit }'
}

stop_job() {
  "$LAUNCHCTL" bootout "$DOMAIN/$1" >/dev/null 2>&1 || true
  local waited=0
  # The daemon shuts down gracefully, so bootout can return while the job is still unloading.
  while "$LAUNCHCTL" print "$DOMAIN/$1" >/dev/null 2>&1; do
    (( waited++ < READY_SECONDS )) || fail "$1 did not unload within ${READY_SECONDS}s"
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

restart() {
  local program
  program="$(staged_release)"
  # Peer endpoints and session IDs are not for other local accounts.
  mkdir -p "$AGENTS" "$LOGS" "$BIN"
  chmod 0700 "$LOGS"
  # Everything that can be checked is checked before the running daemon is touched.
  write_plist "$PLIST.next"
  plutil -lint -s "$PLIST.next" >/dev/null
  [[ -f "$PLIST" ]] && cp -p "$PLIST" "$PLIST.prev"
  stop_job "$LEGACY_LABEL"
  stop_job "$LABEL"
  # Keep the previous run's log for diagnosis; readiness is judged on a fresh one.
  if [[ -f "$LOGS/haild.err.log" ]]; then mv -f "$LOGS/haild.err.log" "$LOGS/haild.err.log.1"; fi
  rm -f "$SOCKET"
  mv -f "$PLIST.next" "$PLIST"
  if start_job && wait_ready; then
    relink "$(dirname "$program")" "$ROOT/running"
    relink "$ROOT/running/haild" "$BIN/haild"
    echo "haild ready: $program"
    return 0
  fi
  echo "error: the new haild did not become ready; see $LOGS/haild.err.log" >&2
  stop_job "$LABEL"
  if [[ -f "$PLIST.prev" ]]; then
    mv -f "$PLIST.prev" "$PLIST"
    if start_job; then echo "restored the previous LaunchAgent" >&2; else echo "error: restore failed" >&2; fi
  fi
  exit 1
}

status() {
  local staged running path_link program state code=0
  staged="$(staged_release)"
  running="$(release_of running || true)"
  path_link="$(readlink "$BIN/haild" 2>/dev/null || true)"
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
  elif [[ "$program" != "$running" ]]; then
    echo "problem: the daemon runs a different release from the PATH haild; run scripts/host.sh restart"
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
