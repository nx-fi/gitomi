#!/usr/bin/env bash
set -euo pipefail

GT_BIN="${GT_BIN:?usage: integration.sh /path/to/gt}"
GT_BIN="$(cd "$(dirname "$GT_BIN")" && pwd)/$(basename "$GT_BIN")"

TEST_SLUG="${TEST_SLUG:-$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" .sh)}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitomi-cli-it.${TEST_SLUG}.XXXXXX")"
cleanup_root() {
  local status=$?
  if [[ -n "${GT_INTEGRATION_KEEP_TMP:-}" || "$status" -ne 0 ]]; then
    echo "integration: temp kept for ${TEST_NAME:-unknown}: $ROOT" >&2
  else
    rm -rf "$ROOT"
  fi
}
trap cleanup_root EXIT

REPO_ID="018f0000-0000-7000-8000-000000000001"
KEY="$ROOT/signing_key"
BOB_KEY="$ROOT/bob_signing_key"
ALLOWED_SIGNERS="$ROOT/allowed_signers"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"$'\n'"output was:"$'\n'"$haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"$'\n'"output was:"$'\n'"$haystack"
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

assert_line_count() {
  local text="$1"
  local expected="$2"
  local count
  count="$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "$expected" ]] || fail "expected $expected non-empty line(s), got $count"$'\n'"$text"
}

assert_line_order() {
  local text="$1"
  shift
  local previous=0
  local needle line
  for needle in "$@"; do
    line="$(printf '%s\n' "$text" | grep -nF "$needle" | head -n 1 | cut -d: -f1 || true)"
    [[ -n "$line" ]] || fail "expected output to contain ordered item: $needle"$'\n'"output was:"$'\n'"$text"
    (( line > previous )) || fail "expected '$needle' to appear after previous ordered item"$'\n'"output was:"$'\n'"$text"
    previous="$line"
  done
}

assert_equal() {
  local left="$1"
  local right="$2"
  local message="$3"
  [[ "$left" == "$right" ]] || fail "$message"$'\n'"left:"$'\n'"$left"$'\n'"right:"$'\n'"$right"
}

json_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "$json" | sed -n 's/.*"'"$field"'":"\([^"]*\)".*/\1/p' | head -n 1
}

object_ref() {
  printf '%s' "$1" | sha256sum | awk '{ print substr($1, 1, 7) }'
}

write_gt_config() {
  local repo_id="$1"
  local principal="$2"
  local device="$3"
  local seq="$4"
  cat > .git/gitomi/config.toml <<EOF
repo_id = "$repo_id"
principal = "$principal"
device = "$device"
seq = $seq
EOF
}

configure_signing() {
  local repo="$1"
  git -C "$repo" config user.name "Alice"
  git -C "$repo" config user.email "alice@example.com"
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config user.signingkey "$KEY"
  git -C "$repo" config gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
}

configure_bob_signing() {
  local repo="$1"
  git -C "$repo" config user.name "Bob"
  git -C "$repo" config user.email "bob@example.com"
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config user.signingkey "$BOB_KEY"
  git -C "$repo" config gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
}

trust_repo() {
  local repo="$1"
  mkdir -p "$repo/.git/gitomi"
  : > "$repo/.git/gitomi/trust"
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init >/dev/null
  trust_repo "$repo"
  configure_signing "$repo"
}

gt() {
  "$GT_BIN" "$@"
}

write_bash_script() {
  local path="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    cat
  } > "$path"
  chmod +x "$path"
}

seed_github_legacy_import() {
  local repo="$1"
  init_repo "$repo"
  (
    cd "$repo"
    gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
    mkdir -p src
    printf 'legacy merge target\n' > src/legacy-merge.txt
    git add src/legacy-merge.txt
    git commit -m "Legacy merge target" >/dev/null
    fixture_merge_oid="$(git rev-parse HEAD)"
    cat > github-fixture.json <<JSON
{
  "issues": [
    {
      "number": 42,
      "title": "Legacy bug",
      "body": "Imported issue body mentioning #42",
      "state": "closed",
      "created_at": "2026-01-01T00:00:00Z",
      "closed_at": "2026-01-02T00:00:00Z",
      "user": { "login": "octocat" },
      "tags": ["triage"],
      "milestone": { "title": "v1.0" },
      "labels": [{ "name": "bug" }],
      "assignees": [{ "login": "alice" }]
    }
  ],
  "pulls": [
    {
      "number": 7,
      "title": "Legacy PR",
      "body": "Imported pull body",
      "state": "closed",
      "created_at": "2026-01-03T00:00:00Z",
      "merged_at": "2026-01-04T00:00:00Z",
      "merge_commit_sha": "$fixture_merge_oid",
      "user": { "login": "ichewm" },
      "labels": [{ "name": "docs" }],
      "assignees": [{ "login": "bob" }],
      "requested_reviewers": [{ "login": "Okenx" }],
      "base": { "ref": "main" },
      "head": { "ref": "feature" },
      "draft": false,
      "commits": 1,
      "changed_files": 4,
      "additions": 40,
      "deletions": 4
    }
  ],
  "comments": {
    "issue:42": [
      { "id": 100, "body": "Imported issue comment mentioning #42", "created_at": "2026-01-02T01:00:00Z", "user": { "login": "commenter" } },
      { "id": 101, "body": "Imported issue reply", "created_at": "2026-01-02T01:30:00Z", "user": { "login": "reviewer" }, "in_reply_to_id": 100 }
    ],
    "pull:7": [{ "body": "Imported pull comment", "created_at": "2026-01-04T01:00:00Z" }]
  },
  "projects": {
    "issue:42": [{ "project": "Roadmap", "column": "Done" }]
  }
}
JSON
    gt github import --from-file github-fixture.json >/dev/null
  )
}

ssh-keygen -q -t ed25519 -N "" -C "alice@example.com" -f "$KEY"
ssh-keygen -q -t ed25519 -N "" -C "bob@example.com" -f "$BOB_KEY"
BOB_PUBLIC_KEY="$(awk '{ print $1 " " $2 }' "$BOB_KEY.pub")"
BOB_FINGERPRINT="$(ssh-keygen -lf "$BOB_KEY.pub" -E sha256 | awk '{ print $2 }')"
{
  awk '{ print "alice@example.com " $1 " " $2 }' "$KEY.pub"
  awk '{ print "bob@example.com " $1 " " $2 }' "$BOB_KEY.pub"
} > "$ALLOWED_SIGNERS"
