#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="concurrent renewals revalidate captured sequence after CAS failure"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
held="$(gt claim acquire 'src/**' --ttl 1m --json)"
id="$(json_field "$held" claim_id)"
export CLAIM_REAL_GIT="$(command -v git)"
export CLAIM_BARRIER="$ROOT/barrier"
mkdir -p "$ROOT/bin" "$CLAIM_BARRIER"
write_bash_script "$ROOT/bin/git" <<'SH'
if [[ "$1" == fetch || "$1" == push ]]; then exit 99; fi
if [[ "$1" == update-ref && "$*" == *refs/gitomi/claims/ledger* && -n "${CLAIM_RACE_ACTOR:-}" && ! -e "$CLAIM_BARRIER/passed-$CLAIM_RACE_ACTOR" ]]; then
  : > "$CLAIM_BARRIER/ready-$CLAIM_RACE_ACTOR"
  for ((i=0; i<500; i++)); do
    if [[ -e "$CLAIM_BARRIER/ready-a" && -e "$CLAIM_BARRIER/ready-b" ]]; then break; fi
    sleep 0.02
  done
  [[ -e "$CLAIM_BARRIER/ready-a" && -e "$CLAIM_BARRIER/ready-b" ]] || exit 98
  : > "$CLAIM_BARRIER/passed-$CLAIM_RACE_ACTOR"
fi
exec "$CLAIM_REAL_GIT" "$@"
SH
export PATH="$ROOT/bin:$PATH"
pids=()
for actor in a b; do
  (
    status=0
    CLAIM_RACE_ACTOR="$actor" gt claim renew "$id" --ttl 3m --lease-seq 1 --json >"$CLAIM_BARRIER/$actor.out" 2>&1 || status=$?
    echo "$status" >"$CLAIM_BARRIER/$actor.status"
  ) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
assert_equal "$(sort "$CLAIM_BARRIER/a.status" "$CLAIM_BARRIER/b.status" | tr '\n' ' ')" '0 4 ' 'exactly one captured token can renew; CAS loser must observe the new sequence'
assert_file "$CLAIM_BARRIER/passed-a"
assert_file "$CLAIM_BARRIER/passed-b"
assert_contains "$(gt claim ls --json)" '"lease_seq":2'
assert_equal "$(git rev-list --count refs/gitomi/claims/ledger)" 2 'losing renewal must not publish another update'
