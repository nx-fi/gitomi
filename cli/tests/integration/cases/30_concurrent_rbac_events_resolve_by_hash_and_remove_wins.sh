#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="concurrent RBAC events resolve by hash and remove-wins"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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

