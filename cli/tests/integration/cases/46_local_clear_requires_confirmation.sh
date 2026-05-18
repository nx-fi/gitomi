#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="local clear requires confirmation"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

clear_local="$ROOT/clear-local"
init_repo "$clear_local"
(
  cd "$clear_local"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Local clear issue" >/dev/null
  if printf 'no\n' | gt clear local >/dev/null 2>&1; then
    fail "expected local clear to abort on mismatched confirmation"
  fi
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/genesis"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  printf 'delete local gitomi refs\n' | gt clear local >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "no Gitomi refs"
  assert_file ".git/gitomi/config.toml"
)

