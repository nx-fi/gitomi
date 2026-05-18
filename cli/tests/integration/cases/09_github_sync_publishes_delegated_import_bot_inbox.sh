#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="github sync publishes delegated import bot inbox"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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
  write_bash_script "$fakebin/gh" <<'SH'
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
