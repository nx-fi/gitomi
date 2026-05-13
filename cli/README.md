# Gitomi CLI

`gt` is the Zig command line client for Gitomi.

Build:

```sh
zig build
```

Run from this package:

```sh
zig build run -- --help
```

Tests:

```sh
zig build test
zig build integration-test
```

Installed binary name:

```sh
zig build install
./zig-out/bin/gt --help
```

Implemented commands:

```text
gt init [--principal ID] [--device ID] [--repo-id UUID] [--force]
gt status
gt fsck
gt index rebuild|status
gt refs
gt events list [--json] [--limit N] [--ref REF]
gt issue list [--json]
gt issue open --title TITLE [--body BODY] [--label LABEL] [--assignee PRINCIPAL]
gt issue edit ISSUE [--title TITLE] [--body BODY] [--state open|closed] [--label LABEL] [--unlabel LABEL] [--assignee PRINCIPAL] [--unassign PRINCIPAL]
gt issue title ISSUE --title TITLE
gt issue body ISSUE --body BODY
gt issue close|reopen ISSUE
gt issue label add|remove ISSUE LABEL
gt issue assignee add|remove ISSUE PRINCIPAL
gt pull list [--json]
gt pull open --title TITLE --base BASE --head HEAD [--body BODY] [--draft]
gt pull edit PULL [--title TITLE] [--body BODY] [--state open|closed] [--base BASE] [--head HEAD] [--label LABEL] [--unlabel LABEL] [--assignee PRINCIPAL] [--unassign PRINCIPAL] [--reviewer PRINCIPAL] [--unreviewer PRINCIPAL]
gt pull title PULL --title TITLE
gt pull body PULL --body BODY
gt pull close|reopen PULL
gt pull base PULL --base BASE
gt pull head PULL --head HEAD
gt pull label add|remove PULL LABEL
gt pull assignee add|remove PULL PRINCIPAL
gt pull reviewer add|remove PULL PRINCIPAL
gt pull merge PULL [--merge-oid OID] [--target-oid OID]
gt comment list issue|pull OBJECT [--json]
gt comment add issue|pull OBJECT --body BODY
gt comment edit COMMENT --body BODY
gt comment redact COMMENT [--reason REASON]
gt runs prune [--dry-run] [--max-age-days N] [--max-count N] [--max-bytes N]
gt sync [--remote REMOTE] [--pull-only|--push-only]
gt web [--host 127.0.0.1] [--port 8080]
```

`gt init` writes a signed genesis manifest to `refs/gitomi/genesis`, including
the repo id, owner, device, public signing key, and key fingerprint. Configure
native Git commit signing before using it, for example SSH signing via
`gpg.format=ssh`.

`gt issue open` writes a signed Git commit to the configured inbox ref under
`refs/gitomi/inbox/<principal>/<device>`. Event identity is the Git commit hash;
client UUIDs are retained only as labels/idempotency keys. New events include
`parent_hashes` for the previous log event and up to 32 non-reachable observed
causal heads.

`gt issue edit` and `gt pull edit` batch multiple scalar and collection updates
into one signed `issue.updated` or `pull.updated` event.

`gt sync` fetches remote genesis and inbox refs into `refs/gitomi/staging/*`,
then admits only compatible genesis refs and new or fast-forward inbox refs into
the authoritative namespace after checking the event commit chain, empty-tree
rule, native Git signature, parent hashes, and v1 JSON envelope. Diverged or
chain-invalid staged inbox refs are moved under `refs/gitomi/quarantine/*`.

`gt fsck` verifies authoritative inbox refs for ref-safe names, empty-tree event
commits, native Git signatures, v1 event envelopes, matching repo IDs, unique
and strictly increasing `(principal, device, seq)` tuples, and first-parent
inbox-chain shape.

`gt index rebuild` writes a disposable SQLite event projection to
`.git/gitomi/index.sqlite`, including the inbox ref heads used to decide
freshness. Structurally valid but domain-rejected events remain visible with a
rejection reason and do not affect issue, pull, or comment projections. `gt
events list`, `gt status`, and the web UI rebuild the cache automatically when
inbox heads change, then query it instead of running `git show` for every
event.

`gt runs prune` deletes auxiliary refs under `refs/gitomi/runs/*` according to
age, count, and byte limits. Run refs are not fetched or pushed by default sync;
the signed `action.run_completed` inbox event is the durable workflow result.

`gt web` starts a local-only GitHub-like web UI for the current repository. It
binds to loopback by default, opens on a committed-tree code explorer, also
serves overview/issues/events/refs pages, and can create signed issue events
through the same storage path as `gt issue open`.
