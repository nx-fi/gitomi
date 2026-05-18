#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="duplicate opened event is audited and only one object projects"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

duplicate_open="$ROOT/duplicate-open"
init_repo "$duplicate_open"
(
  cd "$duplicate_open"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  issue_id="018f0000-0000-7000-8000-000000000211"
  body1='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000212","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000211"},"idempotency_key":"018f0000-0000-7000-8000-000000000213","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"First open"}}'
  first_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") First open" -m "$body1" "$empty_tree" -p "$genesis_head")"
  body2='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000214","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000211"},"idempotency_key":"018f0000-0000-7000-8000-000000000215","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:31:00Z","parent_hashes":{"log":"'"$first_commit"'","anchor":"","causal":[],"related":["'"$first_commit"'"]},"legacy":{},"payload":{"title":"Second open"}}'
  second_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") Second open" -m "$body2" -p "$first_commit" "$empty_tree")"
  git update-ref refs/gitomi/inbox/alice/laptop "$second_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"domain_status":"accepted"'
  assert_contains "$events" '"rejection_reason":"duplicate_object_id"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  gt fsck >/dev/null
)

