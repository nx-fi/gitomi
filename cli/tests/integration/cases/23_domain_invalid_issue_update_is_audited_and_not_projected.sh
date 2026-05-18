#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="domain-invalid issue update is audited and not projected"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

domain_invalid="$ROOT/domain-invalid"
init_repo "$domain_invalid"
(
  cd "$domain_invalid"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  missing_issue="018f0000-0000-7000-8000-000000000111"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000112","event_type":"issue.title_set","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000111"},"idempotency_key":"018f0000-0000-7000-8000-000000000113","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"No opener"}}'
  bad_commit="$(git commit-tree -S -m "issue.title_set #$(object_ref "$missing_issue")" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"object_not_created"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  gt fsck >/dev/null
)

