#!/bin/sh
# Synthetic wrapper: TERM exits the leader while its grandchild ignores TERM and holds stdout open.
trap 'exit 0' TERM
/bin/sh -c 'trap "" TERM; printf "%s %s\n" "$PPID" "$$"; exec /bin/sleep 30' &
wait
