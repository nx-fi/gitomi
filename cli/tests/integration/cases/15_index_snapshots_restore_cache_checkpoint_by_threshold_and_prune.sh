#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="index snapshots restore cache, checkpoint by threshold, and prune"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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

