#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="signing key must match actor device"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

signature_binding="$ROOT/signature-binding"
init_repo "$signature_binding"
(
  cd "$signature_binding"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  issue_id="018f0000-0000-7000-8000-000000002301"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002302","event_type":"issue.opened","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002303","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:00Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Wrong signer"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") Wrong signer" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"signing_key_mismatch"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  if gt fsck >fsck-binding.out 2>&1; then
    fail "expected fsck to reject wrong signer for actor device"
  fi
  assert_contains "$(cat fsck-binding.out)" "signing_key_mismatch"
)

