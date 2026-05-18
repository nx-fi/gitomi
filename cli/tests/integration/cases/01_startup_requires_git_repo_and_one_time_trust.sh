#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="startup requires git repo and one-time trust"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

not_repo="$ROOT/not-repo"
mkdir -p "$not_repo"
(
  cd "$not_repo"
  if gt status >not-repo.out 2>&1; then
    fail "expected status outside git repo to fail"
  fi
  assert_contains "$(cat not-repo.out)" "not a git repo"
)
trust_prompt="$ROOT/trust-prompt"
mkdir -p "$trust_prompt"
git -C "$trust_prompt" init >/dev/null
(
  cd "$trust_prompt"
  if printf 'yes\n' | gt status >trust-prompt.out 2>&1; then
    fail "expected status before gt init to fail"
  fi
  assert_contains "$(cat trust-prompt.out)" "do you trust contents of this git repo?"
  assert_contains "$(cat trust-prompt.out)" "Gitomi is not initialized; run \`gt init\`"
  assert_file ".git/gitomi/trust"
  if gt status >trusted-status.out 2>&1; then
    fail "expected status before gt init to fail"
  fi
  assert_not_contains "$(cat trusted-status.out)" "do you trust contents of this git repo?"
)

