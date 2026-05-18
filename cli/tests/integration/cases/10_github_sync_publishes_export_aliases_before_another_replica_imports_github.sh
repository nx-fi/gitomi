#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="github sync publishes export aliases before another replica imports github"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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
  write_bash_script "$fakebin/gh" <<'SH'
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
    echo '{"number":88,"id":880088}'
    ;;
  *)
    echo "unexpected request: $method $endpoint" >&2
    exit 3
    ;;
esac
SH
  PATH="$fakebin:$PATH" gt github sync --repo acme/export-alias --use-gh --rest --no-comments --no-projects --remote origin >/dev/null
  git --git-dir="$github_export_alias/remote.git" rev-parse --verify refs/gitomi/inbox/import-bot/github >/dev/null
)
(
  cd "$github_export_alias/replica"
  mkdir -p .git/gitomi
  write_gt_config "$REPO_ID" bob desktop 0
  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  write_bash_script "$fakebin/gh" <<'SH'
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
  PATH="$fakebin:$PATH" gt github sync --repo acme/export-alias --use-gh --rest --no-comments --no-projects --import-only --remote origin >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"id":"'"$(cat "$github_export_alias/local_issue_id")"'"'
  assert_contains "$issues" '"legacy_github_issue_number":88'
  events="$(gt events list --json)"
  assert_contains "$events" '"metadata":{"github_issue_number":88,"github_issue_id":880088}'
  import_opened="$(gt events list --json | grep 'issue.opened' | grep 'import-bot' || true)"
  assert_equal "$import_opened" "" "expected GitHub import to reuse the exported local issue instead of opening a duplicate"
  second_sync="$(PATH="$fakebin:$PATH" gt github sync --repo acme/export-alias --use-gh --rest --no-comments --no-projects --remote origin)"
  assert_contains "$second_sync" "exported 0 events via REST"
  gt fsck >/dev/null
)
