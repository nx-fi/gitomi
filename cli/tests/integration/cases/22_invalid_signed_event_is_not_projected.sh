#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="invalid signed event is not projected"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

invalid="$ROOT/invalid"
init_repo "$invalid"
(
  cd "$invalid"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000002","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000003"},"idempotency_key":"018f0000-0000-7000-8000-000000000004","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{}}'
  bad_commit="$(git commit-tree -S -m "bad issue" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 0
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  if gt fsck >fsck.out 2>&1; then
    fail "expected fsck to reject invalid signed event"
  fi
  assert_contains "$(cat fsck.out)" "issue.opened payload.title"
)

