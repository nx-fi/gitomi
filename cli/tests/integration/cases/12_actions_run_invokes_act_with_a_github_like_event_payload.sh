#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="actions run invokes act with a GitHub-like event payload"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

actions_repo="$ROOT/actions"
init_repo "$actions_repo"
(
  cd "$actions_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  mkdir -p .github/workflows
  cat > .github/workflows/ci.yml <<'YAML'
name: CI
on:
  issues:
  workflow_dispatch:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
  git add .github/workflows/ci.yml
  git commit -m "Add CI workflow" >/dev/null
  code_commit="$(git rev-parse HEAD)"

  workflows="$(gt actions workflows --json)"
  assert_contains "$workflows" '"path":".github/workflows/ci.yml"'
  assert_contains "$workflows" '"name":"CI"'
  assert_contains "$workflows" '"triggers":["issues","workflow_dispatch"]'

  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  write_bash_script "$fakebin/act" <<'SH'
set -euo pipefail

printf '%s\n' "$PWD" > "${ACT_CWD_LOG:?}"
printf '%s\n' "$*" > "${ACT_ARGS_LOG:?}"
printf '%s\n' "${1:-}" > "${ACT_EVENT_NAME_LOG:?}"

event_path=""
workflow_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--eventpath)
      shift
      event_path="${1:-}"
      ;;
    -W|--workflows)
      shift
      workflow_path="${1:-}"
      ;;
  esac
  shift || true
done

[[ -n "$event_path" ]] || {
  echo "missing event path" >&2
  exit 2
}
[[ -f "$workflow_path" ]] || {
  echo "missing workflow path: $workflow_path" >&2
  exit 3
}
cat "$event_path" > "${ACT_EVENT_LOG:?}"
SH

  action_object_id="018f0000-0000-7000-8000-00000000a001"
  ACT_CWD_LOG="$PWD/act-cwd.log" \
    ACT_ARGS_LOG="$PWD/act-args.log" \
    ACT_EVENT_NAME_LOG="$PWD/act-event-name.log" \
    ACT_EVENT_LOG="$PWD/act-event.json" \
    gt actions run --event issue.opened --object-id "$action_object_id" --act "$fakebin/act" -- --container-architecture linux/amd64 >/dev/null

  act_args="$(cat act-args.log)"
  assert_contains "$act_args" "issues -W .github/workflows/ci.yml -e"
  assert_contains "$act_args" "--container-architecture linux/amd64"
  assert_contains "$(cat act-event-name.log)" "issues"
  act_payload="$(cat act-event.json)"
  assert_contains "$act_payload" '"action":"opened"'
  assert_contains "$act_payload" '"event_name":"issues"'
  assert_contains "$act_payload" '"ref":"HEAD"'
  assert_contains "$act_payload" '"after":"'"$code_commit"'"'
  assert_contains "$act_payload" '"repository":{"name":"actions","full_name":"actions"}'
  assert_contains "$act_payload" '"workflow":{"path":".github/workflows/ci.yml","name":"CI"}'
  assert_contains "$act_payload" '"issue":{"id":"'"$action_object_id"'","node_id":"'"$action_object_id"'","number":0}'
  assert_contains "$act_payload" '"gitomi":{"run_id":'
  assert_contains "$act_payload" '"event_type":"issue.opened"'
  assert_contains "$act_payload" '"object_id":"'"$action_object_id"'"'

  events="$(gt events list --json)"
  assert_contains "$events" '"event_type":"action.run_requested"'
  assert_contains "$events" '"event_type":"action.run_completed"'

  gt issue open --title "Daemon scheduled issue" >/dev/null
  ACT_CWD_LOG="$PWD/act-cwd.log" \
    ACT_ARGS_LOG="$PWD/act-args.log" \
    ACT_EVENT_NAME_LOG="$PWD/act-event-name.log" \
    ACT_EVENT_LOG="$PWD/act-event.json" \
    gt actions daemon --once --replay --act "$fakebin/act" >/dev/null
  events="$(gt events list --json)"
  request_count="$(printf '%s\n' "$events" | grep -c '"event_type":"action.run_requested"')"
  [[ "$request_count" -ge 2 ]] || fail "expected daemon to create another action run request"
  assert_file ".git/gitomi/actions-scheduler.state"
  gt fsck >/dev/null
)
