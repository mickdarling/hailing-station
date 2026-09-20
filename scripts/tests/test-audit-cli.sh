#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hail-audit-cli.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -m 700 "$scratch/audit"
cp fixtures/audit/chain-v1.jsonl "$scratch/audit/2026-09-19.jsonl"
chmod 600 "$scratch/audit/2026-09-19.jsonl"

records="$(wc -l < "$scratch/audit/2026-09-19.jsonl" | tr -d ' ')"
verified="$(HAIL_CONFIG_DIR="$scratch" .build/debug/haild audit verify)"
[[ "$verified" == "verified 1 day, $records records; tail 2026-09-19 "* ]]

HAIL_CONFIG_DIR="$scratch" .build/debug/haild audit tail > "$scratch/tail.out"
cmp fixtures/audit/chain-v1.jsonl "$scratch/tail.out"
HAIL_CONFIG_DIR="$scratch" .build/debug/haild audit today > /dev/null

if HAIL_CONFIG_DIR="$scratch/missing" .build/debug/haild audit verify 2> "$scratch/missing.err"; then
  echo "audit verify accepted a missing history" >&2
  exit 1
fi
grep -q "no audit history at" "$scratch/missing.err"

set +e
HAIL_CONFIG_DIR="$scratch" .build/debug/haild audit unknown 2> "$scratch/usage.err"
status=$?
set -e
[[ $status -eq 64 ]]
grep -q "haild audit verify|tail|today" "$scratch/usage.err"

# `verify.sh all` invokes this integration driver; keep policy CLI behavior on the same required CI path.
scripts/tests/test-policy-cli.sh
