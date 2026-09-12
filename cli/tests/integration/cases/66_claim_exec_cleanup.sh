#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim exec cleans background descendants and retains the captured deadline across renewal"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
[[ "$(uname -s)" == Linux && "$(uname -m)" =~ ^(x86_64|aarch64)$ ]] || exit 0
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claim_fixtures.sh"
seed_short_claim background 120
# The foreground shell exits successfully while a background child is alive.
gt claim exec "$CLAIM_ID" --lease-seq 1 --expires-at "$CLAIM_EXPIRES" -- bash -c '
  bash -c '\''echo $$ > background.pid; sleep 60; touch escaped-effect'\'' &
  while [[ ! -s background.pid ]]; do sleep 0.01; done
'
assert_process_gone "$(cat background.pid)"
[[ ! -e escaped-effect ]] || fail 'background command outlived supervision'
if command -v setsid >/dev/null 2>&1; then
  status=0
  gt claim exec "$CLAIM_ID" --lease-seq 1 --expires-at "$CLAIM_EXPIRES" -- setsid --wait bash -c 'touch escaped-session' >"$ROOT/setsid.out" 2>&1 || status=$?
  assert_equal "$status" 1 'session escape must be refused'
  [[ ! -e escaped-session ]] || fail 'worker escaped the killable group'
fi
# stdin, cwd, and raw stdout/stderr are preserved for foreground commands.
mkdir subdir
cd subdir
assert_equal "$(printf 'input\n' | gt claim exec "$CLAIM_ID" --lease-seq 1 --expires-at "$CLAIM_EXPIRES" -- bash -c 'read -r x; printf "%s:%s" "$x" "${PWD##*/}"')" 'input:subdir' 'command context must be preserved'
# Inherited automatic child reaping must not defeat group-leader PID pinning.
(trap '' CHLD; exec "$GT_BIN" claim exec "$CLAIM_ID" --lease-seq 1 --expires-at "$CLAIM_EXPIRES" -- true)
seed_short_claim renewed 12
"$GT_BIN" claim exec "$CLAIM_ID" --lease-seq 1 --expires-at "$CLAIM_EXPIRES" -- bash -c 'echo $$ > worker.pid; sleep 60; touch escaped-effect' >"$ROOT/renewed.out" 2>&1 &
caller=$!
wait_file worker.pid
worker="$(cat worker.pid)"
# A newer ledger record cannot silently replace the sequence/deadline captured
# by an operation already in progress. This supervisor aborts; it never renews.
gt claim renew "$CLAIM_ID" --ttl 1m --lease-seq 1 >/dev/null
status=0
wait "$caller" || status=$?
assert_equal "$status" 4 'external renewal must not extend an old operation'
assert_process_gone "$worker"
(( $(date +%s) < CLAIM_DEADLINE )) || fail 'old token exceeded its own deadline'
assert_contains "$(gt claim ls --json)" '"lease_seq":2'
[[ ! -e escaped-effect ]] || fail 'old token ran into a renewed lease'
