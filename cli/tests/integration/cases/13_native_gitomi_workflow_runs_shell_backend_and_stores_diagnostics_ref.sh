#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="native gitomi workflow runs shell backend and stores diagnostics ref"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

native_actions_repo="$ROOT/native-actions"
init_repo "$native_actions_repo"
(
  cd "$native_actions_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  mkdir -p .gitomi/workflows
  cat > .gitomi/workflows/native.yml <<'YAML'
name: Native CI
on:
  push:
  schedule:
    - cron: "* * * * *"
permissions:
  contents: read
source:
  workflow_from: target
  code_from: target
jobs:
  test:
    backend: shell
    env:
      NATIVE_FLAG: yes
    permissions:
      issues: write
    steps:
      - run: echo native-ok > native-output.txt
      - run: test "$NATIVE_FLAG" = yes
      - run: test -f native-output.txt
YAML
  cat > .gitomi/workflows/agent.yml <<'YAML'
name: Agent Review
on: workflow_dispatch
permissions:
  issues: read
jobs:
  review:
    backend: agent
    uses: .gitomi/pipelines/code-review
YAML
  mkdir -p .gitomi/pipelines/code-review
  cat > .gitomi/pipelines/code-review/pipeline.yml <<'YAML'
name: Code Review
tools:
  - comments.write
permissions:
  issues: read
YAML
  git add .gitomi
  git commit -m "Add native workflows" >/dev/null

  workflows="$(gt actions workflows --json)"
  assert_contains "$workflows" '"path":".gitomi/workflows/native.yml"'
  assert_contains "$workflows" '"dialect":"gitomi"'
  assert_contains "$workflows" '"triggers":["push","schedule","workflow.schedule"]'
  assert_contains "$workflows" '"path":".gitomi/workflows/agent.yml"'

  gt actions run --event push >/dev/null
  events="$(gt events list --json)"
  assert_contains "$events" '"event_type":"action.run_requested"'
  assert_contains "$events" '"event_type":"action.run_completed"'
  assert_contains "$events" '"diagnostics_ref":"refs/gitomi/runs/alice-laptop/'
  completed_body="$(git log -1 --format=%B refs/gitomi/inbox/alice/laptop)"
  assert_contains "$completed_body" '"diagnostics_ref":"refs/gitomi/runs/alice-laptop/'
  assert_contains "$completed_body" '"attempt_id":"'
  assert_contains "$completed_body" '"runner_id":"alice-laptop"'
  inbox_log="$(git log --format=%B refs/gitomi/inbox/alice/laptop)"
  assert_contains "$inbox_log" '"workflow_name":"Native CI"'
  assert_contains "$inbox_log" '"workflow_dialect":"gitomi"'
  assert_contains "$inbox_log" '"backend_kind":"shell"'
  assert_contains "$inbox_log" '"source_workflow_from":"target"'
  assert_contains "$inbox_log" '"permission_grant":{"schema":"urn:gitomi:workflow-permission-grant:v1"'
  assert_file ".git/gitomi/runner/id"
  assert_contains "$(cat .git/gitomi/runner/id)" "alice-laptop"

  run_ref="$(git for-each-ref --format='%(refname)' refs/gitomi/runs | head -n 1)"
  [[ -n "$run_ref" ]] || fail "expected native workflow run ref"
  run_json="$(git show "$run_ref:run.json")"
  assert_contains "$run_json" '"schema":"urn:gitomi:workflow-run:v1"'
  assert_contains "$run_json" '"workflow":".gitomi/workflows/native.yml"'
  assert_contains "$run_json" '"dialect":"gitomi"'
  assert_contains "$run_json" '"conclusion":"success"'
  run_files="$(git ls-tree -r --name-only "$run_ref")"
  assert_contains "$run_files" "/manifest.json"
  assert_contains "$run_files" "/outputs/final.json"

  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  write_bash_script "$fakebin/agent-runner" <<'SH'
set -euo pipefail
printf '%s\n' "$*" > "${AGENT_ARGS_LOG:?}"
event_path=""
pipeline=""
worktree=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)
      shift
      event_path="${1:-}"
      ;;
    --pipeline)
      shift
      pipeline="${1:-}"
      ;;
    --worktree)
      shift
      worktree="${1:-}"
      ;;
  esac
  shift || true
done
[[ -f "$event_path" ]] || exit 2
[[ -f "$worktree/$pipeline/pipeline.yml" ]] || exit 3
SH
  AGENT_ARGS_LOG="$PWD/agent-args.log" gt actions run --event workflow.manual --agent-runner "$fakebin/agent-runner" >/dev/null
  agent_args="$(cat agent-args.log)"
  assert_contains "$agent_args" "--pipeline .gitomi/pipelines/code-review"
  assert_contains "$agent_args" "--event "
  inbox_log="$(git log --format=%B refs/gitomi/inbox/alice/laptop)"
  assert_contains "$inbox_log" '"workflow_name":"Agent Review"'
  assert_contains "$inbox_log" '"backend_kind":"agent"'
  assert_contains "$inbox_log" '"pipeline":".gitomi/pipelines/code-review"'
  agent_run_ref=""
  for ref in $(git for-each-ref --format='%(refname)' refs/gitomi/runs); do
    if git ls-tree -r --name-only "$ref" | grep -q 'pipelines/review-manifest.json'; then
      agent_run_ref="$ref"
      break
    fi
  done
  [[ -n "$agent_run_ref" ]] || fail "expected agent workflow run ref with pipeline manifest"
  pipeline_manifest="$(git show "$agent_run_ref:$(git ls-tree -r --name-only "$agent_run_ref" | grep 'pipelines/review-manifest.json' | head -n 1)")"
  assert_contains "$pipeline_manifest" '"schema":"urn:gitomi:pipeline-manifest:v1"'
  assert_contains "$pipeline_manifest" '"name":"Code Review"'
  assert_contains "$pipeline_manifest" '"tools":["comments.write"]'
  gt fsck >/dev/null
)
