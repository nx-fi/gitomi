#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim pre-commit checks staged paths, renames, partial commits, and hostile filenames"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
mine=018f0000-0000-7000-8000-000000000011
mkdir "$ROOT/bin"
ln -s "$GT_BIN" "$ROOT/bin/gt"
export PATH="$ROOT/bin:$PATH"
expect_exit() {
  local expected="$1" status=0
  shift
  "$@" >"$ROOT/result" 2>&1 || status=$?
  assert_equal "$status" "$expected" "unexpected result: $*"
}

printf 'original\n' > owned.txt
printf 'quiet\n' > quiet.txt
printf 'rename\n' > old.txt
git add .
git commit -m baseline >/dev/null
gt claim acquire owned.txt --run-id "$mine" --reason 'editing owned file' >/dev/null
gt claim hook install >"$ROOT/install"
[[ -x .git/hooks/pre-commit ]] || fail 'installed hook must be executable'
assert_contains "$(cat "$ROOT/install")" 'git commit --no-verify'
printf 'unstaged work\n' >> owned.txt
printf 'unclaimed work\n' >> quiet.txt
git add quiet.txt
expect_exit 0 gt claim check --staged
git commit -m 'unclaimed staged path' >/dev/null

git add owned.txt
head="$(git rev-parse HEAD)"
expect_exit 3 gt claim check --staged
assert_contains "$(cat "$ROOT/result")" '"owned.txt"'
expect_exit 1 git commit -m 'blocked non-participant'
assert_contains "$(cat "$ROOT/result")" '[peer-supplied text]'
assert_contains "$(cat "$ROOT/result")" 'gt peers'
assert_equal "$(git rev-parse HEAD)" "$head" 'hook refusal created a commit'
GT_CLAIM_RUN_ID="$mine" git commit -m 'holder commit' >/dev/null

old_claim="$(gt claim acquire old.txt --run-id "$mine" --json)"
git mv old.txt renamed.txt
expect_exit 3 gt claim check --staged
assert_contains "$(cat "$ROOT/result")" '"old.txt"'
gt claim release "$(json_field "$old_claim" claim_id)" >/dev/null
gt claim acquire renamed.txt --run-id "$mine" >/dev/null
expect_exit 3 gt claim check --staged
assert_contains "$(cat "$ROOT/result")" '"renamed.txt"'
GT_CLAIM_RUN_ID="$mine" git commit -m rename >/dev/null
git rm owned.txt >/dev/null
expect_exit 3 gt claim check --staged
GT_CLAIM_RUN_ID="$mine" git commit -m deletion >/dev/null

hostile=$'odd $(touch executed) \';\nfile.txt'
printf 'data\n' > "$hostile"
gt claim acquire "$hostile" --run-id "$mine" >/dev/null
git add -- "$hostile"
expect_exit 3 gt claim check --staged
[[ ! -e executed ]] || fail 'a filename was executed'
assert_contains "$(cat "$ROOT/result")" 'gt peers    inspect current peers'
GT_CLAIM_RUN_ID="$mine" git commit -m 'unusual filename' >/dev/null

# The hook must inspect every staged path, not just an acquire-sized batch.
mkdir bulk
for n in $(seq -w 0 69); do printf 'bulk\n' > "bulk/$n"; done
gt claim acquire bulk/69 --run-id "$mine" >/dev/null
git add bulk
expect_exit 3 gt claim check --staged
assert_contains "$(cat "$ROOT/result")" '"bulk/69"'
git commit --only -m 'partial commit uses temporary index' -- bulk/00 >/dev/null
(
  cd bulk
  expect_exit 3 gt claim check --staged
  assert_contains "$(cat "$ROOT/result")" '"bulk/69"'
)
expect_exit 1 gt claim check --staged --mode read
expect_exit 1 gt claim check --staged bulk/00
git commit --no-verify -m 'explicit advisory bypass' >/dev/null
expect_exit 0 gt claim check --staged
