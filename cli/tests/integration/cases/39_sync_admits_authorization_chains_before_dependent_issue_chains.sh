#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="sync admits authorization chains before dependent issue chains"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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

