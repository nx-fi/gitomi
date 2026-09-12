#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim CAS races on absent and existing ledger tips"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
gt claim ls >/dev/null # Warm the shared inbox authorization projection.
export CLAIM_REAL_GIT="$(command -v git)"
mkdir -p "$ROOT/bin"
write_bash_script "$ROOT/bin/git" <<'SH'
if [[ "$1" == fetch || "$1" == push ]]; then
  echo 'claims must not access the network' >&2
  exit 99
fi
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
for round in absent existing; do
  export CLAIM_BARRIER="$ROOT/$round"
  mkdir -p "$CLAIM_BARRIER"
  (
    status=0
    CLAIM_RACE_ACTOR=a GT_CLAIM_RUN_ID=018f0000-0000-7000-8000-000000000011 gt claim acquire 'src/**' --json >"$CLAIM_BARRIER/a.out" 2>&1 || status=$?
    echo "$status" >"$CLAIM_BARRIER/a.status"
  ) &
  pid_a=$!
  (
    status=0
    CLAIM_RACE_ACTOR=b GT_CLAIM_RUN_ID=018f0000-0000-7000-8000-000000000012 gt claim acquire src/auth.zig --json >"$CLAIM_BARRIER/b.out" 2>&1 || status=$?
    echo "$status" >"$CLAIM_BARRIER/b.status"
  ) &
  pid_b=$!
  wait "$pid_a"
  wait "$pid_b"
  codes="$(sort "$CLAIM_BARRIER/a.status" "$CLAIM_BARRIER/b.status" | tr '\n' ' ')"
  assert_equal "$codes" '0 3 ' "exactly one racer must acquire; loser must reread and report conflict ($round)"
  assert_file "$CLAIM_BARRIER/passed-a"
  assert_file "$CLAIM_BARRIER/passed-b"
  assert_line_count "$(git ls-tree -r --name-only refs/gitomi/claims/ledger)" 1
  gt claim release --all >/dev/null
done

# Lock contention has its own bounded retry exit, not a conflict or IO result.
write_bash_script "$ROOT/bin/git" <<'SH'
if [[ "$1" == update-ref && "$*" == *refs/gitomi/claims/ledger* ]]; then
  echo "fatal: cannot lock ref 'refs/gitomi/claims/ledger': File exists" >&2
  exit 1
fi
exec "$CLAIM_REAL_GIT" "$@"
SH
status=0
gt claim acquire contention.txt >"$ROOT/contention.out" 2>&1 || status=$?
assert_equal "$status" 5 'CAS exhaustion must be contention'
assert_contains "$(cat "$ROOT/contention.out")" 'Retry the same command'
