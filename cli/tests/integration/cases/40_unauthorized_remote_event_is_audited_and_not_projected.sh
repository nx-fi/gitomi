#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="unauthorized remote event is audited and not projected"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

unauthorized="$ROOT/unauthorized"
init_repo "$unauthorized"
(
  cd "$unauthorized"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  issue_id="018f0000-0000-7000-8000-000000000311"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000312","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000311"},"idempotency_key":"018f0000-0000-7000-8000-000000000313","actor":{"principal":"mallory","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Unauthorized"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") Unauthorized" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/mallory/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  gt fsck >/dev/null
)

