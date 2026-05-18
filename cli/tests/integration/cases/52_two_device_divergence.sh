#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="two-device divergence"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

div_root="$ROOT/divergence"
mkdir -p "$div_root"
git -C "$div_root" init --bare remote.git >/dev/null
init_repo "$div_root/laptop"
init_repo "$div_root/desktop"
git -C "$div_root/laptop" remote add origin "$div_root/remote.git"
git -C "$div_root/desktop" remote add origin "$div_root/remote.git"
(
  cd "$div_root/laptop"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device alice desktop >/dev/null
  gt issue open --title "Laptop issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$div_root/desktop"
  gt sync --pull-only >/dev/null
  write_gt_config "$REPO_ID" alice desktop 0
  gt issue open --title "Desktop issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$div_root/laptop"
  gt sync --pull-only >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  assert_contains "$refs" "refs/gitomi/inbox/alice/desktop"
  json="$(gt events list --json)"
  assert_line_count "$json" 3
  assert_contains "$json" '"actor_device":"laptop"'
  assert_contains "$json" '"actor_device":"desktop"'
  gt fsck >/dev/null
)

