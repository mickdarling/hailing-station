#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hail-policy-cli.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

fake_tmux="$scratch/tmux"
fake_log="$scratch/tmux.log"
# These literal strings are the generated script; expansion belongs to that script at runtime.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "list-sessions" ]]; then' \
  '  printf '\''$1|1700000000|%%1|4242|cli\n'\''' \
  'elif [[ "${1:-}" == "send-keys" ]]; then' \
  '  printf '\''%s\n'\'' "$*" >> "$HAIL_FAKE_TMUX_LOG"' \
  'else' \
  '  exit 1' \
  'fi' > "$fake_tmux"
chmod 700 "$fake_tmux"

run_haild() {
  HAIL_CONFIG_DIR="$scratch/config" HAIL_TMUX="$fake_tmux" HAIL_FAKE_TMUX_LOG="$fake_log" \
    .build/debug/haild "$@"
}

run_haild_tty() {
  local response="$1"
  local payload="$2"
  # Tcl expands the env(...) references after the shell passes this script to expect.
  # shellcheck disable=SC2016
  HAIL_CONFIG_DIR="$scratch/config" HAIL_TMUX="$fake_tmux" HAIL_FAKE_TMUX_LOG="$fake_log" \
    HAIL_EXPECT_RESPONSE="$response" HAIL_EXPECT_PAYLOAD="$payload" /usr/bin/expect -c '
      set timeout 10
      spawn -noecho .build/debug/haild send tmux:cli $env(HAIL_EXPECT_PAYLOAD)
      expect {
        -exact "type send to deliver, anything else to cancel: " {
          send -- "$env(HAIL_EXPECT_RESPONSE)\r"
        }
        timeout { exit 124 }
        eof {
          set child_status [wait]
          exit [lindex $child_status 3]
        }
      }
      expect eof
      set child_status [wait]
      exit [lindex $child_status 3]
    '
}

set +e
run_haild send tmux:cli "echo denied" 2> "$scratch/denied.err"
status=$?
set -e
[[ $status -eq 7 ]]
grep -q "target tmux:cli is not allowed" "$scratch/denied.err"

run_haild targets allow tmux:cli > /dev/null
set +e
run_haild send tmux:cli "echo confirm" 2> "$scratch/non-tty.err"
status=$?
set -e
[[ $status -eq 8 ]]
grep -q "confirmation needed; run from a terminal" "$scratch/non-tty.err"

set +e
run_haild_tty cancel "echo cancel" > "$scratch/cancel.out" 2>&1
status=$?
set -e
[[ $status -eq 8 ]]
grep -q "cancelled" "$scratch/cancel.out"
[[ ! -e "$fake_log" ]]

run_haild_tty send "echo approved" > "$scratch/send.out" 2>&1
grep -q "sent 1 line to tmux:cli" "$scratch/send.out"
grep -q -- "send-keys -t %1 -l -- echo approved" "$fake_log"
grep -q -- "send-keys -t %1 Enter" "$fake_log"

printf 'not json' > "$scratch/config/policy.json"
chmod 600 "$scratch/config/policy.json"
set +e
run_haild status > "$scratch/unusable.out" 2>&1
status=$?
set -e
[[ $status -eq 9 ]]
grep -q "policy: UNUSABLE" "$scratch/unusable.out"
