#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim renewal preserves identity, advances tokens, and refuses stale leases"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
export GT_CLAIM_RUN_ID=018f0000-0000-7000-8000-000000000011
original="$(gt claim acquire 'src/**' --ttl 30s --reason 'retain this reason' --json)"
id="$(json_field "$original" claim_id)"
old="$(git show "refs/gitomi/claims/ledger:claims/$id.json")"
renewed="$(gt claim renew "$id" --ttl 2m --lease-seq 1 --json)"
assert_contains "$renewed" '"lease_seq":2'
assert_contains "$renewed" '"established":true'
new="$(git show "refs/gitomi/claims/ledger:claims/$id.json")"
assert_equal "$(printf '%s' "$old" | sed 's/"lease_seq":[0-9]*/"lease_seq":N/; s/"expires_at":"[^"]*"/"expires_at":"DATE"/')" \
  "$(printf '%s' "$new" | sed 's/"lease_seq":[0-9]*/"lease_seq":N/; s/"expires_at":"[^"]*"/"expires_at":"DATE"/')" 'only the deadline and fencing sequence change'
assert_contains "$(git show -s --format=%B refs/gitomi/claims/ledger)" '"op":"renew"'
head="$(git rev-parse refs/gitomi/claims/ledger)"
for refusal in token run duration missing; do
  status=0
  case "$refusal" in
    token) gt claim renew "$id" --ttl 3m --lease-seq 1 >"$ROOT/refusal" 2>&1 || status=$? ;;
    run) gt claim renew "$id" --ttl 3m --run-id 018f0000-0000-7000-8000-000000000012 >"$ROOT/refusal" 2>&1 || status=$? ;;
    duration) gt claim renew "$id" --ttl 30s >"$ROOT/refusal" 2>&1 || status=$? ;;
    missing) gt claim renew 018f0000-0000-7000-8000-000000000099 >"$ROOT/refusal" 2>&1 || status=$? ;;
  esac
  expected=4
  [[ "$refusal" != duration ]] || expected=1
  assert_equal "$status" "$expected" "renewal refusal status: $refusal"
  assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$head" 'refused renewal must not advance the ledger'
  assert_contains "$(cat "$ROOT/refusal")" 'lease'
done
assert_contains "$(gt claim renew "$id" --ttl 3m)" 'lease_seq=3'
gt claim release "$id" >/dev/null
status=0
gt claim renew "$id" >"$ROOT/released" 2>&1 || status=$?
assert_equal "$status" 4 'release makes the captured lease stale'

# Signed initial-state fixtures exercise deadlines without waiting for full TTLs.
# The slow-signer case deliberately outlasts an otherwise valid old lease.
export CLAIM_REAL_GIT="$(command -v git)"
mkdir -p "$ROOT/bin"
write_bash_script "$ROOT/bin/git" <<'SH'
if [[ "$1" == fetch || "$1" == push ]]; then exit 99; fi
if [[ "$1" == commit-tree && -n "${CLAIM_SLOW_SIGNER:-}" ]]; then
  : > "$CLAIM_SLOW_SIGNER"
  sleep 12
fi
exec "$CLAIM_REAL_GIT" "$@"
SH
export PATH="$ROOT/bin:$PATH"
unset GT_CLAIM_RUN_ID
for scenario in expired revoked lifetime slow; do
  init_repo "$ROOT/$scenario"
  cd "$ROOT/$scenario"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  now="$(date +%s)"
  acquired="$(date -u -d "@$((now - 120))" +%Y-%m-%dT%H:%M:%SZ)"
  end=$((now + 120))
  revoked=false
  [[ "$scenario" != expired ]] || end=$((now - 1))
  [[ "$scenario" != revoked ]] || revoked=true
  [[ "$scenario" != slow ]] || end=$((now + 10))
  expires="$(date -u -d "@$end" +%Y-%m-%dT%H:%M:%SZ)"
  record='{"$schema":"urn:gitomi:claim:v1","repo_id":"'"$REPO_ID"'","claim_id":"'"$id"'","lease_seq":1,"holder":{"principal":"alice","device":"laptop"},"mode":"write","paths":["src/**"],"acquired_at":"'"$acquired"'","expires_at":"'"$expires"'","revoked":'"$revoked"',"reason":"fixture"}'
  blob="$(printf '%s' "$record" | git hash-object -w --stdin)"
  subtree="$(printf '100644 blob %s\t%s.json\n' "$blob" "$id" | git mktree)"
  tree="$(printf '040000 tree %s\tclaims\n' "$subtree" | git mktree)"
  body='{"$schema":"urn:gitomi:claim-delta:v1","repo_id":"'"$REPO_ID"'","writer":{"principal":"alice","device":"laptop"},"actions":[{"op":"acquire","claim_id":"'"$id"'"}],"wrote_at":"'"$acquired"'"}'
  head="$(git commit-tree -S "$tree" -m claim.acquire -m "$body")"
  git update-ref refs/gitomi/claims/ledger "$head" ''
  gt claim ls --all >/dev/null
  ttl=15m
  [[ "$scenario" != lifetime ]] || ttl=4h
  status=0
  if [[ "$scenario" == slow ]]; then
    CLAIM_SLOW_SIGNER="$ROOT/signer-ran" gt claim renew "$id" --ttl "$ttl" >"$ROOT/$scenario.out" 2>&1 || status=$?
    assert_file "$ROOT/signer-ran"
  else
    gt claim renew "$id" --ttl "$ttl" >"$ROOT/$scenario.out" 2>&1 || status=$?
  fi
  expected=4
  [[ "$scenario" != lifetime ]] || expected=1
  assert_equal "$status" "$expected" "renewal must refuse $scenario"
  assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$head" 'failed renewal preserves ledger'
  if [[ "$scenario" == revoked ]]; then
    assert_contains "$(gt claim ls)" REVOKED
    status=0
    gt claim acquire src/file --run-id 018f0000-0000-7000-8000-000000000012 >"$ROOT/revoked-conflict" 2>&1 || status=$?
    assert_equal "$status" 3 'revocation still excludes peers until expiry'
  fi
done
