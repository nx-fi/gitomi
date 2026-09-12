#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="signed renewal admission verifies the previous lease and immutable fields"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
for scenario in sequence acquired expires holder; do
  init_repo "$ROOT/$scenario"
  cd "$ROOT/$scenario"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  held="$(gt claim acquire src/file --ttl 15m --json)"
  id="$(json_field "$held" claim_id)"
  head="$(git rev-parse refs/gitomi/claims/ledger)"
  old="$(git show "$head:claims/$id.json")"
  wrote="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  end="$(date -u -d '@'"$(($(date +%s) + 1800))" +%Y-%m-%dT%H:%M:%SZ)"
  record="$(printf '%s' "$old" | sed 's/"lease_seq":1/"lease_seq":2/; s/"expires_at":"[^"]*"/"expires_at":"'"$end"'"/')"
  case "$scenario" in
    sequence) record="$(printf '%s' "$record" | sed 's/"lease_seq":2/"lease_seq":1/')" ;;
    acquired) record="$(printf '%s' "$record" | sed 's/"acquired_at":"[^"]*"/"acquired_at":"'"$end"'"/; s/"expires_at":"[^"]*"/"expires_at":"'"$(date -u -d '@'"$(($(date +%s) + 2700))" +%Y-%m-%dT%H:%M:%SZ)"'"/')" ;;
    expires) record="$(printf '%s' "$old" | sed 's/"lease_seq":1/"lease_seq":2/')" ;;
    holder) record="$(printf '%s' "$record" | sed 's/"principal":"alice"/"principal":"bob"/; s/"device":"laptop"/"device":"desktop"/')" ;;
  esac
  blob="$(printf '%s' "$record" | git hash-object -w --stdin)"
  subtree="$(printf '100644 blob %s\t%s.json\n' "$blob" "$id" | git mktree)"
  tree="$(printf '040000 tree %s\tclaims\n' "$subtree" | git mktree)"
  body='{"$schema":"urn:gitomi:claim-delta:v1","repo_id":"'"$REPO_ID"'","writer":{"principal":"alice","device":"laptop"},"actions":[{"op":"renew","claim_id":"'"$id"'"}],"wrote_at":"'"$wrote"'"}'
  if [[ "$scenario" == holder ]]; then
    configure_bob_signing "$PWD"
    body="$(printf '%s' "$body" | sed 's/"principal":"alice"/"principal":"bob"/; s/"device":"laptop"/"device":"desktop"/')"
  fi
  bad="$(git commit-tree -S "$tree" -p "$head" -m claim.renew -m "$body")"
  git update-ref refs/gitomi/claims/ledger "$bad" "$head"
  status=0
  gt claim check unrelated >"$ROOT/$scenario.out" 2>&1 || status=$?
  assert_equal "$status" 1 "signed invalid renewal must fail closed: $scenario"
  assert_contains "$(cat "$ROOT/$scenario.out")" UnauthorizedClaimDelta
  assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$bad" 'refusal must not overwrite invalid history'
done
