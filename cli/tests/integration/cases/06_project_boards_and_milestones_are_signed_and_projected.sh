#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="project boards and milestones are signed and projected"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

projects_repo="$ROOT/projects"
init_repo "$projects_repo"
(
  cd "$projects_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt project create --name "Roadmap" --description "Release work" --column "Backlog" --column "Done" >/dev/null
  projects="$(gt project list --json)"
  assert_line_count "$projects" 1
  assert_contains "$projects" '"name":"Roadmap"'
  assert_contains "$projects" '"slug":"roadmap"'
  assert_contains "$projects" '"description":"Release work"'
  assert_contains "$projects" '"columns":["Backlog","Done"]'
  assert_contains "$projects" '"column_refs":[{"name":"Backlog","ref":"backlog"},{"name":"Done","ref":"done"}]'
  gt project edit Roadmap --description "Release planning" >/dev/null
  gt project column Roadmap add "In Review" >/dev/null
  gt project field Roadmap create --key status --name "Status" --type single_select --position 1 --required true --default-json '"Backlog"' >/dev/null
  gt project field-option Roadmap status add --name "Backlog" --color green --position 1 >/dev/null
  gt project field-option Roadmap status add --name "In Review" --color yellow --position 2 >/dev/null
  gt project view Roadmap create --name Board --layout board --position 1 --config-json '{"group_by":"status"}' >/dev/null
  gt project view Roadmap create --name Timeline --layout roadmap --position 2 --config-json '{"date_field":"target"}' >/dev/null
  projects="$(gt project list --json)"
  assert_contains "$projects" '"description":"Release planning"'
  assert_contains "$projects" '"columns":["Backlog","Done","In Review"]'
  assert_contains "$projects" '"column_refs":[{"name":"Backlog","ref":"backlog"},{"name":"Done","ref":"done"},{"name":"In Review","ref":"in-review"}]'
  assert_contains "$projects" '"key":"status"'
  assert_contains "$projects" '"type":"single_select"'
  assert_contains "$projects" '"default_value":"Backlog"'
  assert_contains "$projects" '"options":[{"id":'
  assert_contains "$projects" '"name":"Backlog","color":"green"'
  assert_contains "$projects" '"name":"In Review","color":"yellow"'
  assert_contains "$projects" '"layout":"board"'
  assert_contains "$projects" '"config":{"group_by":"status"}'
  assert_contains "$projects" '"layout":"roadmap"'
  gt milestone create --title "v1.0" --description "First release" --due "2026-06-01" >/dev/null
  milestones="$(gt milestone list --json)"
  assert_line_count "$milestones" 1
  assert_contains "$milestones" '"title":"v1.0"'
  assert_contains "$milestones" '"due_at":"2026-06-01"'
  milestone_id="$(json_field "$milestones" id)"
  [[ -n "$milestone_id" ]] || fail "expected milestone id from milestone list"
  milestone_ref="milestone:${milestone_id:0:7}"
  gt milestone edit "$milestone_ref" --title "v1.1" --description "Second release" --due "2026-07-01" >/dev/null
  gt milestone close "^v1.1" >/dev/null
  milestones="$(gt milestone list --json)"
  assert_contains "$milestones" '"title":"v1.1"'
  assert_contains "$milestones" '"description":"Second release"'
  assert_contains "$milestones" '"due_at":"2026-07-01"'
  assert_contains "$milestones" '"state":"closed"'
  gt milestone reopen "$milestone_ref" >/dev/null
  milestones="$(gt milestone list --json)"
  assert_contains "$milestones" '"state":"open"'
  gt issue open --title "Ship kanban" >/dev/null
  issue_id="$(json_field "$(gt issue list --json)" id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from issue list"
  issue_ref="#$(object_ref "$issue_id")"
  gt project add "Roadmap" "$issue_ref" --column "Backlog" >/dev/null
  gt issue project-field "$issue_ref" set Roadmap status --value "In Review" >/dev/null
  gt issue project-field "$issue_ref" clear Roadmap status >/dev/null
  gt issue milestone "$issue_ref" --milestone "v1.1" >/dev/null
  issue_show="$(gt issue show "$issue_ref")"
  assert_contains "$issue_show" "milestone: v1.1"
  assert_contains "$issue_show" "projects:  Roadmap"
  events="$(gt events list --json)"
  assert_contains "$events" '"event_type":"project.created"'
  assert_contains "$events" '"event_type":"project.updated"'
  assert_contains "$events" '"event_type":"project.column_added"'
  assert_contains "$events" '"event_type":"project.field_created"'
  assert_contains "$events" '"event_type":"project.field_option_added"'
  assert_contains "$events" '"event_type":"project.view_created"'
  assert_contains "$events" '"event_type":"milestone.created"'
  assert_contains "$events" '"event_type":"milestone.updated"'
  assert_contains "$events" '"event_type":"milestone.state_set"'
  assert_contains "$events" '"event_type":"issue.project_added"'
  assert_contains "$events" '"event_type":"issue.project_field_set"'
  assert_contains "$events" '"event_type":"issue.project_field_cleared"'
  assert_contains "$events" '"event_type":"issue.milestone_set"'
  gt fsck >/dev/null
)

