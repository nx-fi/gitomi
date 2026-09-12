#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim peers are filtered, reduced, and safe to display"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
mine=018f0000-0000-7000-8000-000000000011
peer=018f0000-0000-7000-8000-000000000012
gt claim acquire 'src/**' --run-id "$mine" --reason 'my task' >/dev/null
gt claim acquire 'docs/**' --mode read --run-id "$peer" --reason $'review docs\n\033[31m\u202equoted data' >/dev/null
gt claim acquire 'assets/**' --run-id "$peer" --reason 'update images' >/dev/null
head="$(git rev-parse refs/gitomi/claims/ledger)"
peers="$(gt peers --run-id "$mine")"
assert_line_count "$peers" 3
assert_contains "$peers" 'Peers (single-store)'
assert_contains "$peers" "$peer"
assert_contains "$peers" 'read'
assert_contains "$peers" '"docs/**"'
assert_contains "$peers" '[peer-supplied text]'
assert_not_contains "$peers" 'my task'
assert_not_contains "$peers" $'\033'
assert_not_contains "$peers" $'\u202e'
filtered="$(GT_CLAIM_RUN_ID="$mine" gt peers docs/manual.md)"
assert_line_count "$filtered" 2
assert_not_contains "$filtered" 'update images'
assert_contains "$(gt peers elsewhere --run-id "$mine")" 'No relevant live peer claims'
mkdir src
assert_contains "$(cd src; GT_CLAIM_RUN_ID="$mine" gt peers docs/manual.md)" '"docs/**"'
assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$head" 'peers must not mutate the ledger'

status=0
gt claim check src/auth.zig >"$ROOT/conflict" 2>&1 || status=$?
assert_equal "$status" 3 'peer conflict keeps protocol exit code'
assert_contains "$(cat "$ROOT/conflict")" 'BLOCKED  "src/auth.zig"'
assert_contains "$(cat "$ROOT/conflict")" "gt peers -- 'src/auth.zig'"
assert_contains "$(cat "$ROOT/conflict")" 'See AGENTS.md'
