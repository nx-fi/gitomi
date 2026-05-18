#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="issue.updated applies milestone and projects"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

issue_updated_metadata="$ROOT/issue-updated-metadata"
init_repo "$issue_updated_metadata"
(
  cd "$issue_updated_metadata"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Metadata batch" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  base_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  update_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000000901","event_type":"issue.updated","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000000902","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:31:00Z","parent_hashes":{"log":"'"$base_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"milestone":"v2.0","projects":[{"project":"Roadmap","column":"Doing"}]}}'
  update_commit="$(git commit-tree -S -m "issue.updated metadata batch" -m "$update_body" "$empty_tree" -p "$base_commit")"
  git update-ref refs/gitomi/inbox/alice/laptop "$update_commit" "$base_commit"
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"milestone":"v2.0"'
  assert_contains "$issues" '"projects":[{"project":"Roadmap","column":"Doing"}]'
  issue_show="$(gt issue show "#$(object_ref "$issue_id")")"
  assert_contains "$issue_show" "milestone: v2.0"
  assert_contains "$issue_show" "projects:  Roadmap / Doing"
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"event_type":"issue.updated"'
  gt fsck >/dev/null
)

