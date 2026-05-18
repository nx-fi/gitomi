#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="sync quarantines inactive actor devices"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

sync_device_binding="$ROOT/sync-device-binding"
mkdir -p "$sync_device_binding"
git -C "$sync_device_binding" init --bare remote.git >/dev/null
init_repo "$sync_device_binding/source"
init_repo "$sync_device_binding/replica"
git -C "$sync_device_binding/source" remote add origin "$sync_device_binding/remote.git"
git -C "$sync_device_binding/replica" remote add origin "$sync_device_binding/remote.git"
(
  cd "$sync_device_binding/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002412","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002411"},"idempotency_key":"018f0000-0000-7000-8000-000000002413","actor":{"principal":"alice","device":"phone"},"seq":1,"occurred_at":"2026-05-13T18:34:20Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Inactive device from remote"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened inactive remote device" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/phone "$bad_commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/phone:refs/gitomi/inbox/alice/phone >/dev/null
)
(
  cd "$sync_device_binding/replica"
  gt sync --pull-only >sync-device-binding.out 2>&1
  assert_contains "$(cat sync-device-binding.out)" "unauthorized_device"
  assert_contains "$(cat sync-device-binding.out)" "quarantined"
  if git show-ref --verify --quiet refs/gitomi/inbox/alice/phone; then
    fail "expected inactive actor device inbox ref to stay out of authoritative refs"
  fi
)

