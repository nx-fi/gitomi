#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="pull workflows use base workflow source and head code source"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

pull_actions_repo="$ROOT/pull-actions"
init_repo "$pull_actions_repo"
(
  cd "$pull_actions_repo"
  git branch -M main
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  mkdir -p .gitomi/workflows
  cat > .gitomi/workflows/review.yml <<'YAML'
name: Pull Source Policy
on:
  pull.opened:
jobs:
  review:
    backend: shell
    steps:
      - run: test -f head-only.txt
      - run: echo base-workflow
YAML
  git add .gitomi
  git commit -m "Add base workflow" >/dev/null
  base_oid="$(git rev-parse HEAD)"

  git checkout -b feature >/dev/null
  echo head > head-only.txt
  cat > .gitomi/workflows/review.yml <<'YAML'
name: Pull Source Policy
on:
  pull.opened:
jobs:
  review:
    backend: shell
    steps:
      - run: exit 42
YAML
  git add .gitomi head-only.txt
  git commit -m "Change workflow on head" >/dev/null
  head_oid="$(git rev-parse HEAD)"

  git checkout -b attacker-base main >/dev/null
  cat > .gitomi/workflows/review.yml <<'YAML'
name: Pull Source Policy
on:
  pull.opened:
jobs:
  review:
    backend: shell
    steps:
      - run: exit 42
YAML
  git add .gitomi/workflows/review.yml
  git commit -m "Add attacker base workflow" >/dev/null
  attacker_base_oid="$(git rev-parse HEAD)"

  git checkout main >/dev/null
  gt pr create --title "Source split" -B main -H feature >/dev/null
  pull_json="$(gt pr list --json)"
  pull_id="$(json_field "$pull_json" "id")"
  [[ -n "$pull_id" ]] || fail "expected pull id"

  gt actions run --event pull.opened --object-id "$pull_id" >/dev/null
  inbox_log="$(git log --format=%B refs/gitomi/inbox/alice/laptop)"
  assert_contains "$inbox_log" '"source_workflow_from":"base"'
  assert_contains "$inbox_log" '"source_code_from":"head"'
  assert_contains "$inbox_log" '"workflow_source_oid":"'"$base_oid"'"'
  assert_contains "$inbox_log" '"target_oid":"'"$head_oid"'"'
  assert_contains "$inbox_log" '"conclusion":"success"'

  gt pr base "$pull_id" --base attacker-base >/dev/null
  gt actions run --event pull.opened --object-id "$pull_id" >/dev/null
  inbox_log="$(git log --format=%B refs/gitomi/inbox/alice/laptop)"
  assert_contains "$inbox_log" '"workflow_source_oid":"'"$base_oid"'"'
  assert_not_contains "$inbox_log" '"workflow_source_oid":"'"$attacker_base_oid"'"'
  assert_contains "$inbox_log" '"conclusion":"success"'

  run_ref="$(git for-each-ref --format='%(refname)' refs/gitomi/runs | head -n 1)"
  run_json="$(git show "$run_ref:run.json")"
  assert_contains "$run_json" '"workflow_source_oid":"'"$base_oid"'"'
  assert_contains "$run_json" '"target_oid":"'"$head_oid"'"'
  gt fsck >/dev/null
)

