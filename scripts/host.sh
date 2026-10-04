#!/usr/bin/env bash
# Install and supervise the Mac host daemon as one immutable release (#246).
# The LaunchAgent and the `haild` on PATH run the same installed binary, so the daemon and `haild reply`
# cannot drift apart after a rebuild (#115). Settings come from one config file instead of ad-hoc flags.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.hailingstation.haild"
# Ad-hoc job started by earlier sessions with `launchctl submit`; `restart` replaces it with the managed agent.
LEGACY_LABEL="com.mickdarling.hailing-station-session"
ROOT="${HAIL_HOST_ROOT:-$HOME/Library/Application Support/HailingStation}"
CONFIG="${HAIL_CONFIG_DIR:-$HOME/.config/hail}/host.json"
AGENTS="${HAIL_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
LOGS="${HAIL_LOG_DIR:-$HOME/Library/Logs/HailingStation}"
BIN="${HAIL_BIN_DIR:-$HOME/.local/bin}"
LAUNCHCTL="${HAIL_LAUNCHCTL:-launchctl}"
READY_SECONDS="${HAIL_READY_SECONDS:-20}"
PLIST="$AGENTS/$LABEL.plist"
DOMAIN="gui/$(id -u)"

usage() {
  cat <<'USAGE'
usage: scripts/host.sh <install|plist|restart|status> [options]

  install [--binary PATH]  Build haild (release) or take PATH, install it as an immutable release,
                           and point `current` and ~/.local/bin/haild at it.
  plist                    Print the LaunchAgent plist generated from ~/.config/hail/host.json.
  restart                  Write the plist, replace any running haild job (including the legacy ad-hoc
                           job), and wait until the listener reports ready.
  status                   Show the installed release, the running daemon, and any drift between them.

host.json: {"bind": "127.0.0.1", "port": 8765, "hostID": "optional", "singleTerminalReplyFallback": true,
            "deviceDiagnostics": false,
            "ambient": {"rightyo": "/abs/path", "config": "/abs/path", "target": "tmux:name"}}
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

require_config() {
  [[ -f "$CONFIG" ]] || fail "missing $CONFIG; see scripts/host.sh --help"
  plutil -convert xml1 -o /dev/null "$CONFIG" >/dev/null 2>&1 || fail "$CONFIG is not valid JSON"
}

# The arguments after the executable, from host.json, in DAEMON_ARGS. Built as an array, never as joined text,
# so no config value can become an extra argument.
DAEMON_ARGS=()
load_daemon_arguments() {
  require_config
  local bind port rightyo rightyo_config target
  bind="$(checked_value bind)"
  port="$(config_value port)"
  # An IPv4 or IPv6 literal; a host name would make the listener's exposure depend on name resolution.
  [[ "$bind" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$bind" =~ ^[0-9A-Fa-f:]+$ ]] \
    || fail "host.json needs \"bind\" as an IP address literal"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "host.json needs a numeric \"port\" between 1 and 65535"
  fi
  DAEMON_ARGS=(run --bind "$bind" --port "$port" --personal-terminal)
  if [[ "$(config_value singleTerminalReplyFallback)" == "true" ]]; then
    DAEMON_ARGS+=(--single-terminal-reply-fallback)
  fi
  if [[ "$(config_value deviceDiagnostics)" == "true" ]]; then DAEMON_ARGS+=(--device-diagnostics); fi
  rightyo="$(checked_value ambient.rightyo)"
  rightyo_config="$(checked_value ambient.config)"
  target="$(checked_value ambient.target)"
  if [[ -n "$rightyo$rightyo_config$target" ]]; then
    [[ "$rightyo" == /* && "$rightyo_config" == /* && -n "$target" ]] \
      || fail "ambient needs absolute \"rightyo\" and \"config\" paths and a \"target\""
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

current_release() {
  [[ -L "$ROOT/current" ]] || fail "nothing installed; run scripts/host.sh install"
  local target
  target="$(readlink "$ROOT/current")"
  [[ -x "$target/haild" ]] || fail "$ROOT/current does not point at an installed haild"
  echo "$target/haild"
}

install_release() {
  local binary=""
  while (( $# )); do
    case "$1" in
      --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  if [[ -z "$binary" ]]; then
    swift build -c release --product haild
    binary=".build/release/haild"
  fi
  [[ -x "$binary" ]] || fail "$binary is not an executable"
  local digest release
  digest="$(shasum -a 256 "$binary" | cut -c1-16)"
  release="$ROOT/releases/$digest"
  mkdir -p "$ROOT/releases" "$BIN"
  if [[ ! -x "$release/haild" ]]; then
    # Clear what an interrupted install may have left, including a read-only partial copy.
    chmod -R u+w "$release.tmp" "$release" 2>/dev/null || true
    rm -rf "$release.tmp" "$release"
    mkdir -p "$release.tmp"
    cp "$binary" "$release.tmp/haild"
    chmod 0555 "$release.tmp/haild"
    mv "$release.tmp" "$release"
  fi
  # Replace each link atomically: a reader sees the old release or the new one, never neither.
  ln -sfn "$release" "$ROOT/current.tmp" && mv -fh "$ROOT/current.tmp" "$ROOT/current"
  ln -sfn "$ROOT/current/haild" "$BIN/haild.tmp" && mv -fh "$BIN/haild.tmp" "$BIN/haild"
  echo "installed release $digest"
  echo "haild on PATH: $BIN/haild -> $ROOT/current/haild"
}

write_plist() {
  local out="$1" program argument host
  program="$(current_release)"
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
  plutil -insert KeepAlive -bool true "$out"
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

restart() {
  # Peer endpoints and session IDs are not for other local accounts.
  mkdir -p "$AGENTS" "$LOGS"
  chmod 0700 "$LOGS"
  write_plist "$PLIST.tmp"
  plutil -lint -s "$PLIST.tmp" >/dev/null
  mv -f "$PLIST.tmp" "$PLIST"
  "$LAUNCHCTL" bootout "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1 || true
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  # Keep the previous run's log for diagnosis; readiness is judged on a fresh one.
  [[ -f "$LOGS/haild.err.log" ]] && mv -f "$LOGS/haild.err.log" "$LOGS/haild.err.log.1"
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"
  local waited=0
  until grep -q '"event":"listener_ready"' "$LOGS/haild.err.log" 2>/dev/null; do
    (( waited++ < READY_SECONDS )) || fail "haild did not report ready within ${READY_SECONDS}s; see $LOGS/haild.err.log"
    sleep 1
  done
  echo "haild ready: $(current_release)"
}

status() {
  local installed running="" link=""
  installed="$(current_release)"
  echo "installed: $installed"
  [[ -L "$BIN/haild" ]] && link="$(readlink "$BIN/haild")"
  echo "PATH haild: $BIN/haild -> ${link:-missing}"
  if [[ -f "$PLIST" ]]; then
    running="$(plutil -extract ProgramArguments.0 raw -o - "$PLIST")"
  fi
  echo "LaunchAgent program: ${running:-not installed}"
  if "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1; then echo "job: loaded"; else echo "job: not loaded"; fi
  if "$LAUNCHCTL" print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
    echo "warning: legacy job $LEGACY_LABEL is still loaded; run scripts/host.sh restart"
  fi
  if [[ -n "$running" && "$running" != "$installed" ]]; then
    echo "drift: the daemon runs an older release than the one installed; run scripts/host.sh restart"
    return 3
  fi
  return 0
}

case "${1:-}" in
  install) shift; install_release "$@" ;;
  plist) print_plist ;;
  restart) restart ;;
  status) status ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
