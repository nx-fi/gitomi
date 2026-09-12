#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim hook installation preserves existing hooks and supports configured paths and worktrees"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
mkdir "$ROOT/bin"
ln -s "$GT_BIN" "$ROOT/bin/gt"
export PATH="$ROOT/bin:$PATH"
mine=018f0000-0000-7000-8000-000000000011

init_repo "$ROOT/existing"
(
  cd "$ROOT/existing"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  write_bash_script .git/hooks/pre-commit <<'SH'
exit 7
SH
  before="$(sha256sum .git/hooks/pre-commit)"
  status=0
  gt claim hook install >"$ROOT/existing.out" 2>&1 || status=$?
  assert_equal "$status" 1 'installer must refuse to overwrite an existing hook'
  assert_equal "$(sha256sum .git/hooks/pre-commit)" "$before" 'installer changed another hook'
  assert_contains "$(cat "$ROOT/existing.out")" 'gt claim hook print'
  assert_contains "$(gt claim hook print)" 'exec gt claim check --staged'
)

init_repo "$ROOT/custom"
(
  cd "$ROOT/custom"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  git config core.hooksPath .custom-hooks
  mkdir sub
  (cd sub; gt claim hook install >/dev/null)
  [[ -x .custom-hooks/pre-commit ]] || fail 'installer did not honor core.hooksPath from a subdirectory'
  gt claim acquire first.txt --run-id "$mine" >/dev/null
  printf 'initial commit\n' > first.txt
  git add first.txt
  status=0
  git commit -m blocked >"$ROOT/custom.out" 2>&1 || status=$?
  [[ "$status" != 0 ]] || fail 'initial commit bypassed the hook'
  assert_contains "$(cat "$ROOT/custom.out")" 'BLOCKED'
  GT_CLAIM_RUN_ID="$mine" git commit -m 'initial holder commit' >/dev/null
)

init_repo "$ROOT/main"
(
  cd "$ROOT/main"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  printf 'shared\n' > shared.txt
  git add shared.txt
  git commit -m baseline >/dev/null
  git worktree add "$ROOT/linked" -b linked >/dev/null
  gt claim acquire shared.txt --run-id "$mine" >/dev/null
)
(
  cd "$ROOT/linked"
  gt claim hook install >/dev/null
  [[ -x "$ROOT/main/.git/hooks/pre-commit" ]] || fail 'linked worktree did not use common hooks directory'
  printf 'linked edit\n' >> shared.txt
  git add shared.txt
  status=0
  git commit -m blocked >"$ROOT/linked.out" 2>&1 || status=$?
  [[ "$status" != 0 ]] || fail 'linked worktree did not observe shared claims'
  assert_contains "$(cat "$ROOT/linked.out")" '"shared.txt"'
  GT_CLAIM_RUN_ID="$mine" git commit -m 'shared holder' >/dev/null
)

# Missing tooling must refuse with a remedy instead of silently skipping checks.
mkdir "$ROOT/empty-bin"
status=0
PATH="$ROOT/empty-bin" /bin/sh "$ROOT/main/.git/hooks/pre-commit" >"$ROOT/missing-gt.out" 2>&1 || status=$?
assert_equal "$status" 1 'missing gt must fail closed'
assert_contains "$(cat "$ROOT/missing-gt.out")" 'install gt or restore PATH'
assert_contains "$(cat "$ROOT/missing-gt.out")" 'git commit --no-verify'
