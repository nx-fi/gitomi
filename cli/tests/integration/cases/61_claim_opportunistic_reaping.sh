#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim writes opportunistically reap expired records without deleting live peers"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
now="$(date +%s)"
acquired="$(date -u -d "@$((now - 300))" +%Y-%m-%dT%H:%M:%SZ)"
# One long-expired claim, a long-expired revocation, and a live revocation.
# Bob signs the initial acquisition; Alice may reap only the first two.
expired=018f0000-0000-7000-8000-000000000021
revoked_expired=018f0000-0000-7000-8000-000000000022
revoked_live=018f0000-0000-7000-8000-000000000023
: > "$ROOT/tree-list"
actions=''
for id in "$expired" "$revoked_expired" "$revoked_live"; do
  end=$((now - 120))
  revoked=true
  [[ "$id" != "$expired" ]] || revoked=false
  [[ "$id" != "$revoked_live" ]] || end=$((now + 600))
  expires="$(date -u -d "@$end" +%Y-%m-%dT%H:%M:%SZ)"
  record='{"$schema":"urn:gitomi:claim:v1","repo_id":"'"$REPO_ID"'","claim_id":"'"$id"'","lease_seq":1,"holder":{"principal":"bob","device":"desktop"},"mode":"write","paths":["peer/'"$id"'"],"acquired_at":"'"$acquired"'","expires_at":"'"$expires"'","revoked":'"$revoked"',"reason":"fixture"}'
  blob="$(printf '%s' "$record" | git hash-object -w --stdin)"
  printf '100644 blob %s\t%s.json\n' "$blob" "$id" >> "$ROOT/tree-list"
  actions+="${actions:+,}"'{"op":"acquire","claim_id":"'"$id"'"}'
done
subtree="$(git mktree < "$ROOT/tree-list")"
tree="$(printf '040000 tree %s\tclaims\n' "$subtree" | git mktree)"
body='{"$schema":"urn:gitomi:claim-delta:v1","repo_id":"'"$REPO_ID"'","writer":{"principal":"bob","device":"desktop"},"actions":['"$actions"'],"wrote_at":"'"$acquired"'"}'
configure_bob_signing "$PWD"
head="$(git commit-tree -S "$tree" -m claim.acquire -m "$body")"
git update-ref refs/gitomi/claims/ledger "$head" ''
configure_signing "$PWD"
# Read-only operations neither reap nor write.
gt claim ls --all >/dev/null
gt peers >/dev/null
gt claim check unrelated >/dev/null
assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$head" 'reads must not reap'
# Nor may a refused acquisition turn into a successful sweep.
status=0
gt claim acquire "peer/$revoked_live" >"$ROOT/blocked" 2>&1 || status=$?
assert_equal "$status" 3 'live revocation must still conflict'
assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$head" 'conflicts must not mutate'
held="$(gt claim acquire unrelated --json)"
own="$(json_field "$held" claim_id)"
listing="$(git ls-tree -r --name-only refs/gitomi/claims/ledger)"
assert_line_count "$listing" 2
assert_contains "$listing" "$revoked_live.json"
assert_contains "$listing" "$own.json"
assert_not_contains "$listing" "$expired.json"
assert_not_contains "$listing" "$revoked_expired.json"
delta="$(git show -s --format=%B refs/gitomi/claims/ledger)"
assert_contains "$delta" '"op":"acquire"'
assert_contains "$delta" '"op":"reap","claim_id":"'"$expired"'","expired_at":'
assert_contains "$delta" '"op":"reap","claim_id":"'"$revoked_expired"'","expired_at":'
assert_equal "$(git rev-parse "refs/gitomi/claims/ledger:claims/$revoked_live.json")" \
  "$(git rev-parse "$head:claims/$revoked_live.json")" 'unexpired peer bytes must be unchanged'
gt claim ls --all >/dev/null # Revalidate the new signed delta from scratch.
assert_equal "$(gt claim release "$own")" 'Released 1 claim(s) (single-store).' 'release count excludes unrelated reaps'
assert_equal "$(git ls-tree -r --name-only refs/gitomi/claims/ledger)" "claims/$revoked_live.json" 'live peer remains after holder release'
