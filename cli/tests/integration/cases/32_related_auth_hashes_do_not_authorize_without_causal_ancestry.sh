#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="related auth hashes do not authorize without causal ancestry"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

related_frontier="$ROOT/related-frontier"
init_repo "$related_frontier"
(
  cd "$related_frontier"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"

  grant_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002111","event_type":"acl.role_granted","object":{"kind":"acl","id":"acl:charlie"},"idempotency_key":"018f0000-0000-7000-8000-000000002211","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:33:10Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"principal":"charlie","role":"reporter"}}'
  grant_commit="$(git commit-tree -S -m "acl.role_granted charlie reporter" -m "$grant_body" "$empty_tree" -p "$genesis_head")"
  identity_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002112","event_type":"identity.device_added","object":{"kind":"identity","id":"identity:charlie:desktop"},"idempotency_key":"018f0000-0000-7000-8000-000000002212","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:33:11Z","parent_hashes":{"log":"'"$grant_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"principal":"charlie","device":"desktop","signing_key":{"scheme":"ssh","public_key":"'"$BOB_PUBLIC_KEY"'","fingerprint":"'"$BOB_FINGERPRINT"'"}}}'
  identity_commit="$(git commit-tree -S -m "identity.device_added charlie/desktop" -m "$identity_body" "$empty_tree" -p "$grant_commit")"
  charlie_issue_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002113","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002114"},"idempotency_key":"018f0000-0000-7000-8000-000000002213","actor":{"principal":"charlie","device":"desktop"},"seq":1,"occurred_at":"2026-05-13T18:33:12Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":["'"$identity_commit"'"]},"legacy":{},"payload":{"title":"Related only should not authorize"}}'
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  charlie_issue_commit="$(git commit-tree -S -m "issue.opened related-only auth" -m "$charlie_issue_body" "$empty_tree" -p "$genesis_head")"

  git update-ref refs/gitomi/inbox/alice/laptop "$identity_commit"
  git update-ref refs/gitomi/inbox/charlie/desktop "$charlie_issue_commit"
  events="$(gt events list --json)"
  charlie_line="$(printf '%s\n' "$events" | grep '"actor_principal":"charlie"')"
  assert_contains "$charlie_line" '"domain_status":"rejected"'
  assert_contains "$charlie_line" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Related only should not authorize"'
  gt fsck >/dev/null
)

