#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="sync admits valid prefix before quarantining duplicate actor sequence"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

sync_duplicate_prefix="$ROOT/sync-duplicate-prefix"
mkdir -p "$sync_duplicate_prefix"
git -C "$sync_duplicate_prefix" init --bare remote.git >/dev/null
init_repo "$sync_duplicate_prefix/source"
init_repo "$sync_duplicate_prefix/replica"
git -C "$sync_duplicate_prefix/source" remote add origin "$sync_duplicate_prefix/remote.git"
git -C "$sync_duplicate_prefix/replica" remote add origin "$sync_duplicate_prefix/remote.git"
(
  cd "$sync_duplicate_prefix/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  body1='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002501","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002500"},"idempotency_key":"018f0000-0000-7000-8000-000000002502","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:30Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Valid prefix"}}'
  first_commit="$(git commit-tree -S -m "issue.opened valid prefix" -m "$body1" "$empty_tree" -p "$genesis_head")"
  body2='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002503","event_type":"issue.updated","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002500"},"idempotency_key":"018f0000-0000-7000-8000-000000002504","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:31Z","parent_hashes":{"log":"'"$first_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"Duplicate seq"}}'
  bad_commit="$(git commit-tree -S -m "issue.updated duplicate seq" -m "$body2" "$empty_tree" -p "$first_commit")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  printf '%s\n' "$first_commit" > "$sync_duplicate_prefix/first-prefix-commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_duplicate_prefix/replica"
  gt sync --pull-only >sync-duplicate-prefix.out 2>&1
  output="$(cat sync-duplicate-prefix.out)"
  assert_contains "$output" "seq 1 is not strictly greater than previous sequence 1"
  assert_contains "$output" "quarantined"
  assert_contains "$output" "created refs/gitomi/inbox/alice/laptop with first 1 valid event"
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$(cat "$sync_duplicate_prefix/first-prefix-commit")" "expected local inbox to stop at the valid prefix"
  quarantine_refs="$(git for-each-ref --format='%(refname)' refs/gitomi/quarantine)"
  assert_contains "$quarantine_refs" "refs/gitomi/quarantine/origin/inbox/alice/laptop"
  gt fsck >/dev/null
)

