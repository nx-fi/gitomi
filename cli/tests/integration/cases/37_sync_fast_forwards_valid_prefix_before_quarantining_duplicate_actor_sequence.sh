#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="sync fast-forwards valid prefix before quarantining duplicate actor sequence"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

sync_ff_duplicate="$ROOT/sync-ff-duplicate"
mkdir -p "$sync_ff_duplicate"
git -C "$sync_ff_duplicate" init --bare remote.git >/dev/null
init_repo "$sync_ff_duplicate/source"
init_repo "$sync_ff_duplicate/replica"
git -C "$sync_ff_duplicate/source" remote add origin "$sync_ff_duplicate/remote.git"
git -C "$sync_ff_duplicate/replica" remote add origin "$sync_ff_duplicate/remote.git"
(
  cd "$sync_ff_duplicate/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  issue_id="018f0000-0000-7000-8000-000000002510"
  body1='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002511","event_type":"issue.opened","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002512","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:32Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Fast-forward prefix"}}'
  first_commit="$(git commit-tree -S -m "issue.opened fast-forward prefix" -m "$body1" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$first_commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_ff_duplicate/replica"
  gt sync --pull-only >/dev/null
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$(git -C "$sync_ff_duplicate/source" rev-parse refs/gitomi/inbox/alice/laptop)" "expected initial pull to admit first event"
)
(
  cd "$sync_ff_duplicate/source"
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  issue_id="018f0000-0000-7000-8000-000000002510"
  first_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  body2='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002513","event_type":"issue.updated","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002514","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:34:33Z","parent_hashes":{"log":"'"$first_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"Fast-forward valid prefix"}}'
  second_commit="$(git commit-tree -S -m "issue.updated fast-forward valid prefix" -m "$body2" "$empty_tree" -p "$first_commit")"
  body3='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002515","event_type":"issue.updated","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002516","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:34:34Z","parent_hashes":{"log":"'"$second_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"Fast-forward duplicate seq"}}'
  bad_commit="$(git commit-tree -S -m "issue.updated fast-forward duplicate seq" -m "$body3" "$empty_tree" -p "$second_commit")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  printf '%s\n' "$second_commit" > "$sync_ff_duplicate/second-prefix-commit"
  git push origin refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_ff_duplicate/replica"
  gt sync --pull-only >sync-ff-duplicate.out 2>&1
  output="$(cat sync-ff-duplicate.out)"
  assert_contains "$output" "seq 2 is not strictly greater than previous sequence 2"
  assert_contains "$output" "quarantined"
  assert_contains "$output" "fast-forwarded refs/gitomi/inbox/alice/laptop by first 1 valid event"
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$(cat "$sync_ff_duplicate/second-prefix-commit")" "expected fast-forward pull to stop at the valid prefix"
  gt fsck >/dev/null
)

