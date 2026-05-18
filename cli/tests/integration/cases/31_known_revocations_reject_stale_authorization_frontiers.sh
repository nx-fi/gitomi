#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="known revocations reject stale authorization frontiers"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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
  revoke_commit=""
  for n in $(seq 1 200); do
    event_uuid="$(printf '018f0000-0000-7000-8000-%012d' $((2006 + n)))"
    idem="$(printf '018f0000-0000-7000-8000-%012d' $((2206 + n)))"
    revoke_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"'"$event_uuid"'","event_type":"acl.role_revoked","object":{"kind":"acl","id":"acl:bob"},"idempotency_key":"'"$idem"'","actor":{"principal":"alice","device":"b"},"seq":2,"occurred_at":"2026-05-13T18:33:05Z","parent_hashes":{"log":"'"$anchor_b_commit"'","anchor":"","causal":["'"$identity_commit"'"],"related":["'"$identity_commit"'"]},"legacy":{},"payload":{"principal":"bob","role":"reporter"}}'
    revoke_commit="$(git commit-tree -S -m "acl.role_revoked bob reporter frontier $n" -m "$revoke_body" "$empty_tree" -p "$anchor_b_commit" -p "$identity_commit")"
    [[ "$bob_issue_commit" > "$revoke_commit" ]] && break
  done
  [[ "$bob_issue_commit" > "$revoke_commit" ]] || fail "expected stale event hash to sort before ACL revoke hash"

  git update-ref refs/gitomi/inbox/alice/a "$identity_commit"
  git update-ref refs/gitomi/inbox/alice/b "$revoke_commit"
  git update-ref refs/gitomi/inbox/bob/desktop "$bob_issue_commit"
  events="$(gt events list --json)"
  bob_line="$(printf '%s\n' "$events" | grep '"actor_principal":"bob"')"
  assert_contains "$bob_line" '"domain_status":"rejected"'
  assert_contains "$bob_line" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Bob concurrent issue"'
  acl_json="$(gt acl list --json)"
  assert_not_contains "$acl_json" '"principal":"bob"'

  gt identity add-device alice phone >/dev/null
  phone_add_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  phone_revoke_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"018f0000-0000-7000-8000-000000004007","event_type":"identity.device_revoked","object":{"kind":"identity","id":"identity:alice:phone"},"idempotency_key":"018f0000-0000-7000-8000-000000004207","actor":{"principal":"alice","device":"b"},"seq":3,"occurred_at":"2026-05-13T18:33:06Z","parent_hashes":{"log":"'"$revoke_commit"'","anchor":"","causal":["'"$phone_add_commit"'"],"related":["'"$phone_add_commit"'"]},"legacy":{},"payload":{"principal":"alice","device":"phone"}}'
  phone_revoke_commit="$(git commit-tree -S -m "identity.device_revoked alice/phone stale frontier" -m "$phone_revoke_body" "$empty_tree" -p "$revoke_commit" -p "$phone_add_commit")"
  phone_issue_commit=""
  for n in $(seq 1 512); do
    event_uuid="$(printf '018f0000-0000-7000-8000-%012d' $((4008 + n)))"
    idem="$(printf '018f0000-0000-7000-8000-%012d' $((4208 + n)))"
    phone_issue_body='{"$schema":"urn:gitomi:event:v1","repo_id":"'"$REPO_ID"'","event_uuid":"'"$event_uuid"'","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000002104"},"idempotency_key":"'"$idem"'","actor":{"principal":"alice","device":"phone"},"seq":1,"occurred_at":"2026-05-13T18:33:07Z","parent_hashes":{"log":"","anchor":"'"$genesis_head"'","causal":["'"$phone_add_commit"'"],"related":["'"$phone_add_commit"'"]},"legacy":{},"payload":{"title":"Phone stale issue"}}'
    phone_issue_commit="$(git commit-tree -S -m "issue.opened phone stale frontier $n" -m "$phone_issue_body" "$empty_tree" -p "$genesis_head" -p "$phone_add_commit")"
    [[ "$phone_issue_commit" < "$phone_revoke_commit" ]] && break
  done
  [[ "$phone_issue_commit" < "$phone_revoke_commit" ]] || fail "expected stale phone event hash to sort before device revoke hash"
  git update-ref refs/gitomi/inbox/alice/b "$phone_revoke_commit" "$revoke_commit"
  git update-ref refs/gitomi/inbox/alice/phone "$phone_issue_commit"
  events="$(gt events list --json)"
  phone_line="$(printf '%s\n' "$events" | grep '"actor_device":"phone"')"
  assert_contains "$phone_line" '"domain_status":"rejected"'
  assert_contains "$phone_line" '"rejection_reason":"unauthorized_device"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Phone stale issue"'
)
