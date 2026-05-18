#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="quarantine adopt fast-forwards past indexed authorization events"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

quarantine_ff_auth="$ROOT/quarantine-ff-auth"
mkdir -p "$quarantine_ff_auth"
git -C "$quarantine_ff_auth" init --bare remote.git >/dev/null
init_repo "$quarantine_ff_auth/source"
init_repo "$quarantine_ff_auth/replica"
git -C "$quarantine_ff_auth/source" remote add origin "$quarantine_ff_auth/remote.git"
git -C "$quarantine_ff_auth/replica" remote add origin "$quarantine_ff_auth/remote.git"
(
  cd "$quarantine_ff_auth/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device alice phone >/dev/null
  identity_head="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  printf '%s\n' "$identity_head" > "$quarantine_ff_auth/identity-head"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$quarantine_ff_auth/replica"
  gt sync --pull-only >/dev/null
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$(cat "$quarantine_ff_auth/identity-head")" "expected replica to index the shared authorization prefix"
)
(
  cd "$quarantine_ff_auth/source"
  gt issue open --title "Quarantine fast-forward adoption" >/dev/null
  quarantine_head="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  printf '%s\n' "$quarantine_head" > "$quarantine_ff_auth/quarantine-head"
  git push origin refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$quarantine_ff_auth/replica"
  quarantine_head="$(cat "$quarantine_ff_auth/quarantine-head")"
  quarantine_ref="refs/gitomi/quarantine/origin/inbox/alice/laptop/${quarantine_head:0:12}"
  git fetch origin "refs/gitomi/inbox/alice/laptop:$quarantine_ref" >/dev/null
  gt quarantine adopt "$quarantine_ref" --yes >quarantine-adopt.out 2>&1
  output="$(cat quarantine-adopt.out)"
  assert_not_contains "$output" "duplicate_event_hash"
  assert_contains "$output" "adopted $quarantine_ref into refs/gitomi/inbox/alice/laptop"
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$quarantine_head" "expected quarantine adoption to fast-forward the local inbox"
  gt fsck >/dev/null
)

