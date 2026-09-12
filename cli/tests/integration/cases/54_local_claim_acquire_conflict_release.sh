#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="local claims acquire, conflict, readers, release, and signing"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
run_a=018f0000-0000-7000-8000-000000000011
run_b=018f0000-0000-7000-8000-000000000012
expect_exit() {
  local expected="$1" status=0
  shift
  "$@" >"$ROOT/result" 2>&1 || status=$?
  assert_equal "$status" "$expected" "unexpected claim exit: $*"
}
printf 'staged work\n' > work.txt
git add work.txt
index_before="$(sha256sum .git/index)"
acquired="$(gt claim acquire './src//session/' --reason $'session work\n\033[31m\u202e' --run-id "$run_a" --json)"
id="$(json_field "$acquired" claim_id)"
assert_contains "$acquired" '"deployment_mode":"single-store"'
assert_contains "$acquired" '"established":true'
assert_contains "$acquired" '"lease_seq":1'
assert_contains "$acquired" '"paths":["src/session/**"]'
assert_equal "$(git ls-tree -r --name-only refs/gitomi/claims/ledger)" "claims/$id.json" "one JSON blob per claim"
git verify-commit refs/gitomi/claims/ledger >/dev/null 2>&1
assert_equal "$(git rev-list --count refs/gitomi/claims/ledger)" 1 "ledger root must have no genesis/inbox parent"
expect_exit 3 gt claim acquire src/session/token.zig --run-id "$run_b"
assert_contains "$(cat "$ROOT/result")" 'BLOCKED'
assert_contains "$(cat "$ROOT/result")" 'peer-supplied text'
assert_contains "$(cat "$ROOT/result")" 'gt claim ls --all'
assert_not_contains "$(cat "$ROOT/result")" $'\033'
assert_not_contains "$(cat "$ROOT/result")" $'\u202e'
expect_exit 3 gt claim check src/session/token.zig --run-id "$run_b"
expect_exit 3 gt claim acquire src/session/token.zig --run-id "$run_b" --wait 1s
expect_exit 0 gt claim check src/session/token.zig --run-id "$run_b" --advisory-only
expect_exit 0 gt claim check src/session/token.zig --run-id "$run_a"
expect_exit 0 gt claim check docs/readme.md --run-id "$run_b"
expect_exit 1 gt claim acquire '../outside'
expect_exit 1 gt claim acquire file --ttl 29s
expect_exit 1 gt claim acquire file --ttl 5h
expect_exit 1 gt claim release --all "$id"
gt claim release "$id" >/dev/null
assert_equal "$(git ls-tree -r refs/gitomi/claims/ledger)" '' "release leaves an empty tree"
expect_exit 0 gt claim check src/session/token.zig --run-id "$run_b"
gt claim acquire src/shared --mode read --run-id "$run_a" >/dev/null
gt claim acquire src/shared --mode read --run-id "$run_b" >/dev/null
expect_exit 3 gt claim check src/shared
assert_contains "$(gt claim ls)" 'single-store'
gt claim release --run "$run_a" >/dev/null
assert_not_contains "$(gt claim ls --json)" "$run_a"
assert_contains "$(gt claim ls --json)" "$run_b"
gt claim release --all >/dev/null
assert_contains "$(gt claim ls --json)" '"claims":[]'

# Waiting acquisition observes a release without any network operation.
gt claim acquire waiting.txt --run-id "$run_a" >/dev/null
gt claim acquire waiting.txt --run-id "$run_b" --wait 5s >"$ROOT/wait.out" 2>&1 &
waiter=$!
sleep 0.5
kill -0 "$waiter" || fail 'waiter returned while conflict was still held'
gt claim release --run "$run_a" >/dev/null
wait "$waiter"
assert_contains "$(cat "$ROOT/wait.out")" 'established'
gt claim release --all >/dev/null

# A cryptographically valid but unbound signing key must never advance the ref.
before="$(git rev-parse refs/gitomi/claims/ledger)"
configure_bob_signing "$PWD"
expect_exit 1 gt claim acquire other.txt
assert_contains "$(cat "$ROOT/result")" 'UnboundClaimSigner'
assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$before" 'unbound key changed ledger'
configure_signing "$PWD"

# Different verified signers preserve each other's unchanged records.
gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
write_gt_config "$REPO_ID" bob desktop 0
configure_bob_signing "$PWD"
bob_claim="$(gt claim acquire bob.txt --json)"
bob_id="$(json_field "$bob_claim" claim_id)"
write_gt_config "$REPO_ID" alice laptop 0
configure_signing "$PWD"
gt claim acquire alice.txt >/dev/null
assert_contains "$(gt claim ls --json)" "$bob_id"
expect_exit 1 gt claim release "$bob_id"
expect_exit 3 gt claim check bob.txt
before="$(git rev-parse refs/gitomi/claims/ledger)"
git config gitomi.claims.mode federated
expect_exit 1 gt claim acquire other.txt
assert_contains "$(cat "$ROOT/result")" 'federated establishment is not implemented'
assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$before" 'unsupported mode changed ledger'
assert_equal "$(sha256sum .git/index)" "$index_before" 'claim command modified Git index'
assert_equal "$(cat work.txt)" 'staged work' 'claim command modified worktree'
[[ ! -e claims ]] || fail 'ledger was checked out'
