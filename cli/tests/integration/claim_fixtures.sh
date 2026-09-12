# Signed short-deadline fixtures, so watchdog tests do not wait full claim TTLs.
# Source after lib.sh. Every call creates a fresh repository and initial ledger.
seed_short_claim() {
  local name="$1" seconds="$2" now acquired blob subtree tree record body
  init_repo "$ROOT/$name"
  cd "$ROOT/$name"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  CLAIM_ID=018f0000-0000-7000-8000-000000000051
  now="$(date +%s)"
  CLAIM_DEADLINE=$((now + seconds))
  acquired="$(date -u -d "@$((now - 120))" +%Y-%m-%dT%H:%M:%SZ)"
  CLAIM_EXPIRES="$(date -u -d "@$CLAIM_DEADLINE" +%Y-%m-%dT%H:%M:%SZ)"
  record='{"$schema":"urn:gitomi:claim:v1","repo_id":"'"$REPO_ID"'","claim_id":"'"$CLAIM_ID"'","lease_seq":1,"holder":{"principal":"alice","device":"laptop"},"mode":"write","paths":["src/**"],"acquired_at":"'"$acquired"'","expires_at":"'"$CLAIM_EXPIRES"'","reason":"watchdog fixture"}'
  blob="$(printf '%s' "$record" | git hash-object -w --stdin)"
  subtree="$(printf '100644 blob %s\t%s.json\n' "$blob" "$CLAIM_ID" | git mktree)"
  tree="$(printf '040000 tree %s\tclaims\n' "$subtree" | git mktree)"
  body='{"$schema":"urn:gitomi:claim-delta:v1","repo_id":"'"$REPO_ID"'","writer":{"principal":"alice","device":"laptop"},"actions":[{"op":"acquire","claim_id":"'"$CLAIM_ID"'"}],"wrote_at":"'"$acquired"'"}'
  CLAIM_HEAD="$(git commit-tree -S "$tree" -m claim.acquire -m "$body")"
  git update-ref refs/gitomi/claims/ledger "$CLAIM_HEAD" ''
}

wait_file() {
  for ((probe=0; probe<200; probe++)); do
    [[ ! -s "$1" ]] || return 0
    sleep 0.025
  done
  fail "worker did not start: $1"
}

assert_process_gone() {
  local pid="$1"
  for ((probe=0; probe<200; probe++)); do
    [[ -e "/proc/$pid/stat" ]] || return 0
    sleep 0.025
  done
  fail "supervised process survived or was not reaped: $pid"
}
