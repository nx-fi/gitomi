#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="sync quarantines signer and actor device binding mismatches"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

sync_binding="$ROOT/sync-binding"
mkdir -p "$sync_binding"
git -C "$sync_binding" init --bare remote.git >/dev/null
init_repo "$sync_binding/source"
init_repo "$sync_binding/replica"
git -C "$sync_binding/source" remote add origin "$sync_binding/remote.git"
git -C "$sync_binding/replica" remote add origin "$sync_binding/remote.git"
(
  cd "$sync_binding/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002402","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002401"},"idempotency_key":"018f0000-0000-7000-8000-000000002403","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:10Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Wrong signer from remote"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened wrong remote signer" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_binding/replica"
  gt sync --pull-only >sync-binding.out 2>&1
  assert_contains "$(cat sync-binding.out)" "signing_key_mismatch"
  assert_contains "$(cat sync-binding.out)" "quarantined"
  if git show-ref --verify --quiet refs/gitomi/inbox/alice/laptop; then
    fail "expected signer mismatch inbox ref to stay out of authoritative refs"
  fi
)

