#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="claim exec fences captured tokens and passes literal commands and lease context"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
[[ "$(uname -s)" == Linux && "$(uname -m)" =~ ^(x86_64|aarch64)$ ]] || exit 0
init_repo "$ROOT/repo"
cd "$ROOT/repo"
gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
run=018f0000-0000-7000-8000-000000000041
held="$(gt claim acquire 'src/**' --ttl 2m --run-id "$run" --reason 'peer text: $(touch reason-was-executed)' --json)"
id="$(json_field "$held" claim_id)"
expires="$(json_field "$held" expires_at)"
head="$(git rev-parse refs/gitomi/claims/ledger)"
export CLAIM_REAL_GIT="$(command -v git)"
mkdir -p "$ROOT/bin"
ln -s "$GT_BIN" "$ROOT/bin/gt"
write_bash_script "$ROOT/bin/git" <<'SH'
if [[ "$1" == fetch || "$1" == push ]]; then echo 'fence must not fetch or push' >&2; exit 99; fi
exec "$CLAIM_REAL_GIT" "$@"
SH
export PATH="$ROOT/bin:$PATH"
weird=$'literal * $(touch command-was-interpolated) ; \'\n--run-id'
out="$(GT_CLAIM_ID=wrong GT_CLAIM_LEASE_SEQ=99 GT_CLAIM_EXPIRES_AT=wrong gt claim exec "$id" --lease-seq 1 --expires-at "$expires" --run-id "$run" -- bash -c 'printf "%s\n%s\n%s\n%s\n%s\n" "$GT_CLAIM_RUN_ID" "$GT_CLAIM_ID" "$GT_CLAIM_LEASE_SEQ" "$GT_CLAIM_EXPIRES_AT" "$1"' bash "$weird")"
assert_contains "$out" "$run"; assert_contains "$out" "$id"; assert_contains "$out" "$expires"; assert_contains "$out" "$weird"
assert_equal "$(gt claim exec "$id" --lease-seq 1 --expires-at "$expires" --run-id "$run" -- bash -c 'printf "%s|%s" "$1" "$2"' bash --token literal-test-value)" '--token|literal-test-value' 'public argv scrubbing must not change forwarded arguments'
[[ ! -e reason-was-executed && ! -e command-was-interpolated ]] || fail 'data was interpreted as code'
assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$head" 'exec must not mutate the ledger'
for refusal in sequence run deadline margin missing command_failure; do
  status=0
  options=("$id" --lease-seq 1 --expires-at "$expires" --run-id "$run")
  case "$refusal" in
    sequence) options+=(--lease-seq 2) ;;
    run) options+=(--run-id 018f0000-0000-7000-8000-000000000042) ;;
    deadline) options+=(--expires-at 2099-01-01T00:00:00Z) ;;
    margin) options+=(--abort-margin 1h) ;;
    missing) options=("$id" --expires-at "$expires" --run-id "$run") ;;
  esac
  if [[ "$refusal" == command_failure ]]; then
    gt claim exec "${options[@]}" -- bash -c 'exit 3' >"$ROOT/$refusal.out" 2>&1 || status=$?
  else
    gt claim exec "${options[@]}" -- bash -c 'touch should-not-run' >"$ROOT/$refusal.out" 2>&1 || status=$?
  fi
  expected=4
  [[ "$refusal" != missing && "$refusal" != command_failure ]] || expected=1
  assert_equal "$status" "$expected" "refusal status for $refusal"
  [[ ! -e should-not-run ]] || fail "stale/invalid execution started: $refusal"
  assert_equal "$(git rev-parse refs/gitomi/claims/ledger)" "$head" 'refusal preserves ledger'
done
status=0
gt claim exec "$id" --lease-seq 1 --expires-at "$expires" --run-id "$run" -- "$ROOT/no-such-command" >"$ROOT/missing-command" 2>&1 || status=$?
assert_equal "$status" 1 'missing executable fails with an IO status'
assert_contains "$(cat "$ROOT/missing-command")" 'Check the executable'
# A real commit under supervision propagates --run-id to the conflict hook.
gt claim hook install >/dev/null
gt claim exec "$id" --lease-seq 1 --expires-at "$expires" --run-id "$run" -- bash -c 'mkdir -p src; echo content > src/file; git add src/file; git commit -m "supervised commit"' >/dev/null
assert_equal "$(git log -1 --format=%s)" 'supervised commit' 'supervision must support real signed commits and hooks'
renewed="$(gt claim renew "$id" --run-id "$run" --ttl 3m --json)"
status=0
gt claim exec "$id" --lease-seq 1 --expires-at "$expires" --run-id "$run" -- bash -c 'touch should-not-run' >"$ROOT/renewed" 2>&1 || status=$?
assert_equal "$status" 4 'renewal invalidates captured token'
expires="$(json_field "$renewed" expires_at)"
gt claim exec "$id" --lease-seq 2 --expires-at "$expires" --run-id "$run" -- true
gt claim release "$id" >/dev/null
status=0
gt claim exec "$id" --lease-seq 2 --expires-at "$expires" --run-id "$run" -- bash -c 'touch should-not-run' >"$ROOT/released" 2>&1 || status=$?
assert_equal "$status" 4 'released token cannot start work'
[[ ! -e should-not-run ]] || fail 'stale token started work'
read_claim="$(gt claim acquire 'src/**' --mode read --ttl 2m --json)"
id="$(json_field "$read_claim" claim_id)"
expires="$(json_field "$read_claim" expires_at)"
status=0
gt claim exec "$id" --lease-seq 1 --expires-at "$expires" -- bash -c 'touch should-not-run' >"$ROOT/read-lease" 2>&1 || status=$?
assert_equal "$status" 1 'default write execution requires a write lease'
[[ ! -e should-not-run ]] || fail 'read lease authorized a write command'
assert_equal "$(gt claim exec "$id" --lease-seq 1 --expires-at "$expires" --mode read -- git show HEAD:src/file)" content 'explicit read operation can use a read lease'
