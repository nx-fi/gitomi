#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="issue open requires gt init"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

no_init="$ROOT/no-init"
init_repo "$no_init"
(
  cd "$no_init"
  if gt issue open --title "No init issue" >no-init.out 2>&1; then
    fail "expected issue open to fail before gt init"
  fi
  assert_contains "$(cat no-init.out)" "Gitomi is not initialized; run \`gt init\`"
  refs="$(gt refs)"
  assert_contains "$refs" "no Gitomi refs"
)

