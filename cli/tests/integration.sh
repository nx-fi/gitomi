#!/usr/bin/env bash
set -euo pipefail

GT_BIN="${1:?usage: integration.sh /path/to/gt}"
GT_BIN="$(cd "$(dirname "$GT_BIN")" && pwd)/$(basename "$GT_BIN")"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitomi-cli-it.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO_ID="018f0000-0000-7000-8000-000000000001"
KEY="$ROOT/signing_key"
BOB_KEY="$ROOT/bob_signing_key"
ALLOWED_SIGNERS="$ROOT/allowed_signers"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"$'\n'"output was:"$'\n'"$haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"$'\n'"output was:"$'\n'"$haystack"
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

assert_line_count() {
  local text="$1"
  local expected="$2"
  local count
  count="$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "$expected" ]] || fail "expected $expected non-empty line(s), got $count"$'\n'"$text"
}

assert_line_order() {
  local text="$1"
  shift
  local previous=0
  local needle line
  for needle in "$@"; do
    line="$(printf '%s\n' "$text" | grep -nF "$needle" | head -n 1 | cut -d: -f1 || true)"
    [[ -n "$line" ]] || fail "expected output to contain ordered item: $needle"$'\n'"output was:"$'\n'"$text"
    (( line > previous )) || fail "expected '$needle' to appear after previous ordered item"$'\n'"output was:"$'\n'"$text"
    previous="$line"
  done
}

assert_equal() {
  local left="$1"
  local right="$2"
  local message="$3"
  [[ "$left" == "$right" ]] || fail "$message"$'\n'"left:"$'\n'"$left"$'\n'"right:"$'\n'"$right"
}

json_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "$json" | sed -n 's/.*"'"$field"'":"\([^"]*\)".*/\1/p' | head -n 1
}

object_ref() {
  printf '%s' "$1" | sha256sum | awk '{ print substr($1, 1, 7) }'
}

write_gt_config() {
  local repo_id="$1"
  local principal="$2"
  local device="$3"
  local seq="$4"
  cat > .git/gitomi/config.toml <<EOF
repo_id = "$repo_id"
principal = "$principal"
device = "$device"
seq = $seq
EOF
}

configure_signing() {
  local repo="$1"
  git -C "$repo" config user.name "Alice"
  git -C "$repo" config user.email "alice@example.com"
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config user.signingkey "$KEY"
  git -C "$repo" config gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
}

configure_bob_signing() {
  local repo="$1"
  git -C "$repo" config user.name "Bob"
  git -C "$repo" config user.email "bob@example.com"
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config user.signingkey "$BOB_KEY"
  git -C "$repo" config gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init >/dev/null
  configure_signing "$repo"
}

gt() {
  "$GT_BIN" "$@"
}

ssh-keygen -q -t ed25519 -N "" -C "alice@example.com" -f "$KEY"
ssh-keygen -q -t ed25519 -N "" -C "bob@example.com" -f "$BOB_KEY"
BOB_PUBLIC_KEY="$(awk '{ print $1 " " $2 }' "$BOB_KEY.pub")"
BOB_FINGERPRINT="$(ssh-keygen -lf "$BOB_KEY.pub" -E sha256 | awk '{ print $2 }')"
{
  awk '{ print "alice@example.com " $1 " " $2 }' "$KEY.pub"
  awk '{ print "bob@example.com " $1 " " $2 }' "$BOB_KEY.pub"
} > "$ALLOWED_SIGNERS"

echo "integration: init, issue open, events list --json"
single="$ROOT/single"
init_repo "$single"
(
  cd "$single"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "First issue" --body "Body text" --label bug --assignee alice >/dev/null
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 1
  assert_contains "$json" '"event_type":"issue.opened"'
  assert_contains "$json" '"object_kind":"issue"'
  assert_contains "$json" '"actor_principal":"alice"'
  assert_contains "$json" '"actor_device":"laptop"'
  assert_contains "$json" '"seq":1'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"open"'
  assert_contains "$issues" '"title":"First issue"'
  assert_contains "$issues" '"labels":["bug"]'
  assert_contains "$issues" '"assignees":["alice"]'
  issue_id="$(json_field "$issues" id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from issue list"
  issue_show="$(gt issue show "#$(object_ref "$issue_id")")"
  assert_contains "$issue_show" "id:        $issue_id"
  assert_contains "$issue_show" "labels:    bug"
  assert_contains "$issue_show" "assignees: alice"
  assert_contains "$issue_show" "Body text"
  issue_show_json="$(gt issue show "#$(object_ref "$issue_id")" --json)"
  assert_line_count "$issue_show_json" 1
  assert_contains "$issue_show_json" '"id":"'"$issue_id"'"'
  assert_contains "$issue_show_json" '"body":"Body text"'
  gt fsck >/dev/null
)

echo "integration: issue open requires gt init"
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

echo "integration: user A syncs an issue that user B can pull"
user_sync="$ROOT/user-sync"
mkdir -p "$user_sync"
git -C "$user_sync" init --bare remote.git >/dev/null
init_repo "$user_sync/a"
init_repo "$user_sync/b"
configure_bob_signing "$user_sync/b"
git -C "$user_sync/a" remote add origin "$user_sync/remote.git"
git -C "$user_sync/b" remote add origin "$user_sync/remote.git"
(
  cd "$user_sync/a"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "A synced issue" --body "A body" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$user_sync/b"
  gt sync --pull-only >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"title":"A synced issue"'
  assert_contains "$issues" '"body":"A body"'
  gt fsck >/dev/null
)

echo "integration: issue reducer applies signed updates"
reducer="$ROOT/reducer"
init_repo "$reducer"
(
  cd "$reducer"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Original title" --body "Old body" --label bug --assignee alice >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#$(object_ref "$issue_id")"
  sleep 1
  gt issue title "$issue_ref" --title "Updated title" >/dev/null
  updated_body=$'Updated body first paragraph\n\nUpdated body second paragraph'
  gt issue body "$issue_ref" --body "$updated_body" >/dev/null
  body_update_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  body_update_subject="$(git show -s --format=%s "$body_update_commit")"
  assert_contains "$body_update_subject" "issue.body_set #"
  body_update_event_body="$(git show -s --format=%b "$body_update_commit")"
  [[ "$body_update_event_body" == \{* ]] || fail "expected multiline issue body update commit body to start with JSON"$'\n'"$body_update_event_body"
  assert_contains "$body_update_event_body" '"event_type":"issue.body_set"'
  assert_contains "$body_update_event_body" '"body":"Updated body first paragraph\n\nUpdated body second paragraph"'
  gt issue close "$issue_ref" >/dev/null
  gt issue label "$issue_ref" remove bug >/dev/null
  gt issue assignee "$issue_ref" remove alice >/dev/null
  gt issue label "$issue_ref" add regression >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"closed"'
  assert_contains "$issues" '"title":"Updated title"'
  assert_contains "$issues" '"body":"Updated body first paragraph\n\nUpdated body second paragraph"'
  assert_contains "$issues" '"labels":["regression"]'
  assert_contains "$issues" '"assignees":[]'
  gt fsck >/dev/null
)

echo "integration: project boards and milestones are signed and projected"
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

echo "integration: github import preserves legacy numbers and export replays API calls"
github_io="$ROOT/github-io"
init_repo "$github_io"
(
  cd "$github_io"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  cat > github-fixture.json <<'JSON'
{
  "issues": [
    {
      "number": 42,
      "title": "Legacy bug",
      "body": "Imported issue body mentioning #42",
      "state": "closed",
      "created_at": "2026-01-01T00:00:00Z",
      "closed_at": "2026-01-02T00:00:00Z",
      "user": { "login": "octocat" },
      "tags": ["triage"],
      "milestone": { "title": "v1.0" },
      "labels": [{ "name": "bug" }],
      "assignees": [{ "login": "alice" }]
    }
  ],
  "pulls": [
    {
      "number": 7,
      "title": "Legacy PR",
      "body": "Imported pull body",
      "state": "closed",
      "created_at": "2026-01-03T00:00:00Z",
      "merged_at": "2026-01-04T00:00:00Z",
      "merge_commit_sha": "0123456789abcdef0123456789abcdef01234567",
      "user": { "login": "ichewm" },
      "labels": [{ "name": "docs" }],
      "assignees": [{ "login": "bob" }],
      "requested_reviewers": [{ "login": "Okenx" }],
      "base": { "ref": "main" },
      "head": { "ref": "feature" },
      "draft": false,
      "commits": 1,
      "changed_files": 4,
      "additions": 40,
      "deletions": 4
    }
  ],
  "comments": {
    "issue:42": [
      { "id": 100, "body": "Imported issue comment mentioning #42", "created_at": "2026-01-02T01:00:00Z", "user": { "login": "commenter" } },
      { "id": 101, "body": "Imported issue reply", "created_at": "2026-01-02T01:30:00Z", "user": { "login": "reviewer" }, "in_reply_to_id": 100 }
    ],
    "pull:7": [{ "body": "Imported pull comment", "created_at": "2026-01-04T01:00:00Z" }]
  },
  "projects": {
    "issue:42": [{ "project": "Roadmap", "column": "Done" }]
  }
}
JSON
  gt github import --from-file github-fixture.json >/dev/null
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Legacy bug"'
  assert_contains "$issues" '"source_author":"octocat"'
  assert_contains "$issues" '"milestone":"v1.0"'
  assert_contains "$issues" '"labels":["bug","triage"]'
  assert_contains "$issues" '"projects":[{"project":"Roadmap","column":"Done"}]'
  assert_contains "$issues" '"legacy_github_issue_number":42'
  issue_show="$(gt issue show '#42')"
  assert_contains "$issue_show" "github:    #42"
  assert_contains "$issue_show" "source:    octocat"
  assert_contains "$issue_show" "milestone: v1.0"
  assert_contains "$issue_show" "projects:  Roadmap / Done"
  comments="$(gt comment list issue '#42' --json)"
  assert_contains "$comments" '"source_author":"commenter"'
  assert_contains "$comments" '"source_author":"reviewer"'
  assert_contains "$comments" '"reply_parent_id":'
  assert_contains "$comments" '"reply_parent_hash":'
  pulls="$(gt pr list --json)"
  assert_contains "$pulls" '"title":"Legacy PR"'
  assert_contains "$pulls" '"source_author":"ichewm"'
  assert_contains "$pulls" '"labels":["docs"]'
  assert_contains "$pulls" '"assignees":["bob"]'
  assert_contains "$pulls" '"reviewers":["Okenx"]'
  assert_contains "$pulls" '"commit_count":1'
  assert_contains "$pulls" '"changed_files":4'
  assert_contains "$pulls" '"additions":40'
  assert_contains "$pulls" '"deletions":4'
  assert_contains "$pulls" '"legacy_github_pull_number":7'
  events="$(gt events list --json)"
  assert_contains "$events" '"event_type":"acl.delegation_granted"'
  assert_contains "$events" '"actor_principal":"alice"'
  assert_contains "$events" '"actor_principal":"import-bot"'
  assert_contains "$events" '"event_type":"comment.added"'
  mkdir -p src
  printf 'legacy refs\n' > src/legacy.txt
  git add src/legacy.txt
  git commit -m "Connect #42 and #7" >/dev/null
  code_commit="$(git rev-parse HEAD)"
  issue_show_json="$(gt issue show '#42' --json)"
  assert_contains "$issue_show_json" '"commit_references":["'"$code_commit"'"]'
  pull_show_json="$(gt pr view '#7' --json)"
  assert_contains "$pull_show_json" '"source_author":"ichewm"'
  assert_contains "$pull_show_json" '"reviewers":["Okenx"]'
  assert_contains "$pull_show_json" '"commit_count":1'
  assert_contains "$pull_show_json" '"changed_files":4'
  assert_contains "$pull_show_json" '"additions":40'
  assert_contains "$pull_show_json" '"deletions":4'
  assert_contains "$pull_show_json" '"commit_references":["'"$code_commit"'"]'
  replay="$(gt github export --repo acme/project --dry-run --reuse-legacy --rest)"
  assert_contains "$replay" "PATCH /repos/acme/project/issues/42"
  assert_contains "$replay" "PUT /repos/acme/project/pulls/7/merge"
  assert_contains "$replay" "POST /repos/acme/project/issues/42/comments"
  assert_contains "$replay" "POST /repos/acme/project/issues/7/comments"
  gt fsck >/dev/null
)

echo "integration: sync admits github import bootstrap sequences"
github_sync="$ROOT/github-sync"
mkdir -p "$github_sync"
git -C "$github_sync" init --bare remote.git >/dev/null
init_repo "$github_sync/replica"
git -C "$github_io" remote add import-sync "$github_sync/remote.git"
git -C "$github_sync/replica" remote add origin "$github_sync/remote.git"
(
  cd "$github_io"
  gt sync --remote import-sync --push-only >/dev/null
  write_gt_config "$REPO_ID" import-bot github 0
  gt sync --remote import-sync --push-only >/dev/null
)
(
  cd "$github_sync/replica"
  gt sync --pull-only >/dev/null
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Legacy bug"'
  pulls="$(gt pr list --json)"
  assert_contains "$pulls" '"title":"Legacy PR"'
  events="$(gt events list --json)"
  delegation_line="$(printf '%s\n' "$events" | grep 'acl.delegation_granted')"
  assert_contains "$delegation_line" '"actor_principal":"alice"'
  assert_contains "$delegation_line" '"domain_status":"accepted"'
  import_line="$(printf '%s\n' "$events" | grep 'issue.opened' | grep 'import-bot')"
  assert_contains "$import_line" '"domain_status":"accepted"'
  gt fsck >/dev/null
)

echo "integration: github sync publishes delegated import bot inbox"
github_bridge="$ROOT/github-bridge"
mkdir -p "$github_bridge"
git -C "$github_bridge" init --bare remote.git >/dev/null
init_repo "$github_bridge/source"
init_repo "$github_bridge/replica"
git -C "$github_bridge/source" remote add origin "$github_bridge/remote.git"
git -C "$github_bridge/replica" remote add origin "$github_bridge/remote.git"
(
  cd "$github_bridge/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "api" ]] || {
  echo "expected gh api" >&2
  exit 2
}

endpoint="${@: -1}"
case "$endpoint" in
  'repos/acme/bridge/issues?state=all&per_page=100&page=1')
    cat <<'JSON'
[
  {
    "number": 77,
    "title": "Bridge synced issue",
    "body": "Imported through gt github sync",
    "state": "open",
    "created_at": "2026-01-07T00:00:00Z",
    "comments": 0,
    "labels": [{ "name": "sync" }],
    "assignees": []
  }
]
JSON
    ;;
  'repos/acme/bridge/pulls?state=all&per_page=100&page=1')
    echo '[]'
    ;;
  *)
    echo "unexpected endpoint: $endpoint" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  PATH="$fakebin:$PATH" gt github sync --repo acme/bridge --use-gh --rest --no-comments --no-projects --import-only --remote origin >/dev/null
  git --git-dir="$github_bridge/remote.git" rev-parse --verify refs/gitomi/inbox/import-bot/github >/dev/null
)
(
  cd "$github_bridge/replica"
  gt sync --pull-only >/dev/null
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Bridge synced issue"'
  assert_contains "$issues" '"legacy_github_issue_number":77'
  events="$(gt events list --json)"
  assert_contains "$events" '"actor_principal":"import-bot"'
  gt fsck >/dev/null
)

echo "integration: github sync publishes export aliases before another replica imports github"
github_export_alias="$ROOT/github-export-alias"
mkdir -p "$github_export_alias"
git -C "$github_export_alias" init --bare remote.git >/dev/null
init_repo "$github_export_alias/source"
init_repo "$github_export_alias/replica"
configure_bob_signing "$github_export_alias/replica"
git -C "$github_export_alias/source" remote add origin "$github_export_alias/remote.git"
git -C "$github_export_alias/replica" remote add origin "$github_export_alias/remote.git"
(
  cd "$github_export_alias/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" >/dev/null
  gt acl grant bob maintainer >/dev/null
  gt issue open --title "Local exported issue" --body "Created locally first" >/dev/null
  local_issue_id="$(json_field "$(gt issue list --json)" id)"
  [[ -n "$local_issue_id" ]] || fail "expected local exported issue id"
  printf '%s\n' "$local_issue_id" > "$github_export_alias/local_issue_id"
  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "api" ]] || {
  echo "expected gh api" >&2
  exit 2
}

method=""
endpoint=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --method)
      method="$2"
      shift 2
      ;;
    --input)
      shift 2
      ;;
    -H)
      shift 2
      ;;
    *)
      endpoint="$1"
      shift
      ;;
  esac
done

if [[ "$method" == "POST" ]]; then
  cat >/dev/null
fi

case "$method $endpoint" in
  'GET repos/acme/export-alias/issues?state=all&per_page=100&page=1')
    echo '[]'
    ;;
  'GET repos/acme/export-alias/pulls?state=all&per_page=100&page=1')
    echo '[]'
    ;;
  'POST repos/acme/export-alias/issues')
    echo '{"number":88}'
    ;;
  *)
    echo "unexpected request: $method $endpoint" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  PATH="$fakebin:$PATH" gt github sync --repo acme/export-alias --use-gh --rest --no-comments --no-projects --remote origin >/dev/null
  git --git-dir="$github_export_alias/remote.git" rev-parse --verify refs/gitomi/inbox/import-bot/github >/dev/null
)
(
  cd "$github_export_alias/replica"
  mkdir -p .git/gitomi
  write_gt_config "$REPO_ID" bob desktop 0
  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "api" ]] || {
  echo "expected gh api" >&2
  exit 2
}

method=""
endpoint=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --method)
      method="$2"
      shift 2
      ;;
    --input)
      shift 2
      ;;
    -H)
      shift 2
      ;;
    *)
      endpoint="$1"
      shift
      ;;
  esac
done

case "$method $endpoint" in
  'GET repos/acme/export-alias/issues?state=all&per_page=100&page=1')
    cat <<'JSON'
[
  {
    "number": 88,
    "title": "Local exported issue",
    "body": "Created locally first",
    "state": "open",
    "created_at": "2026-01-08T00:00:00Z",
    "comments": 0,
    "labels": [],
    "assignees": []
  }
]
JSON
    ;;
  'GET repos/acme/export-alias/pulls?state=all&per_page=100&page=1')
    echo '[]'
    ;;
  *)
    echo "unexpected request: $method $endpoint" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  PATH="$fakebin:$PATH" gt github sync --repo acme/export-alias --use-gh --rest --no-comments --no-projects --import-only --remote origin >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"id":"'"$(cat "$github_export_alias/local_issue_id")"'"'
  assert_contains "$issues" '"legacy_github_issue_number":88'
  import_opened="$(gt events list --json | grep 'issue.opened' | grep 'import-bot' || true)"
  assert_equal "$import_opened" "" "expected GitHub import to reuse the exported local issue instead of opening a duplicate"
  replay="$(PATH="$fakebin:$PATH" gt github export --repo acme/export-alias --use-gh --rest)"
  assert_contains "$replay" "github export: replayed 0 events"
  gt fsck >/dev/null
)

echo "integration: github import without options uses local gh current-repo context"
github_gh="$ROOT/github-gh"
init_repo "$github_gh"
(
  cd "$github_gh"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  git remote add origin git@github.com:acme/current.git
  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${GH_CALL_LOG:?}"
[[ "${1:-}" == "api" ]] || {
  echo "expected gh api" >&2
  exit 2
}

endpoint="${@: -1}"
case "$endpoint" in
  'repos/{owner}/{repo}/issues?state=all&per_page=100&page=1')
    cat <<'JSON'
[
  {
    "number": 43,
    "title": "Current repo issue",
    "body": "Imported through gh",
    "state": "open",
    "created_at": "2026-01-05T00:00:00Z",
    "comments": 1,
    "labels": [],
    "assignees": []
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/issues/43/comments?per_page=100&page=1')
    if [[ "${GH_FAIL_COMMENTS:-}" == "1" || "${GH_FAIL_ISSUE_COMMENTS:-}" == "1" ]]; then
      echo "issue comments endpoint failed" >&2
      exit 4
    fi
    cat <<'JSON'
[
  {
    "body": "Current repo comment",
    "created_at": "2026-01-05T01:00:00Z"
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/pulls?state=all&per_page=100&page=1')
    cat <<'JSON'
[
  {
    "number": 44,
    "title": "Current repo pull summary",
    "body": "Summary payload should not be imported",
    "state": "open",
    "created_at": "2026-01-06T00:00:00Z",
    "base": { "ref": "main" },
    "head": { "ref": "feature" },
    "draft": false
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/pulls/44')
    cat <<'JSON'
{
  "number": 44,
  "title": "Current repo pull",
  "body": "Imported pull through gh",
  "state": "closed",
  "created_at": "2026-01-06T00:00:00Z",
  "merged_at": "2026-01-06T02:00:00Z",
  "merge_commit_sha": "abcdef0123456789abcdef0123456789abcdef01",
  "user": { "login": "pull-author" },
  "comments": 1,
  "labels": [{ "name": "api" }],
  "assignees": [{ "login": "api-assignee" }],
  "requested_reviewers": [{ "login": "api-reviewer" }],
  "base": { "ref": "main" },
  "head": { "ref": "feature" },
  "draft": false,
  "commits": 2,
  "changed_files": 3,
  "additions": 12,
  "deletions": 5
}
JSON
    ;;
  'repos/{owner}/{repo}/issues/44/comments?per_page=100&page=1')
    if [[ "${GH_FAIL_COMMENTS:-}" == "1" || "${GH_FAIL_PULL_COMMENTS:-}" == "1" ]]; then
      echo "pull comments endpoint failed" >&2
      exit 4
    fi
    cat <<'JSON'
[
  {
    "body": "Current repo pull comment",
    "created_at": "2026-01-06T01:00:00Z"
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/projects?per_page=100')
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
    ;;
  *)
    echo "unexpected endpoint: $endpoint" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  export GH_CALL_LOG="$PWD/gh-calls.log"
  set +e
  GH_FAIL_ISSUE_COMMENTS=1 PATH="$fakebin:$PATH" gt github import --rest >/tmp/github-import-issue-comment-failure.log 2>&1
  failed_status=$?
  set -e
  [[ "$failed_status" -ne 0 ]] || fail "expected github import to fail when issue comments fail"
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" "Current repo issue"
  pulls="$(gt pr list --json)"
  assert_not_contains "$pulls" "Current repo pull"
  : > "$GH_CALL_LOG"

  set +e
  GH_FAIL_PULL_COMMENTS=1 PATH="$fakebin:$PATH" gt github import --rest >/tmp/github-import-pull-comment-failure.log 2>&1
  failed_status=$?
  set -e
  [[ "$failed_status" -ne 0 ]] || fail "expected github import to fail when pull comments fail"
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Current repo issue"'
  pulls="$(gt pr list --json)"
  assert_not_contains "$pulls" "Current repo pull"
  : > "$GH_CALL_LOG"

  PATH="$fakebin:$PATH" gt github import --rest >/dev/null
  gh_calls="$(cat "$GH_CALL_LOG")"
  assert_contains "$gh_calls" "api --method GET"
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/issues?state=all&per_page=100&page=1'
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/pulls/44'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Current repo issue"'
  assert_contains "$issues" '"legacy_github_issue_number":43'
  pulls="$(gt pr list --json)"
  assert_contains "$pulls" '"title":"Current repo pull"'
  assert_contains "$pulls" '"state":"merged"'
  assert_not_contains "$pulls" "Summary payload should not be imported"
  assert_contains "$pulls" '"source_author":"pull-author"'
  assert_contains "$pulls" '"labels":["api"]'
  assert_contains "$pulls" '"assignees":["api-assignee"]'
  assert_contains "$pulls" '"reviewers":["api-reviewer"]'
  assert_contains "$pulls" '"commit_count":2'
  assert_contains "$pulls" '"changed_files":3'
  assert_contains "$pulls" '"additions":12'
  assert_contains "$pulls" '"deletions":5'
  assert_contains "$pulls" '"legacy_github_pull_number":44'
  events="$(gt events list --json)"
  assert_contains "$events" '"event_type":"comment.added"'
  : > "$GH_CALL_LOG"
  GH_FAIL_COMMENTS=1 PATH="$fakebin:$PATH" gt github import --rest >/dev/null
  gh_calls="$(cat "$GH_CALL_LOG")"
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/issues?state=all&per_page=100&page=1'
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/pulls?state=all&per_page=100&page=1'
  assert_not_contains "$gh_calls" 'repos/{owner}/{repo}/pulls/44'
  assert_not_contains "$gh_calls" 'repos/{owner}/{repo}/issues/43/comments?per_page=100&page=1'
  assert_not_contains "$gh_calls" 'repos/{owner}/{repo}/issues/44/comments?per_page=100&page=1'
  gt fsck >/dev/null
)

echo "integration: actions run invokes act with a GitHub-like event payload"
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
  cat > "$fakebin/act" <<'SH'
#!/usr/bin/env bash
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
  chmod +x "$fakebin/act"

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

echo "integration: native gitomi workflow runs shell backend and stores diagnostics ref"
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
  cat > "$fakebin/agent-runner" <<'SH'
#!/usr/bin/env bash
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
  chmod +x "$fakebin/agent-runner"
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

echo "integration: pull workflows use base workflow source and head code source"
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

echo "integration: index snapshots restore cache, checkpoint by threshold, and prune"
snapshots="$ROOT/snapshots"
init_repo "$snapshots"
(
  cd "$snapshots"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Snapshot base" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#$(object_ref "$issue_id")"

  gt index rebuild >/dev/null
  snapshot_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/snapshots)"
  [[ -n "$snapshot_refs" ]] || fail "expected at least one snapshot ref"
  snapshot_ref="$(git for-each-ref --sort=-committerdate '--format=%(refname)' refs/gitomi/snapshots | head -n 1)"
  manifest="$(git show "$snapshot_ref:manifest.json")"
  assert_contains "$manifest" '"$schema":"urn:gitomi:snapshot:v1"'
  assert_contains "$manifest" '"index_schema_version":"1"'
  assert_contains "$manifest" '"covered_refs"'

  rm -f .git/gitomi/index.sqlite
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"event_type":"issue.opened"'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Snapshot base"'

  for n in $(seq 1 33); do
    gt issue title "$issue_ref" --title "Snapshot title $n" >/dev/null
    gt index rebuild >/dev/null
  done
  snapshot_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/snapshots)"
  assert_line_count "$snapshot_refs" 1

  for n in $(seq 34 64); do
    gt issue title "$issue_ref" --title "Snapshot title $n" >/dev/null
    gt index rebuild >/dev/null
  done
  snapshot_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/snapshots)"
  assert_line_count "$snapshot_refs" 2
  gt index snapshots prune --max-count 1 --max-bytes 0 --max-tree-bytes 0 >/dev/null
  snapshot_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/snapshots)"
  assert_line_count "$snapshot_refs" 1
  gt fsck >/dev/null
)

echo "integration: issue edit batches multiple updates"
issue_edit="$ROOT/issue-edit"
init_repo "$issue_edit"
(
  cd "$issue_edit"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Batch original" --body "Old body" --label bug --assignee alice >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#$(object_ref "$issue_id")"
  sleep 1
  gt issue edit "$issue_ref" --title "Batch title" --body "Batch body" --state closed --unlabel bug --label regression --unassign alice --assignee bob >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"closed"'
  assert_contains "$issues" '"title":"Batch title"'
  assert_contains "$issues" '"body":"Batch body"'
  assert_contains "$issues" '"labels":["regression"]'
  assert_contains "$issues" '"assignees":["bob"]'
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"event_type":"issue.updated"'
  gt fsck >/dev/null
)

echo "integration: issue.updated applies milestone and projects"
issue_updated_metadata="$ROOT/issue-updated-metadata"
init_repo "$issue_updated_metadata"
(
  cd "$issue_updated_metadata"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Metadata batch" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  base_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  update_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000000901","event_type":"issue.updated","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000000902","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:31:00Z","parent_hashes":{"log":"'"$base_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"milestone":"v2.0","projects":[{"project":"Roadmap","column":"Doing"}]}}'
  update_commit="$(git commit-tree -S -m "issue.updated metadata batch" -m "$update_body" "$empty_tree" -p "$base_commit")"
  git update-ref refs/gitomi/inbox/alice/laptop "$update_commit" "$base_commit"
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"milestone":"v2.0"'
  assert_contains "$issues" '"projects":[{"project":"Roadmap","column":"Doing"}]'
  issue_show="$(gt issue show "#$(object_ref "$issue_id")")"
  assert_contains "$issue_show" "milestone: v2.0"
  assert_contains "$issue_show" "projects:  Roadmap / Doing"
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"event_type":"issue.updated"'
  gt fsck >/dev/null
)

echo "integration: comments are signed and projected"
comments="$ROOT/comments"
init_repo "$comments"
(
  cd "$comments"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Commented issue" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#$(object_ref "$issue_id")"
  gt comment add issue "$issue_ref" --body "Initial comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_line_count "$comments_json" 1
  assert_contains "$comments_json" '"body":"Initial comment"'
  assert_contains "$comments_json" '"redacted":false'
  comment_id="$(json_field "$comments_json" id)"
  [[ -n "$comment_id" ]] || fail "expected comment id from comment list"
  comment_ref="comment:$(object_ref "$comment_id")"
  gt issue comment "$issue_ref" --body "Issue alias comment" >/dev/null
  gt issue close "$issue_ref" --body "Closing note" >/dev/null
  issues_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issues_json" '"state":"closed"'
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"body":"Issue alias comment"'
  assert_contains "$comments_json" '"body":"Closing note"'
  gt issue reopen "$issue_ref" --body "Reopening note" >/dev/null
  issues_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issues_json" '"state":"open"'
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"body":"Reopening note"'
  gt issue react "$issue_ref" +1 >/dev/null
  issue_show_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issue_show_json" '"reactions":[{'
  assert_contains "$issue_show_json" '"count":1'
  assert_contains "$issue_show_json" '"actors":["alice"]'
  gt issue unreact "$issue_ref" +1 >/dev/null
  issue_show_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issue_show_json" '"reactions":[]'
  gt comment react "$comment_ref" heart >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"reactions":[{'
  assert_contains "$comments_json" '"actors":["alice"]'
  gt comment unreact "$comment_ref" heart >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"reactions":[]'
  gt comment reply "$comment_ref" --body "Reply comment" >/dev/null
  gt issue comment "$issue_ref" --reply "$comment_ref" --body "Issue alias reply" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_line_count "$comments_json" 6
  assert_contains "$comments_json" '"body":"Reply comment"'
  assert_contains "$comments_json" '"body":"Issue alias reply"'
  assert_contains "$comments_json" '"reply_parent_id":"'"$comment_id"'"'
  assert_contains "$comments_json" '"reply_parent_hash":'
  issue_agent="$(gt issue show "$issue_ref" --view agent)"
  assert_line_count "$issue_agent" 1
  assert_contains "$issue_agent" '"kind":"issue"'
  assert_contains "$issue_agent" '"comments":['
  assert_contains "$issue_agent" '"body":"Issue alias reply"'
  assert_contains "$issue_agent" '"timeline_events":['
  assert_contains "$issue_agent" '"cli_commands":{'
  assert_contains "$issue_agent" '"comment":"gt issue comment #'
  issue_list_agent="$(gt issue list --view agent --state open --limit 5)"
  assert_line_count "$issue_list_agent" 1
  assert_contains "$issue_list_agent" '"kind":"issue_list"'
  assert_contains "$issue_list_agent" '"filters":{"state":"open"'
  assert_contains "$issue_list_agent" '"issues":['
  assert_contains "$issue_list_agent" '"cli_commands":{'
  sleep 1
  gt comment edit "$comment_ref" --body "Edited comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"body":"Edited comment"'
  gt comment redact "$comment_ref" --reason "cleanup" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"redacted":true'
  assert_contains "$comments_json" '"body":""'
  sleep 1
  gt comment edit "$comment_ref" --body "Restored comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"redacted":true'
  assert_contains "$comments_json" '"body":""'
  latest_body_event="$(gt events list --json | grep '"event_type":"comment.body_set"' | tail -n 1)"
  assert_contains "$latest_body_event" '"domain_status":"rejected"'
  assert_contains "$latest_body_event" '"rejection_reason":"object_redacted"'
  gt fsck >/dev/null
)

echo "integration: pulls are signed and projected"
pulls_repo="$ROOT/pulls"
init_repo "$pulls_repo"
(
  cd "$pulls_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt pr create --title "First pull" -B main -H feature --body "Pull body" -d >/dev/null
  pulls_json="$(gt pr list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"open"'
  assert_contains "$pulls_json" '"title":"First pull"'
  assert_contains "$pulls_json" '"body":"Pull body"'
  assert_contains "$pulls_json" '"base_ref":"main"'
  assert_contains "$pulls_json" '"head_ref":"feature"'
  assert_contains "$pulls_json" '"draft":true'
  pull_id="$(json_field "$pulls_json" id)"
  [[ -n "$pull_id" ]] || fail "expected pull id from pull list"
  pull_ref="#$(object_ref "$pull_id")"
  pull_show="$(gt pr view "$pull_ref")"
  assert_contains "$pull_show" "id:         $pull_id"
  assert_contains "$pull_show" "base:       main"
  assert_contains "$pull_show" "head:       feature"
  assert_contains "$pull_show" "draft:      true"
  assert_contains "$pull_show" "Pull body"
  pull_show_json="$(gt pr view "$pull_ref" --json)"
  assert_line_count "$pull_show_json" 1
  assert_contains "$pull_show_json" '"id":"'"$pull_id"'"'
  assert_contains "$pull_show_json" '"base_ref":"main"'
  assert_contains "$pull_show_json" '"head_ref":"feature"'
  gt pr comment "$pull_ref" --body "Pull comment" >/dev/null
  pull_comments="$(gt comment list pr "$pull_ref" --json)"
  assert_line_count "$pull_comments" 1
  assert_contains "$pull_comments" '"body":"Pull comment"'
  pull_comment_id="$(json_field "$pull_comments" id)"
  [[ -n "$pull_comment_id" ]] || fail "expected pull comment id from comment list"
  pull_comment_ref="comment:$(object_ref "$pull_comment_id")"
  gt pr react "$pull_ref" eyes >/dev/null
  pull_show_json="$(gt pr view "$pull_ref" --json)"
  assert_contains "$pull_show_json" '"reactions":[{'
  assert_contains "$pull_show_json" '"actors":["alice"]'
  gt comment react "$pull_comment_ref" +1 >/dev/null
  gt pr comment "$pull_ref" --reply "$pull_comment_ref" --body "Pull reply" >/dev/null
  pull_comments="$(gt comment list pr "$pull_ref" --json)"
  assert_line_count "$pull_comments" 2
  assert_contains "$pull_comments" '"body":"Pull reply"'
  assert_contains "$pull_comments" '"reply_parent_id":"'"$pull_comment_id"'"'
  assert_contains "$pull_comments" '"reactions":[{'
  gt pr comment "$pull_ref" --body "Line note" --file cli/src/pr.zig --side new --line 42 >/dev/null
  gt pr comment "$pull_ref" --body "Range note" --file cli/src/pr.zig --side old --start-line 10 --end-line 12 >/dev/null
  pull_comments="$(gt comment list pr "$pull_ref" --json)"
  assert_line_count "$pull_comments" 4
  assert_contains "$pull_comments" 'Review comment on `cli/src/pr.zig` (new line 42).'
  assert_contains "$pull_comments" 'Review comment on `cli/src/pr.zig` (old lines 10-12).'
  pull_agent="$(gt pr view "$pull_ref" --view agent)"
  assert_line_count "$pull_agent" 1
  assert_contains "$pull_agent" '"kind":"pull_request"'
  assert_contains "$pull_agent" '"comments":['
  assert_contains "$pull_agent" 'Range note'
  assert_contains "$pull_agent" '"timeline_events":['
  assert_contains "$pull_agent" '"cli_commands":{'
  assert_contains "$pull_agent" '"review_line":"gt pr comment #'
  pull_agent_with_diff="$(gt pr view "$pull_ref" --view agent --include-diff)"
  assert_line_count "$pull_agent_with_diff" 1
  assert_contains "$pull_agent_with_diff" '"diff_available":false'
  assert_contains "$pull_agent_with_diff" '"refresh_with_diff":"gt pr view #'
  pull_list_agent="$(gt pr list --view agent --state open --limit 5)"
  assert_line_count "$pull_list_agent" 1
  assert_contains "$pull_list_agent" '"kind":"pull_request_list"'
  assert_contains "$pull_list_agent" '"filters":{"state":"open"'
  assert_contains "$pull_list_agent" '"pull_requests":['
  assert_contains "$pull_list_agent" '"cli_commands":{'
  sleep 1
  gt pr title "$pull_ref" --title "Updated pull" >/dev/null
  gt pr base "$pull_ref" --base trunk >/dev/null
  gt pr label "$pull_ref" add review >/dev/null
  gt pr reviewer "$pull_ref" add alice >/dev/null
  gt pr merge "$pull_ref" --target-oid 0123456789abcdef0123456789abcdef01234567 >/dev/null
  pulls_json="$(gt pr list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"merged"'
  assert_contains "$pulls_json" '"title":"Updated pull"'
  assert_contains "$pulls_json" '"base_ref":"trunk"'
  assert_contains "$pulls_json" '"labels":["review"]'
  assert_contains "$pulls_json" '"reviewers":["alice"]'
  assert_contains "$pulls_json" '"target_oid":"0123456789abcdef0123456789abcdef01234567"'
  gt fsck >/dev/null
)

echo "integration: pull edit batches multiple updates"
pull_edit="$ROOT/pull-edit"
init_repo "$pull_edit"
(
  cd "$pull_edit"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt pr create --title "Batch pull" --base main --head feature --body "Old body" >/dev/null
  pulls_json="$(gt pr list --json)"
  pull_id="$(json_field "$pulls_json" id)"
  [[ -n "$pull_id" ]] || fail "expected pull id from pull list"
  pull_ref="#$(object_ref "$pull_id")"
  sleep 1
  gt pr edit "$pull_ref" -t "Batch pull updated" -b "New body" --state closed -B trunk --head feature-v2 --add-label review --add-assignee bob --add-reviewer alice >/dev/null
  pulls_json="$(gt pr list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"closed"'
  assert_contains "$pulls_json" '"title":"Batch pull updated"'
  assert_contains "$pulls_json" '"body":"New body"'
  assert_contains "$pulls_json" '"base_ref":"trunk"'
  assert_contains "$pulls_json" '"head_ref":"feature-v2"'
  assert_contains "$pulls_json" '"labels":["review"]'
  assert_contains "$pulls_json" '"assignees":["bob"]'
  assert_contains "$pulls_json" '"reviewers":["alice"]'
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"event_type":"pull.updated"'
  gt fsck >/dev/null
)

echo "integration: data commit references are derived"
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

echo "integration: invalid signed event is not projected"
invalid="$ROOT/invalid"
init_repo "$invalid"
(
  cd "$invalid"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000002","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000003"},"idempotency_key":"018f0000-0000-7000-8000-000000000004","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{}}'
  bad_commit="$(git commit-tree -S -m "bad issue" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 0
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  if gt fsck >fsck.out 2>&1; then
    fail "expected fsck to reject invalid signed event"
  fi
  assert_contains "$(cat fsck.out)" "issue.opened payload.title"
)

echo "integration: domain-invalid issue update is audited and not projected"
domain_invalid="$ROOT/domain-invalid"
init_repo "$domain_invalid"
(
  cd "$domain_invalid"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  missing_issue="018f0000-0000-7000-8000-000000000111"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000112","event_type":"issue.title_set","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000111"},"idempotency_key":"018f0000-0000-7000-8000-000000000113","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"No opener"}}'
  bad_commit="$(git commit-tree -S -m "issue.title_set #$(object_ref "$missing_issue")" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"object_not_created"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  gt fsck >/dev/null
)

echo "integration: duplicate opened event is audited and only one object projects"
duplicate_open="$ROOT/duplicate-open"
init_repo "$duplicate_open"
(
  cd "$duplicate_open"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  issue_id="018f0000-0000-7000-8000-000000000211"
  body1='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000212","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000211"},"idempotency_key":"018f0000-0000-7000-8000-000000000213","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"First open"}}'
  first_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") First open" -m "$body1" "$empty_tree" -p "$genesis_head")"
  body2='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000214","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000211"},"idempotency_key":"018f0000-0000-7000-8000-000000000215","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:31:00Z","parent_hashes":{"log":"'"$first_commit"'","anchor":"","causal":[],"related":["'"$first_commit"'"]},"legacy":{},"payload":{"title":"Second open"}}'
  second_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") Second open" -m "$body2" -p "$first_commit" "$empty_tree")"
  git update-ref refs/gitomi/inbox/alice/laptop "$second_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"domain_status":"accepted"'
  assert_contains "$events" '"rejection_reason":"duplicate_object_id"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  gt fsck >/dev/null
)

echo "integration: collection cardinality overflows are audited without projection"
collection_limits="$ROOT/collection-limits"
init_repo "$collection_limits"
(
  cd "$collection_limits"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null

  open_args=(issue open --title "Bounded issue")
  for n in $(seq 1 128); do
    open_args+=(--label "label$n" --assignee "user$n")
  done
  gt "${open_args[@]}" >/dev/null

  issue_json="$(gt issue list --json)"
  issue_id="$(json_field "$issue_json" id)"
  [[ -n "$issue_id" ]] || fail "expected bounded issue id"
  issue_ref="#$(object_ref "$issue_id")"

  add_labels=(issue edit "$issue_ref")
  for n in $(seq 129 256); do
    add_labels+=(--label "label$n")
  done
  gt "${add_labels[@]}" >/dev/null

  gt issue edit "$issue_ref" --title "Overflow issue title" --label label257 --assignee user129 >/dev/null
  events="$(gt events list --json)"
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"collection_limit_exceeded"'
  issue_show="$(gt issue show "$issue_ref")"
  assert_contains "$issue_show" "Bounded issue"
  assert_not_contains "$issue_show" "Overflow issue title"
  assert_not_contains "$issue_show" "label257"
  assert_not_contains "$issue_show" "user129"

  gt pr create --title "Bounded pull" --base main --head feature >/dev/null
  pull_json="$(gt pr list --json)"
  pull_id="$(json_field "$pull_json" id)"
  [[ -n "$pull_id" ]] || fail "expected bounded pull id"
  pull_ref="#$(object_ref "$pull_id")"

  add_reviewers=(pr edit "$pull_ref")
  for n in $(seq 1 128); do
    add_reviewers+=(--add-reviewer "reviewer$n")
  done
  gt "${add_reviewers[@]}" >/dev/null

  gt pr edit "$pull_ref" --title "Overflow pull title" --add-reviewer reviewer129 >/dev/null
  events="$(gt events list --json)"
  assert_contains "$events" '"rejection_reason":"collection_limit_exceeded"'
  pull_show="$(gt pr view "$pull_ref")"
  assert_contains "$pull_show" "Bounded pull"
  assert_not_contains "$pull_show" "Overflow pull title"
  assert_not_contains "$pull_show" "reviewer129"
  gt fsck >/dev/null
)

echo "integration: RBAC projections and write accounting"
rbac_repo="$ROOT/rbac"
init_repo "$rbac_repo"
(
  cd "$rbac_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  genesis_manifest="$(git show refs/gitomi/genesis:.gitomi/genesis.json)"
  assert_contains "$genesis_manifest" '"access":{"mode":"closed"}'
  acl_json="$(gt acl list --json)"
  assert_contains "$acl_json" '"principal":"alice"'
  assert_contains "$acl_json" '"role":"owner"'
  identity_json="$(gt identity list --json)"
  assert_contains "$identity_json" '"principal":"alice"'
  assert_contains "$identity_json" '"device":"laptop"'
  assert_contains "$identity_json" '"active":true'
  if gt acl revoke alice >last-owner.out 2>&1; then
    fail "expected last owner revoke to fail authorization"
  fi
  assert_contains "$(cat last-owner.out)" "last owner"
  gt acl grant bob reader >/dev/null
  gt identity add-device bob desktop >/dev/null
  acl_json="$(gt acl list --json)"
  assert_contains "$acl_json" '"principal":"bob"'
  assert_contains "$acl_json" '"role":"reader"'
  write_gt_config "$REPO_ID" bob desktop 0
  gt issue open --title "Reader cannot open" >/dev/null
  events="$(gt events list --json)"
  reader_line="$(printf '%s\n' "$events" | grep 'Reader cannot open')"
  assert_contains "$reader_line" '"actor_principal":"bob"'
  assert_contains "$reader_line" '"domain_status":"rejected"'
  assert_contains "$reader_line" '"rejection_reason":"insufficient_role"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Reader cannot open"'
)

echo "integration: RBAC pre-flight blocks unauthorized ACL and identity events"
rbac_preflight="$ROOT/rbac-preflight"
init_repo "$rbac_preflight"
(
  cd "$rbac_preflight"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  gt acl grant bob maintainer >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  configure_bob_signing "$PWD"

  if gt acl grant charlie owner >acl-escalate.out 2>&1; then
    fail "expected non-owner ACL grant owner to fail pre-flight"
  fi
  assert_contains "$(cat acl-escalate.out)" "refusing to grant owner; current actor bob has role maintainer"

  if gt acl grant charlie reader >acl-grant.out 2>&1; then
    fail "expected non-owner ACL grant to fail pre-flight"
  fi
  assert_contains "$(cat acl-grant.out)" "owner role required to grant ACL roles"

  if gt acl revoke alice >acl-revoke.out 2>&1; then
    fail "expected non-owner ACL revoke to fail pre-flight"
  fi
  assert_contains "$(cat acl-revoke.out)" "owner role required to revoke ACL roles"

  if gt identity add-device charlie phone >identity-add.out 2>&1; then
    fail "expected non-owner identity add-device to fail pre-flight"
  fi
  assert_contains "$(cat identity-add.out)" "owner role required to add identity devices"

  if gt identity revoke-device alice laptop >identity-revoke.out 2>&1; then
    fail "expected non-owner identity revoke-device to fail pre-flight"
  fi
  assert_contains "$(cat identity-revoke.out)" "owner role required to revoke identity devices"

  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_not_contains "$events" "charlie"
  assert_not_contains "$events" "acl.role_revoked alice"
  assert_not_contains "$events" "identity.device_revoked alice/laptop"
)

echo "integration: open access accepts self-registered signed writers without explicit roles"
open_rbac="$ROOT/open-rbac"
init_repo "$open_rbac"
(
  cd "$open_rbac"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop --access open >/dev/null
  genesis_manifest="$(git show refs/gitomi/genesis:.gitomi/genesis.json)"
  assert_contains "$genesis_manifest" '"access":{"mode":"open"}'
  write_gt_config "$REPO_ID" bob desktop 0
  configure_bob_signing "$PWD"
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  gt issue open --title "Open access Bob issue" >/dev/null
  events="$(gt events list --json)"
  identity_line="$(printf '%s\n' "$events" | grep 'identity.device_added' | grep 'bob')"
  assert_contains "$identity_line" '"domain_status":"accepted"'
  bob_line="$(printf '%s\n' "$events" | grep 'Open access Bob issue')"
  assert_contains "$bob_line" '"actor_principal":"bob"'
  assert_contains "$bob_line" '"domain_status":"accepted"'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Open access Bob issue"'
  gt fsck >/dev/null
)

echo "integration: closed RBAC sync hides unauthorized events until a grant"
closed_rbac="$ROOT/closed-rbac-sync"
mkdir -p "$closed_rbac"
git -C "$closed_rbac" init --bare remote.git >/dev/null
init_repo "$closed_rbac/alice"
init_repo "$closed_rbac/bob"
configure_bob_signing "$closed_rbac/bob"
git -C "$closed_rbac/alice" remote add origin "$closed_rbac/remote.git"
git -C "$closed_rbac/bob" remote add origin "$closed_rbac/remote.git"
(
  cd "$closed_rbac/alice"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop --access closed >/dev/null
  gt issue open --title "Alice visible issue" >/dev/null
  alice_issue_id="$(json_field "$(gt issue list --json)" id)"
  [[ -n "$alice_issue_id" ]] || fail "expected Alice issue id"
  printf '%s\n' "$alice_issue_id" > "$closed_rbac/alice_issue_id"
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/bob"
  gt sync --pull-only >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  gt issue open --title "Bob hidden issue" >/dev/null
  events="$(gt events list --json)"
  bob_line="$(printf '%s\n' "$events" | grep 'Bob hidden issue')"
  assert_contains "$bob_line" '"actor_principal":"bob"'
  assert_contains "$bob_line" '"domain_status":"rejected"'
  assert_contains "$bob_line" '"rejection_reason":"unauthorized_principal"'
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/alice"
  gt sync --pull-only >/dev/null
  events="$(gt events list --json)"
  bob_line="$(printf '%s\n' "$events" | grep 'Bob hidden issue')"
  assert_contains "$bob_line" '"domain_status":"rejected"'
  assert_contains "$bob_line" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Alice visible issue"'
  assert_not_contains "$issues" '"title":"Bob hidden issue"'
  gt acl grant bob reporter >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/bob"
  gt sync --pull-only >/dev/null
  alice_issue_id="$(cat "$closed_rbac/alice_issue_id")"
  alice_issue_ref="#$(object_ref "$alice_issue_id")"
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Alice visible issue"'
  gt comment add issue "$alice_issue_ref" --body "Bob visible comment" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/alice"
  gt sync --pull-only >/dev/null
  alice_issue_id="$(cat "$closed_rbac/alice_issue_id")"
  alice_issue_ref="#$(object_ref "$alice_issue_id")"
  comments="$(gt comment list issue "$alice_issue_ref" --json)"
  assert_contains "$comments" '"body":"Bob visible comment"'
  events="$(gt events list --json)"
  comment_line="$(printf '%s\n' "$events" | grep 'comment.added' | grep 'bob')"
  assert_contains "$comment_line" '"domain_status":"accepted"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Bob hidden issue"'
  gt fsck >/dev/null
)

echo "integration: concurrent RBAC events resolve by hash and remove-wins"
concurrent_rbac="$ROOT/concurrent-rbac"
init_repo "$concurrent_rbac"
(
  cd "$concurrent_rbac"
  gt init --repo-id "$REPO_ID" --principal alice --device anchor >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"

  gt identity add-device alice m >/dev/null
  gt identity add-device alice z >/dev/null
  write_gt_config "$REPO_ID" alice m 0
  gt issue open --title "M anchor" >/dev/null
  m_base="$(git rev-parse refs/gitomi/inbox/alice/m)"
  write_gt_config "$REPO_ID" alice z 0
  gt issue open --title "Z anchor" >/dev/null
  z_base="$(git rev-parse refs/gitomi/inbox/alice/z)"
  write_gt_config "$REPO_ID" alice anchor 2
  gt acl grant bob reader >/dev/null
  anchor_base="$(git rev-parse refs/gitomi/inbox/alice/anchor)"

  acl_grant_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000000501","event_type":"acl.role_granted","object":{"kind":"acl","id":"acl:bob"},"idempotency_key":"018f0000-0000-7000-8000-000000000502","actor":{"principal":"alice","device":"z"},"seq":2,"occurred_at":"2026-05-13T18:31:00Z","parent_hashes":{"log":"'"$z_base"'","anchor":"","causal":["'"$anchor_base"'"],"related":["'"$anchor_base"'"]},"legacy":{},"payload":{"principal":"bob","role":"reporter"}}'
  acl_grant_commit="$(git commit-tree -S -m "acl.role_granted bob reporter" -m "$acl_grant_body" "$empty_tree" -p "$z_base" -p "$anchor_base")"
  acl_revoke_commit=""
  for n in $(seq 1 200); do
    event_uuid="$(printf '018f0000-0000-7000-8000-%012d' $((600 + n)))"
    idem="$(printf '018f0000-0000-7000-8000-%012d' $((800 + n)))"
    acl_revoke_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"'"$event_uuid"'","event_type":"acl.role_revoked","object":{"kind":"acl","id":"acl:bob"},"idempotency_key":"'"$idem"'","actor":{"principal":"alice","device":"m"},"seq":2,"occurred_at":"2026-05-13T18:31:01Z","parent_hashes":{"log":"'"$m_base"'","anchor":"","causal":["'"$anchor_base"'"],"related":["'"$anchor_base"'"]},"legacy":{},"payload":{"principal":"bob","role":"reader"}}'
    acl_revoke_commit="$(git commit-tree -S -m "acl.role_revoked bob reader $n" -m "$acl_revoke_body" "$empty_tree" -p "$m_base" -p "$anchor_base")"
    [[ "$acl_revoke_commit" > "$acl_grant_commit" ]] && break
  done
  [[ "$acl_revoke_commit" > "$acl_grant_commit" ]] || fail "expected to generate ACL revoke hash greater than grant hash"
  git update-ref refs/gitomi/inbox/alice/m "$acl_revoke_commit" "$m_base"
  git update-ref refs/gitomi/inbox/alice/z "$acl_grant_commit" "$z_base"
  acl_json="$(gt acl list --json)"
  assert_not_contains "$acl_json" '"principal":"bob"'

  write_gt_config "$REPO_ID" alice anchor 3
  gt identity add-device alice phone >/dev/null
  phone_base="$(git rev-parse refs/gitomi/inbox/alice/anchor)"
  m_head="$(git rev-parse refs/gitomi/inbox/alice/m)"
  z_head="$(git rev-parse refs/gitomi/inbox/alice/z)"

  phone_revoke_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000001001","event_type":"identity.device_revoked","object":{"kind":"identity","id":"identity:alice:phone"},"idempotency_key":"018f0000-0000-7000-8000-000000001002","actor":{"principal":"alice","device":"m"},"seq":3,"occurred_at":"2026-05-13T18:32:00Z","parent_hashes":{"log":"'"$m_head"'","anchor":"","causal":["'"$phone_base"'"],"related":["'"$phone_base"'"]},"legacy":{},"payload":{"principal":"alice","device":"phone"}}'
  phone_revoke_commit="$(git commit-tree -S -m "identity.device_revoked alice/phone" -m "$phone_revoke_body" "$empty_tree" -p "$m_head" -p "$phone_base")"
  phone_add_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000001003","event_type":"identity.device_added","object":{"kind":"identity","id":"identity:alice:phone"},"idempotency_key":"018f0000-0000-7000-8000-000000001004","actor":{"principal":"alice","device":"z"},"seq":3,"occurred_at":"2026-05-13T18:32:01Z","parent_hashes":{"log":"'"$z_head"'","anchor":"","causal":["'"$phone_base"'"],"related":["'"$phone_base"'"]},"legacy":{},"payload":{"principal":"alice","device":"phone","signing_key":{"scheme":"ssh","public_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIrotate","fingerprint":"phone-rotate"}}}'
  phone_add_commit="$(git commit-tree -S -m "identity.device_added alice/phone" -m "$phone_add_body" "$empty_tree" -p "$z_head" -p "$phone_base")"
  git update-ref refs/gitomi/inbox/alice/m "$phone_revoke_commit" "$m_head"
  git update-ref refs/gitomi/inbox/alice/z "$phone_add_commit" "$z_head"
  identity_json="$(gt identity list --json)"
  assert_contains "$identity_json" '"device":"phone"'
  assert_contains "$identity_json" '"active":false'
  gt fsck >/dev/null
)

echo "integration: authorization uses event causal frontier"
frontier_auth="$ROOT/frontier-auth"
init_repo "$frontier_auth"
(
  cd "$frontier_auth"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  gt identity add-device alice a >/dev/null
  identity_a_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  gt identity add-device alice b >/dev/null
  identity_b_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"

  anchor_a_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002001","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002101"},"idempotency_key":"018f0000-0000-7000-8000-000000002201","actor":{"principal":"alice","device":"a"},"seq":1,"occurred_at":"2026-05-13T18:33:00Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":["'"$identity_a_commit"'"],"related":["'"$identity_a_commit"'"]},"legacy":{},"payload":{"title":"Frontier anchor A"}}'
  anchor_a_commit="$(git commit-tree -S -m "issue.opened frontier anchor A" -m "$anchor_a_body" "$empty_tree" -p "$genesis_head" -p "$identity_a_commit")"
  grant_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002002","event_type":"acl.role_granted","object":{"kind":"acl","id":"acl:bob"},"idempotency_key":"018f0000-0000-7000-8000-000000002202","actor":{"principal":"alice","device":"a"},"seq":2,"occurred_at":"2026-05-13T18:33:01Z","parent_hashes":{"log":"'"$anchor_a_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"principal":"bob","role":"reporter"}}'
  grant_commit="$(git commit-tree -S -m "acl.role_granted bob reporter frontier" -m "$grant_body" "$empty_tree" -p "$anchor_a_commit")"
  identity_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002003","event_type":"identity.device_added","object":{"kind":"identity","id":"identity:bob:desktop"},"idempotency_key":"018f0000-0000-7000-8000-000000002203","actor":{"principal":"alice","device":"a"},"seq":3,"occurred_at":"2026-05-13T18:33:02Z","parent_hashes":{"log":"'"$grant_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"principal":"bob","device":"desktop","signing_key":{"scheme":"ssh","public_key":"'"$BOB_PUBLIC_KEY"'","fingerprint":"'"$BOB_FINGERPRINT"'"}}}'
  identity_commit="$(git commit-tree -S -m "identity.device_added bob/desktop frontier" -m "$identity_body" "$empty_tree" -p "$grant_commit")"
  bob_issue_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002004","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002102"},"idempotency_key":"018f0000-0000-7000-8000-000000002204","actor":{"principal":"bob","device":"desktop"},"seq":1,"occurred_at":"2026-05-13T18:33:03Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":["'"$identity_commit"'"],"related":["'"$identity_commit"'"]},"legacy":{},"payload":{"title":"Bob concurrent issue"}}'
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  bob_issue_commit="$(git commit-tree -S -m "issue.opened bob concurrent frontier" -m "$bob_issue_body" "$empty_tree" -p "$genesis_head" -p "$identity_commit")"
  git config user.name "Alice"
  git config user.email "alice@example.com"
  git config user.signingkey "$KEY"

  anchor_b_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002005","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002103"},"idempotency_key":"018f0000-0000-7000-8000-000000002205","actor":{"principal":"alice","device":"b"},"seq":1,"occurred_at":"2026-05-13T18:33:04Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":["'"$identity_b_commit"'"],"related":["'"$identity_b_commit"'"]},"legacy":{},"payload":{"title":"Frontier anchor B"}}'
  anchor_b_commit="$(git commit-tree -S -m "issue.opened frontier anchor B" -m "$anchor_b_body" "$empty_tree" -p "$genesis_head" -p "$identity_b_commit")"
  revoke_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002006","event_type":"acl.role_revoked","object":{"kind":"acl","id":"acl:bob"},"idempotency_key":"018f0000-0000-7000-8000-000000002206","actor":{"principal":"alice","device":"b"},"seq":2,"occurred_at":"2026-05-13T18:33:05Z","parent_hashes":{"log":"'"$anchor_b_commit"'","anchor":"","causal":["'"$identity_commit"'"],"related":["'"$identity_commit"'"]},"legacy":{},"payload":{"principal":"bob","role":"reporter"}}'
  revoke_commit="$(git commit-tree -S -m "acl.role_revoked bob reporter frontier" -m "$revoke_body" "$empty_tree" -p "$anchor_b_commit" -p "$identity_commit")"

  git update-ref refs/gitomi/inbox/alice/a "$identity_commit"
  git update-ref refs/gitomi/inbox/alice/b "$revoke_commit"
  git update-ref refs/gitomi/inbox/bob/desktop "$bob_issue_commit"
  events="$(gt events list --json)"
  bob_line="$(printf '%s\n' "$events" | grep '"actor_principal":"bob"')"
  assert_contains "$bob_line" '"domain_status":"accepted"'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Bob concurrent issue"'
  acl_json="$(gt acl list --json)"
  assert_not_contains "$acl_json" '"principal":"bob"'
  gt fsck >/dev/null
)

echo "integration: related auth hashes do not authorize without causal ancestry"
related_frontier="$ROOT/related-frontier"
init_repo "$related_frontier"
(
  cd "$related_frontier"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"

  grant_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002111","event_type":"acl.role_granted","object":{"kind":"acl","id":"acl:charlie"},"idempotency_key":"018f0000-0000-7000-8000-000000002211","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:33:10Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"principal":"charlie","role":"reporter"}}'
  grant_commit="$(git commit-tree -S -m "acl.role_granted charlie reporter" -m "$grant_body" "$empty_tree" -p "$genesis_head")"
  identity_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002112","event_type":"identity.device_added","object":{"kind":"identity","id":"identity:charlie:desktop"},"idempotency_key":"018f0000-0000-7000-8000-000000002212","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:33:11Z","parent_hashes":{"log":"'"$grant_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"principal":"charlie","device":"desktop","signing_key":{"scheme":"ssh","public_key":"'"$BOB_PUBLIC_KEY"'","fingerprint":"'"$BOB_FINGERPRINT"'"}}}'
  identity_commit="$(git commit-tree -S -m "identity.device_added charlie/desktop" -m "$identity_body" "$empty_tree" -p "$grant_commit")"
  charlie_issue_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002113","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002114"},"idempotency_key":"018f0000-0000-7000-8000-000000002213","actor":{"principal":"charlie","device":"desktop"},"seq":1,"occurred_at":"2026-05-13T18:33:12Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":["'"$identity_commit"'"]},"legacy":{},"payload":{"title":"Related only should not authorize"}}'
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  charlie_issue_commit="$(git commit-tree -S -m "issue.opened related-only auth" -m "$charlie_issue_body" "$empty_tree" -p "$genesis_head")"

  git update-ref refs/gitomi/inbox/alice/laptop "$identity_commit"
  git update-ref refs/gitomi/inbox/charlie/desktop "$charlie_issue_commit"
  events="$(gt events list --json)"
  charlie_line="$(printf '%s\n' "$events" | grep '"actor_principal":"charlie"')"
  assert_contains "$charlie_line" '"domain_status":"rejected"'
  assert_contains "$charlie_line" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Related only should not authorize"'
  gt fsck >/dev/null
)

echo "integration: signing key must match actor device"
signature_binding="$ROOT/signature-binding"
init_repo "$signature_binding"
(
  cd "$signature_binding"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  issue_id="018f0000-0000-7000-8000-000000002301"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002302","event_type":"issue.opened","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002303","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:00Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Wrong signer"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") Wrong signer" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"signing_key_mismatch"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  if gt fsck >fsck-binding.out 2>&1; then
    fail "expected fsck to reject wrong signer for actor device"
  fi
  assert_contains "$(cat fsck-binding.out)" "signing_key_mismatch"
)

echo "integration: sync quarantines signer and actor device binding mismatches"
sync_binding="$ROOT/sync-binding"
mkdir -p "$sync_binding"
git -C "$sync_binding" init --bare remote.git >/dev/null
init_repo "$sync_binding/source"
init_repo "$sync_binding/replica"
git -C "$sync_binding/source" remote add origin "$sync_binding/remote.git"
git -C "$sync_binding/replica" remote add origin "$sync_binding/remote.git"
(
  cd "$sync_binding/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002402","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002401"},"idempotency_key":"018f0000-0000-7000-8000-000000002403","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:10Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Wrong signer from remote"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened wrong remote signer" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_binding/replica"
  gt sync --pull-only >sync-binding.out 2>&1
  assert_contains "$(cat sync-binding.out)" "signing_key_mismatch"
  assert_contains "$(cat sync-binding.out)" "quarantined"
  if git show-ref --verify --quiet refs/gitomi/inbox/alice/laptop; then
    fail "expected signer mismatch inbox ref to stay out of authoritative refs"
  fi
)

echo "integration: sync quarantines inactive actor devices"
sync_device_binding="$ROOT/sync-device-binding"
mkdir -p "$sync_device_binding"
git -C "$sync_device_binding" init --bare remote.git >/dev/null
init_repo "$sync_device_binding/source"
init_repo "$sync_device_binding/replica"
git -C "$sync_device_binding/source" remote add origin "$sync_device_binding/remote.git"
git -C "$sync_device_binding/replica" remote add origin "$sync_device_binding/remote.git"
(
  cd "$sync_device_binding/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002412","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002411"},"idempotency_key":"018f0000-0000-7000-8000-000000002413","actor":{"principal":"alice","device":"phone"},"seq":1,"occurred_at":"2026-05-13T18:34:20Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Inactive device from remote"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened inactive remote device" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/phone "$bad_commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/phone:refs/gitomi/inbox/alice/phone >/dev/null
)
(
  cd "$sync_device_binding/replica"
  gt sync --pull-only >sync-device-binding.out 2>&1
  assert_contains "$(cat sync-device-binding.out)" "unauthorized_device"
  assert_contains "$(cat sync-device-binding.out)" "quarantined"
  if git show-ref --verify --quiet refs/gitomi/inbox/alice/phone; then
    fail "expected inactive actor device inbox ref to stay out of authoritative refs"
  fi
)

echo "integration: sync admits valid prefix before quarantining duplicate actor sequence"
sync_duplicate_prefix="$ROOT/sync-duplicate-prefix"
mkdir -p "$sync_duplicate_prefix"
git -C "$sync_duplicate_prefix" init --bare remote.git >/dev/null
init_repo "$sync_duplicate_prefix/source"
init_repo "$sync_duplicate_prefix/replica"
git -C "$sync_duplicate_prefix/source" remote add origin "$sync_duplicate_prefix/remote.git"
git -C "$sync_duplicate_prefix/replica" remote add origin "$sync_duplicate_prefix/remote.git"
(
  cd "$sync_duplicate_prefix/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  body1='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002501","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002500"},"idempotency_key":"018f0000-0000-7000-8000-000000002502","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:30Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Valid prefix"}}'
  first_commit="$(git commit-tree -S -m "issue.opened valid prefix" -m "$body1" "$empty_tree" -p "$genesis_head")"
  body2='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002503","event_type":"issue.updated","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002500"},"idempotency_key":"018f0000-0000-7000-8000-000000002504","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:31Z","parent_hashes":{"log":"'"$first_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"Duplicate seq"}}'
  bad_commit="$(git commit-tree -S -m "issue.updated duplicate seq" -m "$body2" "$empty_tree" -p "$first_commit")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  printf '%s\n' "$first_commit" > "$sync_duplicate_prefix/first-prefix-commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_duplicate_prefix/replica"
  gt sync --pull-only >sync-duplicate-prefix.out 2>&1
  output="$(cat sync-duplicate-prefix.out)"
  assert_contains "$output" "seq 1 is not strictly greater than previous sequence 1"
  assert_contains "$output" "quarantined"
  assert_contains "$output" "created refs/gitomi/inbox/alice/laptop with first 1 valid event"
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$(cat "$sync_duplicate_prefix/first-prefix-commit")" "expected local inbox to stop at the valid prefix"
  quarantine_refs="$(git for-each-ref --format='%(refname)' refs/gitomi/quarantine)"
  assert_contains "$quarantine_refs" "refs/gitomi/quarantine/origin/inbox/alice/laptop"
  gt fsck >/dev/null
)

echo "integration: sync fast-forwards valid prefix before quarantining duplicate actor sequence"
sync_ff_duplicate="$ROOT/sync-ff-duplicate"
mkdir -p "$sync_ff_duplicate"
git -C "$sync_ff_duplicate" init --bare remote.git >/dev/null
init_repo "$sync_ff_duplicate/source"
init_repo "$sync_ff_duplicate/replica"
git -C "$sync_ff_duplicate/source" remote add origin "$sync_ff_duplicate/remote.git"
git -C "$sync_ff_duplicate/replica" remote add origin "$sync_ff_duplicate/remote.git"
(
  cd "$sync_ff_duplicate/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  issue_id="018f0000-0000-7000-8000-000000002510"
  body1='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002511","event_type":"issue.opened","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002512","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:34:32Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Fast-forward prefix"}}'
  first_commit="$(git commit-tree -S -m "issue.opened fast-forward prefix" -m "$body1" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/alice/laptop "$first_commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_ff_duplicate/replica"
  gt sync --pull-only >/dev/null
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$(git -C "$sync_ff_duplicate/source" rev-parse refs/gitomi/inbox/alice/laptop)" "expected initial pull to admit first event"
)
(
  cd "$sync_ff_duplicate/source"
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  issue_id="018f0000-0000-7000-8000-000000002510"
  first_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  body2='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002513","event_type":"issue.updated","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002514","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:34:33Z","parent_hashes":{"log":"'"$first_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"Fast-forward valid prefix"}}'
  second_commit="$(git commit-tree -S -m "issue.updated fast-forward valid prefix" -m "$body2" "$empty_tree" -p "$first_commit")"
  body3='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002515","event_type":"issue.updated","object":{"kind":"issue","id":"'"$issue_id"'"},"idempotency_key":"018f0000-0000-7000-8000-000000002516","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:34:34Z","parent_hashes":{"log":"'"$second_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"Fast-forward duplicate seq"}}'
  bad_commit="$(git commit-tree -S -m "issue.updated fast-forward duplicate seq" -m "$body3" "$empty_tree" -p "$second_commit")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  printf '%s\n' "$second_commit" > "$sync_ff_duplicate/second-prefix-commit"
  git push origin refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop >/dev/null
)
(
  cd "$sync_ff_duplicate/replica"
  gt sync --pull-only >sync-ff-duplicate.out 2>&1
  output="$(cat sync-ff-duplicate.out)"
  assert_contains "$output" "seq 2 is not strictly greater than previous sequence 2"
  assert_contains "$output" "quarantined"
  assert_contains "$output" "fast-forwarded refs/gitomi/inbox/alice/laptop by first 1 valid event"
  assert_equal "$(git rev-parse refs/gitomi/inbox/alice/laptop)" "$(cat "$sync_ff_duplicate/second-prefix-commit")" "expected fast-forward pull to stop at the valid prefix"
  gt fsck >/dev/null
)

echo "integration: sync admits authorization chains before dependent issue chains"
sync_auth_order="$ROOT/sync-auth-order"
mkdir -p "$sync_auth_order"
git -C "$sync_auth_order" init --bare remote.git >/dev/null
init_repo "$sync_auth_order/source"
init_repo "$sync_auth_order/replica"
git -C "$sync_auth_order/source" remote add origin "$sync_auth_order/remote.git"
git -C "$sync_auth_order/replica" remote add origin "$sync_auth_order/remote.git"
(
  cd "$sync_auth_order/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device alice zzz >/dev/null
  alice_zzz_identity="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  grant_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002601","event_type":"acl.role_granted","object":{"kind":"acl","id":"acl:aaron"},"idempotency_key":"018f0000-0000-7000-8000-000000002602","actor":{"principal":"alice","device":"zzz"},"seq":1,"occurred_at":"2026-05-13T18:34:40Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":["'"$alice_zzz_identity"'"],"related":["'"$alice_zzz_identity"'"]},"legacy":{},"payload":{"principal":"aaron","role":"reporter"}}'
  grant_commit="$(git commit-tree -S -m "acl.role_granted aaron reporter order" -m "$grant_body" "$empty_tree" -p "$genesis_head" -p "$alice_zzz_identity")"
  identity_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002603","event_type":"identity.device_added","object":{"kind":"identity","id":"identity:aaron:desktop"},"idempotency_key":"018f0000-0000-7000-8000-000000002604","actor":{"principal":"alice","device":"zzz"},"seq":2,"occurred_at":"2026-05-13T18:34:41Z","parent_hashes":{"log":"'"$grant_commit"'","anchor":"","causal":[],"related":[]},"legacy":{},"payload":{"principal":"aaron","device":"desktop","signing_key":{"scheme":"ssh","public_key":"'"$BOB_PUBLIC_KEY"'","fingerprint":"'"$BOB_FINGERPRINT"'"}}}'
  identity_commit="$(git commit-tree -S -m "identity.device_added aaron/desktop order" -m "$identity_body" "$empty_tree" -p "$grant_commit")"
  git update-ref refs/gitomi/inbox/alice/zzz "$identity_commit"
  issue_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000002605","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002606"},"idempotency_key":"018f0000-0000-7000-8000-000000002607","actor":{"principal":"aaron","device":"desktop"},"seq":1,"occurred_at":"2026-05-13T18:34:42Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":["'"$identity_commit"'"],"related":["'"$identity_commit"'"]},"legacy":{},"payload":{"title":"Aaron order-independent issue"}}'
  git config user.name "Bob"
  git config user.email "bob@example.com"
  git config user.signingkey "$BOB_KEY"
  issue_commit="$(git commit-tree -S -m "issue.opened aaron order-independent" -m "$issue_body" "$empty_tree" -p "$genesis_head" -p "$identity_commit")"
  git update-ref refs/gitomi/inbox/aaron/desktop "$issue_commit"
  git push origin refs/gitomi/genesis:refs/gitomi/genesis refs/gitomi/inbox/alice/laptop:refs/gitomi/inbox/alice/laptop refs/gitomi/inbox/alice/zzz:refs/gitomi/inbox/alice/zzz refs/gitomi/inbox/aaron/desktop:refs/gitomi/inbox/aaron/desktop >/dev/null
)
(
  cd "$sync_auth_order/replica"
  gt sync --pull-only >sync-auth-order.out 2>&1
  output="$(cat sync-auth-order.out)"
  assert_not_contains "$output" "quarantined"
  events="$(gt events list --json)"
  aaron_line="$(printf '%s\n' "$events" | grep '"actor_principal":"aaron"')"
  assert_contains "$aaron_line" '"domain_status":"accepted"'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Aaron order-independent issue"'
  gt fsck >/dev/null
)

echo "integration: unauthorized remote event is audited and not projected"
unauthorized="$ROOT/unauthorized"
init_repo "$unauthorized"
(
  cd "$unauthorized"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  genesis_head="$(git rev-parse refs/gitomi/genesis)"
  issue_id="018f0000-0000-7000-8000-000000000311"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000312","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000311"},"idempotency_key":"018f0000-0000-7000-8000-000000000313","actor":{"principal":"mallory","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":[],"related":[]},"legacy":{},"payload":{"title":"Unauthorized"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened #$(object_ref "$issue_id") Unauthorized" -m "$bad_body" "$empty_tree" -p "$genesis_head")"
  git update-ref refs/gitomi/inbox/mallory/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  gt fsck >/dev/null
)

echo "integration: stale config seq is recovered before writing"
seq_recovery="$ROOT/seq-recovery"
init_repo "$seq_recovery"
(
  cd "$seq_recovery"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Seq base" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id"
  write_gt_config "$REPO_ID" alice laptop 0
  gt issue title "#$(object_ref "$issue_id")" --title "Recovered seq" >/dev/null
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"seq":2'
  gt fsck >/dev/null
)

echo "integration: missing inbox ref resets stale config seq before writing"
seq_missing="$ROOT/seq-missing"
init_repo "$seq_missing"
(
  cd "$seq_missing"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  write_gt_config "$REPO_ID" alice laptop 99
  gt issue open --title "Missing inbox seq reset" >/dev/null
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"seq":1'
  gt fsck >/dev/null
)

echo "integration: bare-remote sync"
sync_root="$ROOT/sync"
mkdir -p "$sync_root"
git -C "$sync_root" init --bare remote.git >/dev/null
init_repo "$sync_root/a"
init_repo "$sync_root/b"
git -C "$sync_root/a" remote add origin "$sync_root/remote.git"
git -C "$sync_root/b" remote add origin "$sync_root/remote.git"
(
  cd "$sync_root/a"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Synced issue" >/dev/null
  gt sync >/dev/null
)
remote_refs="$(git --git-dir="$sync_root/remote.git" for-each-ref '--format=%(refname)' refs/gitomi)"
assert_contains "$remote_refs" "refs/gitomi/inbox/alice/laptop"
assert_not_contains "$remote_refs" "refs/gitomi/staging"
(
  cd "$sync_root/b"
  gt sync --pull-only >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/staging/origin/inbox/alice/laptop"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 1
  assert_contains "$json" '"actor_device":"laptop"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"title":"Synced issue"'
  gt fsck >/dev/null
)

echo "integration: two users sync interleaved issue events and converge with LWW edits"
interleaved="$ROOT/interleaved-users"
mkdir -p "$interleaved"
git -C "$interleaved" init --bare remote.git >/dev/null
init_repo "$interleaved/a"
init_repo "$interleaved/b"
configure_bob_signing "$interleaved/b"
git -C "$interleaved/a" remote add origin "$interleaved/remote.git"
git -C "$interleaved/b" remote add origin "$interleaved/remote.git"
(
  cd "$interleaved/a"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" >/dev/null
  gt acl grant bob maintainer >/dev/null
  gt issue open --title "Shared interleaved issue" --body "Initial shared body" >/dev/null
  shared_issue_id="$(json_field "$(gt issue list --json)" id)"
  [[ -n "$shared_issue_id" ]] || fail "expected shared issue id"
  printf '%s\n' "$shared_issue_id" > "$interleaved/shared_issue_id"
  gt sync --push-only >/dev/null
)
(
  cd "$interleaved/b"
  gt sync >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Shared interleaved issue"'
)
(
  cd "$interleaved/a"
  gt sync >/dev/null
)

(
  cd "$interleaved/a"
  gt issue open --title "Alice interleaved 1" >/dev/null
)
sleep 1
(
  cd "$interleaved/b"
  gt issue open --title "Bob interleaved 1" >/dev/null
)
sleep 1
(
  cd "$interleaved/a"
  gt issue open --title "Alice interleaved 2" >/dev/null
)
sleep 1
(
  cd "$interleaved/b"
  gt issue open --title "Bob interleaved 2" >/dev/null
)

(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/b"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 5
  assert_line_order "$issues" \
    '"title":"Bob interleaved 2"' \
    '"title":"Alice interleaved 2"' \
    '"title":"Bob interleaved 1"' \
    '"title":"Alice interleaved 1"' \
    '"title":"Shared interleaved issue"'
)
(
  cd "$interleaved/b"
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 5
  assert_line_order "$issues" \
    '"title":"Bob interleaved 2"' \
    '"title":"Alice interleaved 2"' \
    '"title":"Bob interleaved 1"' \
    '"title":"Alice interleaved 1"' \
    '"title":"Shared interleaved issue"'
)

shared_issue_id="$(cat "$interleaved/shared_issue_id")"
shared_issue_ref="#$(object_ref "$shared_issue_id")"
(
  cd "$interleaved/a"
  gt comment add issue "$shared_issue_ref" --body "Alice local comment" >/dev/null
)
sleep 1
(
  cd "$interleaved/b"
  gt comment add issue "$shared_issue_ref" --body "Bob local comment" >/dev/null
)
sleep 1
(
  cd "$interleaved/a"
  gt issue body "$shared_issue_ref" --body "Alice local edit" >/dev/null
  git rev-parse refs/gitomi/inbox/alice/laptop > "$interleaved/alice_edit_hash"
)
sleep 1
(
  cd "$interleaved/b"
  gt issue body "$shared_issue_ref" --body "Bob local edit" >/dev/null
  git rev-parse refs/gitomi/inbox/bob/desktop > "$interleaved/bob_edit_hash"
)
alice_edit_hash="$(cat "$interleaved/alice_edit_hash")"
bob_edit_hash="$(cat "$interleaved/bob_edit_hash")"
if [[ "$alice_edit_hash" > "$bob_edit_hash" ]]; then
  expected_body="Alice local edit"
else
  expected_body="Bob local edit"
fi

(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/b"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  issue_show="$(gt issue show "$shared_issue_ref" --json)"
  comments="$(gt comment list issue "$shared_issue_ref" --json)"
  assert_contains "$issue_show" '"body":"'"$expected_body"'"'
  assert_line_count "$comments" 2
  assert_contains "$comments" '"body":"Alice local comment"'
  assert_contains "$comments" '"body":"Bob local comment"'
  printf '%s\n' "$issue_show" > "$interleaved/a_issue.json"
  printf '%s\n' "$comments" > "$interleaved/a_comments.json"
  gt fsck >/dev/null
)
(
  cd "$interleaved/b"
  issue_show="$(gt issue show "$shared_issue_ref" --json)"
  comments="$(gt comment list issue "$shared_issue_ref" --json)"
  assert_contains "$issue_show" '"body":"'"$expected_body"'"'
  assert_line_count "$comments" 2
  assert_contains "$comments" '"body":"Alice local comment"'
  assert_contains "$comments" '"body":"Bob local comment"'
  assert_equal "$(cat "$interleaved/a_issue.json")" "$issue_show" "expected user A and user B issue projections to match"
  assert_equal "$(cat "$interleaved/a_comments.json")" "$comments" "expected user A and user B comment projections to match"
  gt fsck >/dev/null
)

echo "integration: default push publishes only configured actor inbox ref"
scope_root="$ROOT/sync-push-scope"
mkdir -p "$scope_root"
git -C "$scope_root" init --bare upstream.git >/dev/null
git -C "$scope_root" init --bare backup.git >/dev/null
init_repo "$scope_root/source"
init_repo "$scope_root/replica"
git -C "$scope_root/source" remote add origin "$scope_root/upstream.git"
git -C "$scope_root/replica" remote add origin "$scope_root/upstream.git"
git -C "$scope_root/replica" remote add backup "$scope_root/backup.git"
(
  cd "$scope_root/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Alice upstream issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$scope_root/replica"
  gt sync --pull-only >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  configure_bob_signing "$scope_root/replica"
  gt issue open --title "Bob local issue" >/dev/null
  gt sync --remote backup --push-only >/dev/null
)
backup_refs="$(git --git-dir="$scope_root/backup.git" for-each-ref '--format=%(refname)' refs/gitomi)"
assert_contains "$backup_refs" "refs/gitomi/genesis"
assert_contains "$backup_refs" "refs/gitomi/inbox/bob/desktop"
assert_not_contains "$backup_refs" "refs/gitomi/inbox/alice/laptop"
assert_not_contains "$backup_refs" "refs/gitomi/staging"
assert_not_contains "$backup_refs" "refs/gitomi/quarantine"
assert_not_contains "$backup_refs" "refs/gitomi/snapshots"
assert_not_contains "$backup_refs" "refs/gitomi/runs"

echo "integration: local clear requires confirmation"
clear_local="$ROOT/clear-local"
init_repo "$clear_local"
(
  cd "$clear_local"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Local clear issue" >/dev/null
  if printf 'no\n' | gt clear local >/dev/null 2>&1; then
    fail "expected local clear to abort on mismatched confirmation"
  fi
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/genesis"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  printf 'delete local gitomi refs\n' | gt clear local >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "no Gitomi refs"
  assert_file ".git/gitomi/config.toml"
)

echo "integration: local reset removes refs and config"
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

echo "integration: remote reset requires confirmation"
clear_remote="$ROOT/clear-remote"
mkdir -p "$clear_remote"
git -C "$clear_remote" init --bare remote.git >/dev/null
init_repo "$clear_remote/source"
git -C "$clear_remote/source" remote add origin "$clear_remote/remote.git"
(
  cd "$clear_remote/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Remote clear issue" >/dev/null
  gt sync --push-only >/dev/null
  if printf 'no\n' | gt reset remote --remote origin >/dev/null 2>&1; then
    fail "expected remote reset to abort on mismatched confirmation"
  fi
)
remote_refs="$(git --git-dir="$clear_remote/remote.git" for-each-ref '--format=%(refname)' refs/gitomi)"
assert_contains "$remote_refs" "refs/gitomi/genesis"
assert_contains "$remote_refs" "refs/gitomi/inbox/alice/laptop"
(
  cd "$clear_remote/source"
  printf 'delete remote gitomi refs from origin\n' | gt reset remote --remote origin >/dev/null
)
remote_refs="$(git --git-dir="$clear_remote/remote.git" for-each-ref '--format=%(refname)' refs/gitomi)"
[[ -z "$remote_refs" ]] || fail "expected remote Gitomi refs to be deleted"$'\n'"$remote_refs"

echo "integration: sync prunes stale staging after remote clear"
stale_root="$ROOT/stale-staging"
mkdir -p "$stale_root"
git -C "$stale_root" init --bare remote.git >/dev/null
init_repo "$stale_root/source"
init_repo "$stale_root/replica"
git -C "$stale_root/source" remote add origin "$stale_root/remote.git"
git -C "$stale_root/replica" remote add origin "$stale_root/remote.git"
(
  cd "$stale_root/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Stale staging issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$stale_root/replica"
  gt init --repo-id "$REPO_ID" --principal bob --device desktop >/dev/null
  if first_pull="$(gt sync --pull-only 2>&1)"; then
    fail "expected sync to reject conflicting genesis"
  fi
  assert_contains "$first_pull" "conflicting refs/gitomi/genesis"
  assert_contains "$first_pull" "refusing to admit inbox refs"
  staged_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/staging/origin)"
  assert_contains "$staged_refs" "refs/gitomi/staging/origin/genesis"
  refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/inbox)"
  [[ -z "$refs" ]] || fail "expected conflicting pull not to admit inbox refs"$'\n'"$refs"
  gt clear remote --yes >/dev/null
  second_pull="$(gt sync --pull-only 2>&1)"
  assert_contains "$second_pull" "no remote Gitomi genesis ref at origin"
  assert_contains "$second_pull" "no staged Gitomi inbox refs to admit"
  assert_not_contains "$second_pull" "conflicting refs/gitomi/genesis"
  staged_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/staging/origin)"
  [[ -z "$staged_refs" ]] || fail "expected stale staging refs to be pruned"$'\n'"$staged_refs"
)

echo "integration: causal parents are capped"
cap_repo="$ROOT/causal-cap"
init_repo "$cap_repo"
(
  cd "$cap_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Laptop root" >/dev/null
  for n in $(seq 1 40); do
    gt identity add-device alice "device$n" >/dev/null
  done
  for n in $(seq 1 40); do
    write_gt_config "$REPO_ID" alice "device$n" 0
    gt issue open --title "Device $n root" >/dev/null
    write_gt_config "$REPO_ID" alice laptop 0
  done
  write_gt_config "$REPO_ID" alice laptop 1
  first_event="$(gt events list --json --ref refs/gitomi/inbox/alice/laptop)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected laptop issue id"
  gt issue title "$issue_id" --title "Laptop capped update" >/dev/null
  laptop_head="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  parents="$(git show -s --format=%P "$laptop_head")"
  parent_count="$(printf '%s\n' "$parents" | awk '{ print NF }')"
  [[ "$parent_count" == "33" ]] || fail "expected 33 parents (1 log + 32 causal), got $parent_count: $parents"
  gt fsck >/dev/null
)

echo "integration: run refs prune by retention count"
runs_repo="$ROOT/runs"
init_repo "$runs_repo"
(
  cd "$runs_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  run1="$(git commit-tree -S -m "run one" "$empty_tree")"
  git update-ref refs/gitomi/runs/local/run1 "$run1"
  sleep 1
  run2="$(git commit-tree -S -m "run two" "$empty_tree")"
  git update-ref refs/gitomi/runs/local/run2 "$run2"
  gt runs prune --max-count 1 --max-age-days 0 --max-bytes 0 >/dev/null
  run_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/runs)"
  assert_line_count "$run_refs" 1
  assert_contains "$run_refs" "refs/gitomi/runs/local/run2"
)

echo "integration: two-device divergence"
div_root="$ROOT/divergence"
mkdir -p "$div_root"
git -C "$div_root" init --bare remote.git >/dev/null
init_repo "$div_root/laptop"
init_repo "$div_root/desktop"
git -C "$div_root/laptop" remote add origin "$div_root/remote.git"
git -C "$div_root/desktop" remote add origin "$div_root/remote.git"
(
  cd "$div_root/laptop"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device alice desktop >/dev/null
  gt issue open --title "Laptop issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$div_root/desktop"
  gt sync --pull-only >/dev/null
  write_gt_config "$REPO_ID" alice desktop 0
  gt issue open --title "Desktop issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$div_root/laptop"
  gt sync --pull-only >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  assert_contains "$refs" "refs/gitomi/inbox/alice/desktop"
  json="$(gt events list --json)"
  assert_line_count "$json" 3
  assert_contains "$json" '"actor_device":"laptop"'
  assert_contains "$json" '"actor_device":"desktop"'
  gt fsck >/dev/null
)

echo "integration: ok"
