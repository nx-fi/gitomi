#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="data commit references are derived"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

derived_refs="$ROOT/derived-refs"
init_repo "$derived_refs"
(
  cd "$derived_refs"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Referenced issue" >/dev/null
  issues_json="$(gt issue list --json)"
  issue_id="$(json_field "$issues_json" id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from issue list"
  gt pr create --title "Referenced pull" --base main --head feature >/dev/null
  pulls_json="$(gt pr list --json)"
  pull_id="$(json_field "$pulls_json" id)"
  [[ -n "$pull_id" ]] || fail "expected pull id from pull list"

  mkdir -p src
  printf 'referenced\n' > src/app.txt
  git add src/app.txt
  git commit -m "Connect #$(object_ref "$issue_id") and #$(object_ref "$pull_id")" >/dev/null
  code_commit="$(git rev-parse HEAD)"
  printf 'typed referenced\n' > src/typed.txt
  git add src/typed.txt
  git commit -m "Connect issue:$(object_ref "$issue_id") and pr:$(object_ref "$pull_id")" >/dev/null
  typed_commit="$(git rev-parse HEAD)"

  issue_show_json="$(gt issue show "#$(object_ref "$issue_id")" --json)"
  assert_contains "$issue_show_json" "$code_commit"
  assert_contains "$issue_show_json" "$typed_commit"
  pull_show_json="$(gt pr view "#$(object_ref "$pull_id")" --json)"
  assert_contains "$pull_show_json" "$code_commit"
  assert_contains "$pull_show_json" "$typed_commit"
  gt fsck >/dev/null
)

