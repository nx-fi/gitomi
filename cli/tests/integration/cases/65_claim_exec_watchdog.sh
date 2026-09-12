#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim exec watchdog stops paused workers and survives a paused or killed caller"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
[[ "$(uname -s)" == Linux && "$(uname -m)" =~ ^(x86_64|aarch64)$ ]] || exit 0
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claim_fixtures.sh"
# Workers ignore TERM, fork a descendant, and try a delayed effect. The watchdog
# must kill and reap the whole group before expiry, including stopped processes.
for scenario in deadline worker_paused caller_paused caller_killed canceled; do
  ttl=120
  [[ "$scenario" != deadline && "$scenario" != worker_paused && "$scenario" != caller_paused ]] || ttl=12
  seed_short_claim "$scenario" "$ttl"
  "$GT_BIN" claim exec "$CLAIM_ID" --lease-seq 1 --expires-at "$CLAIM_EXPIRES" -- bash -c '
    trap "" TERM
    echo $$ > worker.pid
    bash -c '\''trap "" TERM; echo $$ > descendant.pid; sleep 60; touch escaped-effect'\'' &
    wait
  ' >"$ROOT/$scenario.out" 2>&1 &
  caller=$!
  wait_file worker.pid
  wait_file descendant.pid
  worker="$(cat worker.pid)"
  descendant="$(cat descendant.pid)"
  case "$scenario" in
    worker_paused) kill -STOP "$worker" ;;
    caller_paused) kill -STOP "$caller" ;;
    caller_killed) kill -KILL "$caller" ;;
    canceled) kill -TERM "$caller" ;;
  esac
  if [[ "$scenario" == caller_paused ]]; then
    # The invoking process is stopped; its independent watchdog must still run.
    for ((probe=0; probe<500; probe++)); do
      [[ -e "/proc/$worker/stat" ]] || break
      sleep 0.025
    done
    kill -CONT "$caller"
  fi
  status=0
  wait "$caller" || status=$?
  expected=4
  [[ "$scenario" != caller_killed ]] || expected=137
  [[ "$scenario" != canceled ]] || expected=1
  assert_equal "$status" "$expected" "watchdog result: $scenario"
  assert_process_gone "$worker"
  assert_process_gone "$descendant"
  (( $(date +%s) < CLAIM_DEADLINE )) || fail 'abort did not finish before the holder deadline'
  [[ ! -e escaped-effect ]] || fail 'worker performed an effect after abort'
  assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$CLAIM_HEAD" 'watchdog must not renew, release, or reap'
done
