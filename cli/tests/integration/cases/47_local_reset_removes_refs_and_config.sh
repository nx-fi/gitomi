#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="local reset removes refs and config"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

reset_local="$ROOT/reset-local"
init_repo "$reset_local"
(
  cd "$reset_local"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Local reset issue" >/dev/null
  gt issue list --json >/dev/null
  assert_file ".git/gitomi/config.toml"
  assert_file ".git/gitomi/index.sqlite"
  if printf 'no\n' | gt reset local >/dev/null 2>&1; then
    fail "expected local reset to abort on mismatched confirmation"
  fi
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/genesis"
  printf 'delete local gitomi state\n' | gt reset local >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "no Gitomi refs"
  [[ ! -e .git/gitomi/config.toml ]] || fail "expected config to be deleted"
  [[ ! -e .git/gitomi/index.sqlite ]] || fail "expected index to be deleted"
)

