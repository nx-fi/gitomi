#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claims reject malformed trees, forged diffs, and unauthorized signed changes"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

for scenario in unsigned actions outside record conflicting delete parents; do
  init_repo "$ROOT/$scenario"
  (
    cd "$ROOT/$scenario"
    gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
    gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
    good="$(gt claim acquire 'src/**' --json)"
    id="$(json_field "$good" claim_id)"
    head="$(git rev-parse refs/gitomi/claims/ledger)"
    tree="$(git rev-parse "$head^{tree}")"
    wrote="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body='{"$schema":"urn:gitomi:claim-delta:v1","repo_id":"'"$REPO_ID"'","writer":{"principal":"alice","device":"laptop"},"actions":[{"op":"release","claim_id":"'"$id"'"}],"wrote_at":"'"$wrote"'"}'
    signing=(-S)
    parents=(-p "$head")
    expected=ClaimDeltaDiffMismatch
    case "$scenario" in
      unsigned)
        tree="$(git mktree </dev/null)"
        signing=()
        expected=UnverifiedClaimSigner
        ;;
      actions) ;; # Declared release with unchanged tree.
      outside)
        blob="$(printf bad | git hash-object -w --stdin)"
        tree="$(printf '100644 blob %s\toutside\n' "$blob" | git mktree)"
        expected=InvalidClaimTree
        ;;
      record)
        invalid="$(git show "$head:claims/$id.json" | sed 's/"lease_seq":1/"lease_seq":0/')"
        blob="$(printf '%s' "$invalid" | git hash-object -w --stdin)"
        subtree="$(printf '100644 blob %s\t%s.json\n' "$blob" "$id" | git mktree)"
        tree="$(printf '040000 tree %s\tclaims\n' "$subtree" | git mktree)"
        expected=InvalidClaim
        ;;
      conflicting)
        other=018f0000-0000-7000-8000-000000000099
        record="$(git show "$head:claims/$id.json" | sed "s/$id/$other/; s/\"principal\":\"alice\"/\"principal\":\"bob\"/; s/\"device\":\"laptop\"/\"device\":\"desktop\"/")"
        blob="$(printf '%s' "$record" | git hash-object -w --stdin)"
        original="$(git rev-parse "$head:claims/$id.json")"
        subtree="$(printf '100644 blob %s\t%s.json\n100644 blob %s\t%s.json\n' "$original" "$id" "$blob" "$other" | git mktree)"
        tree="$(printf '040000 tree %s\tclaims\n' "$subtree" | git mktree)"
        body="$(printf '%s' "$body" | sed "s/\"principal\":\"alice\"/\"principal\":\"bob\"/; s/\"device\":\"laptop\"/\"device\":\"desktop\"/; s/release/acquire/; s/$id/$other/")"
        configure_bob_signing "$PWD"
        expected=ConflictingClaimLedger
        ;;
      delete)
        tree="$(git mktree </dev/null)"
        body="$(printf '%s' "$body" | sed 's/"principal":"alice"/"principal":"bob"/; s/"device":"laptop"/"device":"desktop"/')"
        configure_bob_signing "$PWD"
        expected=UnauthorizedClaimDelta
        ;;
      parents)
        parents+=(-p "$(git rev-parse refs/gitomi/genesis)")
        expected=InvalidClaimParents
        ;;
    esac
    bad="$(git commit-tree "${signing[@]}" "$tree" "${parents[@]}" -m 'claim.release invalid' -m "$body")"
    git update-ref refs/gitomi/claims/ledger "$bad" "$head"
    status=0
    gt claim check unrelated.txt >"$ROOT/$scenario.out" 2>&1 || status=$?
    assert_equal "$status" 1 "invalid ledger must fail closed: $scenario"
    assert_contains "$(cat "$ROOT/$scenario.out")" "$expected"
    assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$bad" 'refusal must not overwrite invalid ledger'
  )
done

for scenario in broken symbolic; do
  init_repo "$ROOT/$scenario"
  (
    cd "$ROOT/$scenario"
    gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
    if [[ "$scenario" == broken ]]; then
      mkdir -p .git/refs/gitomi/claims
      printf 'invalid-object-id\n' > .git/refs/gitomi/claims/ledger
    else
      git symbolic-ref refs/gitomi/claims/ledger refs/gitomi/claims/missing
    fi
    status=0
    gt claim check anything.txt >"$ROOT/$scenario.out" 2>&1 || status=$?
    assert_equal "$status" 1 'a broken or dangling symbolic ledger must never look conflict-free'
  )
done
