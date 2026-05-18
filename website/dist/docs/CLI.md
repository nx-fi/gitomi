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
gt init [--principal ID] [--device ID] [--repo-id UUID] [--access open|closed] [--force]
gt status
gt fsck
gt index rebuild|status
gt index snapshots prune [--dry-run] [--max-count N] [--max-bytes N] [--max-tree-bytes N]
gt refs
gt quarantine list
gt quarantine inspect REF
gt quarantine adopt REF [--replace-local] [--keep] [--yes]
gt quarantine restore-local-to-remote REF [--remote REMOTE] [--keep] [--yes]
gt quarantine drop REF [--yes]
gt clear local [--yes]
gt clear remote [--remote REMOTE] [--yes]
gt reset local [--yes]
gt reset remote [--remote REMOTE] [--yes]
gt events list [--json] [--limit N] [--ref REF]
gt issue list [--json] [--view agent] [--state open|closed|all] [--author PRINCIPAL] [--label LABEL] [--project PROJECT] [--milestone MILESTONE] [--assignee PRINCIPAL] [--sort newest|oldest|updated] [--limit N]
gt issue show ISSUE [--json] [--view agent]
gt issue open --title TITLE [--body BODY] [--type bug|feature|task] [--priority P0|P1|P2|P3] [--status Draft|Todo|WIP|Review|Done|Failed] [--label LABEL] [--assignee PRINCIPAL]
gt issue edit ISSUE [--title TITLE] [--body BODY] [--state open|closed] [--type bug|feature|task] [--priority P0|P1|P2|P3] [--status Draft|Todo|WIP|Review|Done|Failed] [--label LABEL] [--unlabel LABEL] [--assignee PRINCIPAL] [--unassign PRINCIPAL]
gt issue title ISSUE --title TITLE
gt issue body ISSUE --body BODY
gt issue type ISSUE --type bug|feature|task
gt issue priority ISSUE --priority P0|P1|P2|P3
gt issue status ISSUE --status Draft|Todo|WIP|Review|Done|Failed
gt issue comment ISSUE --body BODY [--reply COMMENT]
gt issue close|reopen ISSUE [--body BODY]
gt issue label ISSUE add|remove LABEL
gt issue assignee ISSUE add|remove PRINCIPAL
gt issue milestone ISSUE --milestone MILESTONE
gt issue project ISSUE add|remove PROJECT --column COLUMN
gt issue react|unreact ISSUE EMOJI
gt project list [--json]
gt project create --name NAME [--description TEXT] [--column COLUMN]
gt project column PROJECT add|remove COLUMN
gt project add|remove PROJECT ISSUE --column COLUMN
gt milestone list [--json]
gt milestone create --title TITLE [--description TEXT] [--due DATE]
gt milestone edit MILESTONE [--title TITLE] [--description TEXT] [--due DATE] [--state open|closed]
gt milestone close|reopen MILESTONE
gt milestone delete MILESTONE
gt pr list [--json] [--view agent] [--state open|merged|closed|all] [--limit N]
gt pr view PR [--json] [--view agent] [--include-diff]
gt pr create --title TITLE --base BASE --head HEAD [--body BODY] [--draft]
gt pr edit PR [--title TITLE] [--body BODY] [--state open|closed] [--base BASE] [--head HEAD] [--add-label LABEL] [--remove-label LABEL] [--add-assignee PRINCIPAL] [--remove-assignee PRINCIPAL] [--add-reviewer PRINCIPAL] [--remove-reviewer PRINCIPAL]
gt pr title PR --title TITLE
gt pr body PR --body BODY
gt pr close|reopen PR
gt pr base PR --base BASE
gt pr head PR --head HEAD
gt pr label PR add|remove LABEL
gt pr assignee PR add|remove PRINCIPAL
gt pr reviewer PR add|remove PRINCIPAL
gt pr comment PR --body BODY [--reply COMMENT]
gt pr comment PR --body BODY --file PATH --side old|new --line LINE
gt pr comment PR --body BODY --file PATH --side old|new --start-line LINE [--end-line LINE]
gt pr react|unreact PR EMOJI
gt pr merge PR [--merge-oid OID] [--target-oid OID]
gt comment list issue|pr OBJECT [--json]
gt comment add issue|pr OBJECT --body BODY
gt comment reply COMMENT --body BODY
gt comment edit COMMENT --body BODY
gt comment redact COMMENT [--reason REASON]
gt comment react|unreact COMMENT EMOJI
gt inbox [--json] [--all|--unread] [--principal PRINCIPAL] [--limit N]
gt notification subscribe issue|pr OBJECT [--principal PRINCIPAL]
gt notification unsubscribe issue|pr OBJECT [--principal PRINCIPAL]
gt notification subscriptions [--json] [--principal PRINCIPAL]
gt notification read EVENT|--all [--principal PRINCIPAL]
gt actions workflows [--json] [--ref REF|--oid OID]
gt actions request --workflow WORKFLOW [--ref REF|--oid OID] [--event EVENT]
gt actions complete RUN --conclusion CONCLUSION [--workflow WORKFLOW] [--ref REF|--oid OID] [--event EVENT]
gt actions run --event EVENT [--ref REF|--oid OID] [--object-id ID] [--dry-run] [--act PATH] [--agent-runner PATH] [-- ACT_ARGS...]
gt actions run-requested [RUN] [--dry-run] [--act PATH] [--agent-runner PATH] [-- ACT_ARGS...]
gt actions daemon [--once] [--replay] [--interval-ms N] [--dry-run] [--act PATH] [--agent-runner PATH] [-- ACT_ARGS...]
gt runs prune [--dry-run] [--max-age-days N] [--max-count N] [--max-bytes N]
gt sync [--remote REMOTE] [--pull-only|--push-only]
gt github import [--repo OWNER/REPO] [--token-env NAME|--token-file PATH] [--from-file PATH] [--no-comments] [--no-projects] [--rest|--graphql]
gt github export --repo OWNER/REPO [--token-env NAME|--token-file PATH|--use-gh] [--dry-run] [--map-file PATH] [--reuse-legacy] [--rest|--graphql]
gt github sync [--repo OWNER/REPO] [--token-env NAME|--token-file PATH|--use-gh] [--remote REMOTE] [--interval-ms N] [--max-pages N] [--dry-run] [--no-git-sync] [--import-only] [--rest|--graphql]
gt github live [--repo OWNER/REPO] --webhook-url URL (--secret-env NAME|--secret-file PATH) [--host 127.0.0.1] [--port 12656] [--path /github/webhook] [--remote REMOTE] [--interval-ms N] [--once] [--no-subscribe] [--dry-run] [--no-git-sync] [--rest|--graphql]
gt gitlab import [--project GROUP/PROJECT] [--token-env NAME|--token-file PATH] [--from-file PATH] [--no-comments]
gt gitlab export --project GROUP/PROJECT [--token-env NAME|--token-file PATH] [--dry-run] [--map-file PATH] [--reuse-legacy]
gt gitlab sync --project GROUP/PROJECT [--token-env NAME|--token-file PATH] [--remote REMOTE] [--interval-ms N] [--max-pages N] [--dry-run] [--no-git-sync]
gt web [--local] [--host 127.0.0.1] [--port 12655] [--once]
gt web --live [--host 127.0.0.1] [--port 12655] [--repo OWNER/REPO] [--webhook-url URL] (--secret-env NAME|--secret-file PATH) [--live-host 127.0.0.1] [--live-port 12656] [--live-path /github/webhook] [--remote REMOTE] [--interval-ms N] [--no-subscribe] [--dry-run] [--no-git-sync] [--rest|--graphql]
```

`gt init` writes a signed genesis manifest to `refs/gitomi/genesis`, including
the repo id, access mode, owner, device, public signing key, and key
fingerprint. `--access closed` is the default RBAC mode: events from principals
without effective grants remain in the signed inbox log but are not projected
as visible issues, comments, or other domain objects. `--access open` accepts
signed events from anyone who can sync and push Gitomi refs, leaving access
control to the Git server. Configure Git commit signing before using it. OpenPGP
`user.signingkey` values are exported with `gpg`; SSH signing is also supported
when `gpg.format=ssh`.

`gt issue open` writes a signed Git commit to the configured inbox ref under
`refs/gitomi/inbox/<principal>/<device>`. Event identity is the Git commit hash;
client UUIDs are retained only as labels/idempotency keys. New events include
`parent_hashes` for the previous log event and up to 32 non-reachable observed
causal heads.

`gt issue edit` and `gt pr edit` batch multiple scalar and collection updates
into one signed `issue.updated` or `pull.updated` event. `gt issue comment`
mirrors the issue conversation form, including replies, and `gt issue close`
or `gt issue reopen` can write the same optional note that the web UI accepts
when changing issue state.

`gt issue list --view agent` and `gt pr list --view agent` emit single
aggregated JSON documents with active filters, counts, rows, and suggested
`cli_commands`. `gt issue show --view agent` and `gt pr view --view agent`
include detail metadata, comments, reactions, timeline events, commit
references, and command templates for follow-up actions. `gt pr view --view
agent --include-diff` also includes a local diff when the pull request base and
head refs are available.

`gt inbox` lists unread notifications by default and can show recent read and
unread events with `--all`. `gt notification subscribe` and
`gt notification unsubscribe` explicitly manage issue or pull request
subscriptions, while `gt notification read EVENT` and
`gt notification read --all` write signed read-marker events.

`gt project create` creates a signed project board event with kanban columns.
When no columns are supplied it creates `Todo`, `In Progress`, and `Done`.
`gt project add` and `gt project remove` place issue cards on or off a board
column by writing signed issue placement events. `gt milestone create` creates
named milestones, `gt milestone edit` updates title, description, due date, or
state, `gt milestone close` / `gt milestone reopen` change milestone state, and
`gt milestone delete` removes a milestone.
`gt issue milestone` assigns or clears an issue milestone.

`gt pr view` also accepts `show`, and `gt pr create` also accepts `open` and
`new`.
`gt pr comment` can reply to an existing comment or add the same file/line
review note produced from the pull request Files tab. Pull request merge and
conflict-resolution semantics are specified in
`../spec/06_PULL_REQUEST_MERGE_SEMANTICS.md`: web-initiated merges are
remote-first, use detached temporary worktrees or equivalent object-level
operations for computation, and must not update the active local worktree or
local base/head branches by default.

`gt sync` fetches remote genesis and inbox refs into `refs/gitomi/staging/*`,
then admits only compatible genesis refs and new or fast-forward inbox refs into
the authoritative namespace after checking the event commit chain, empty-tree
rule, native Git signature, parent hashes, and v1 JSON envelope. Diverged or
chain-invalid staged inbox refs are moved under `refs/gitomi/quarantine/*`.
To join an existing Gitomi repository, clone or add the remote and run
`gt sync` without running `gt init` first; the remote genesis is promoted
locally and a local config is created from it. A replica that has already
created a different local genesis must clear or recreate its local Gitomi state
before it can trust and project the remote issues.
Default push publishes local genesis and, when present, the configured actor's
own inbox ref under `refs/gitomi/inbox/<principal>/<device>`. It does not relay
locally replicated inbox refs for other principals or devices. Sync does not
publish local cache or diagnostic namespaces such as
`refs/gitomi/staging/*`, `refs/gitomi/quarantine/*`, `refs/gitomi/snapshots/*`,
or `refs/gitomi/runs/*`.

`gt quarantine list` and `gt quarantine inspect REF` show staged inbox heads that
sync refused to admit. `gt quarantine adopt REF` validates the quarantined inbox
chain and installs it as the local authoritative inbox ref; if that would replace
a divergent local head, pass `--replace-local`. `gt quarantine
restore-local-to-remote REF` pushes the current local inbox head back to the
remote with `--force-with-lease` pinned to the quarantined head, which is the
intended recovery path when the remote was accidentally rewritten. `gt
quarantine drop REF` deletes a diagnostic quarantine ref after the operator has
chosen a recovery path.

`gt fsck` verifies authoritative inbox refs for ref-safe names, empty-tree event
commits, native Git signatures, signing-key bindings to actor identities, v1
event envelopes, matching repo IDs, unique and strictly increasing `(principal,
device, seq)` tuples, and first-parent inbox-chain shape.

`gt actions workflows` reads native workflow definitions from
`.gitomi/workflows/*.yml` and `.gitomi/workflows/*.yaml`, plus
GitHub Actions-compatible workflow definitions from `.github/workflows/*.yml`
and `.github/workflows/*.yaml`, in the selected commit. `gt actions run`
schedules matching workflows for a Gitomi or data-plane event, emits a signed
`action.run_requested` event, creates a detached worktree at the target commit,
executes native shell/container/agent jobs or runs GitHub-compatible workflows
through `nektos/act` as `act <event> -W <workflow> -e <payload>`, then emits a
signed `action.run_completed` event. For pull events, workflows without an
explicit `source:` policy default to `workflow_from: base` and
`code_from: head`; the run request and diagnostics record both the workflow
source OID and the code target OID. `gt actions request` and
`gt actions complete` expose the same event emission manually, and
`gt actions run-requested` executes accepted pending run requests from the local
event projection. Extra act flags can be passed after `--`; `--act PATH`
selects a non-default act binary, and `--agent-runner PATH` selects the external
agent backend command for native `backend: agent` jobs.

`gt actions daemon` is the scheduler service. It polls the local repository,
executes accepted pending run requests, schedules new accepted Gitomi events,
cron-style native `schedule` triggers, and `HEAD` changes against matching
workflow triggers, and stores local cursors under
`.git/gitomi/actions-scheduler.state`. On first start it begins from the
current frontier; use `--replay` to intentionally schedule existing history.

`gt index rebuild` writes a disposable SQLite event projection to
`.git/gitomi/index.sqlite`, including the inbox, branch, and tag heads used to
decide freshness. Structurally valid but domain-rejected events remain visible
with a rejection reason and do not affect issue, pull, or comment projections.
`gt events list`, `gt status`, and the web UI rebuild the cache automatically
when indexed refs change, then query it instead of running `git show` for every
event. Rebuilds restore the newest valid snapshot first; Gitomi writes the first
snapshot immediately, then writes another only after 64 new events or after the
previous snapshot is at least 24 hours old and there is new event history to
checkpoint. Branch and tag movement can reuse event snapshots while derived
commit references are rebuilt for the current refs. Automatic retention keeps at
most 32 snapshots, at most 64 MiB per snapshot, and at most 2 GiB total by
default. `gt index snapshots prune` applies the same retention rules manually,
with optional count, total-byte, and per-snapshot byte limits.

`gt runs prune` deletes auxiliary refs under `refs/gitomi/runs/*` according to
age, count, and byte limits. By default it retains run diagnostics no older than
30 days, at most 100 run refs, and at most 256 MiB. Run refs are not fetched or
pushed by default sync; the signed `action.run_completed` inbox event is the
durable workflow result.

`gt clear local` deletes all local refs under `refs/gitomi/*` while leaving
`.git/gitomi/config.toml` and local caches in place. `gt reset local` deletes
local `refs/gitomi/*` and the repo-local `.git/gitomi/` state directory, so the
next `gt init` starts from scratch. `gt clear remote` and `gt reset remote`
delete all refs under `refs/gitomi/*` from a remote, using `origin` by default
or `--remote REMOTE`. All variants require an exact typed confirmation unless
`--yes` is supplied.

`gt github import` reads GitHub issues and pull requests from the GitHub API or
a fixture JSON object with `issues`, `pulls`, and optional `comments` fields,
then writes signed import events through a delegated `import-bot/github` actor.
The current maintainer or owner emits an `acl.delegation_granted` event that
binds the bot to the signing key used for the import. With no API or fixture
options, it shells out to local `gh` for repository and credential discovery
from the current Git checkout. Imported
issue and pull numbers are preserved as `legacy.github_issue_number` and
`legacy.github_pull_number`, are materialized in the local index, and can be
used as `#123`, `gh#123`, or `github:123` references. A later import skips
issues and pulls whose GitHub number is already present locally. Imported
issues also retain GitHub authors, labels/tags, milestones, and project column
placements; pass `--no-projects` to skip GitHub project-card discovery.
GraphQL is the default API mode; pass `--rest` for the older REST importer.

`gt github export` replays accepted Gitomi issue, pull, and comment transitions
through the GitHub API. It stores the Gitomi UUID to GitHub number mapping in
`.git/gitomi/github/<owner>/<repo>/map.jsonl`; use `--dry-run` to print the API
requests without network writes, `--use-gh` to route writes through the local
GitHub CLI credentials, or `--reuse-legacy` when exporting back to the same
GitHub repository that was imported. GraphQL is the default API mode for core
issue, pull, and comment create/update operations, with REST still used for
name-based label/assignee/reviewer deltas and comment edits that require
database-number mappings; pass `--rest` to force the older REST replay path.

`gt github sync` performs a polling API sync: optional Gitomi `gt sync` pull,
GitHub import, optional GitHub export of local accepted events since the last
sync, and optional Gitomi publication. It defaults to `--graphql`, batching issue
and pull pages with nested fields through GitHub's GraphQL API and using the
GraphQL export path by default; pass `--rest` to use the older REST path. State
and the private export map live under `.git/gitomi/github/<owner>/<repo>/`; pass
`--no-git-sync` to skip surrounding Git transport steps, or `--import-only` to
skip outbound GitHub writes. Before exporting, the exporter seeds that private
map from shared Gitomi GitHub aliases so a replica that has pulled bridge
aliases does not recreate already-exported issues or pull requests.

For GitHub-to-Gitomi imports, all maintainers share one canonical bridge actor:
`import-bot/github` by default, stored at
`refs/gitomi/inbox/import-bot/github`. A maintainer running `gt github sync`
first pulls remote Gitomi refs, then imports GitHub changes through that bot
actor. Before any outbound GitHub export, sync publishes the maintainer's own
inbox (including any new delegation grant) and then pushes the bot inbox
fast-forward-only. If another maintainer published the same bridge inbox first,
sync restores its local GitHub mapping file, abandons only the unpublished local
bot commits, pulls the remote bot head, and retries the import. Use
`gt github sync --import-only` when any maintainer should be able to refresh
GitHub state into Gitomi without also performing outbound GitHub writes. When
outbound sync creates a GitHub issue or pull request from a local Gitomi object,
it records the GitHub number as an alias-only `issue.updated` or `pull.updated`
event on the bridge inbox and pushes that alias before advancing export state.
Later importers resolve the GitHub object to the original Gitomi object even if
their private map file is empty.

Do not solve bridge concurrency by creating a different Gitomi genesis per user.
That creates separate trust roots and separate repositories. Also avoid one bot
device per maintainer for the same GitHub project unless the GitHub source IDs
are made globally unique in the reducer: concurrent imports on separate bot
devices can otherwise create duplicate native Gitomi objects for the same
GitHub issue, pull, or comment. The intended model is one shared genesis, one
canonical bridge inbox per upstream project, and fast-forward/retry publication
by any maintainer authorized for that bridge. Shared aliases prevent later
duplicate issue and pull exports, but they are not a distributed lock for
simultaneous outbound creates; two exporters can still race before either has
published the alias, and comment export receipts remain local. Run
Gitomi-to-GitHub export from one designated runner or serialize exporters
externally when outbound writes are enabled.

`gt github live` runs the normal local Gitomi workflow with a two-way GitHub
bridge. It subscribes the current repository to a GitHub webhook through
`gh api`, listens locally for `issues`, `pull_request`, `issue_comment`, and
`push` events, imports GitHub changes as delegated `import-bot/github` events,
and periodically exports accepted local issue, pull, and comment events back to
GitHub through the GitHub CLI. Live state and the export map are stored under
`.git/gitomi/github/<owner>/<repo>/`; use `--no-subscribe` when the webhook
already exists, `--once` for one webhook request plus one export pass, or
`--no-git-sync` to skip the surrounding Gitomi `gt sync` pull/push steps. Live
uses webhook payloads for incoming GitHub changes and defaults its periodic
outbound export pass to GraphQL; pass `--rest` to force REST export. Live
webhook imports require `--secret-env` or `--secret-file` so GitHub deliveries
are authenticated with `X-Hub-Signature-256`; use the same secret when
configuring an existing hook with `--no-subscribe`.

`gt gitlab import` reads GitLab issues and merge requests from the GitLab REST
API, or a fixture JSON object with `issues`, `merge_requests`/`pulls`, and
optional `notes`/`comments` fields. It writes signed import events through a
delegated `import-bot/gitlab` actor. GitLab credentials come from
`GITLAB_TOKEN`, `GL_TOKEN`, `--token-env`, or `--token-file`. Imported issue and
merge request IIDs are stored as `legacy.gitlab_issue_iid` and
`legacy.gitlab_merge_request_iid`, materialized as `gitlab` aliases, and can be
used as `gl#123`, `gl:123`, `gitlab#123`, or `gitlab:123` references.

`gt gitlab export` replays accepted Gitomi issue, pull, and comment transitions
through the GitLab REST API and stores UUID-to-IID mappings in
`.git/gitomi/gitlab/<project>/map.jsonl`. `--reuse-legacy` maps previously
imported GitLab objects instead of recreating them.

`gt gitlab sync` performs a two-way API sync: optional Gitomi `gt sync` pull,
GitLab import, GitLab export of local accepted events since the last sync, and
optional Gitomi `gt sync` push. State and mappings live under
`.git/gitomi/gitlab/<project>/`; set `--interval-ms N` to poll continuously or
`--no-git-sync` to skip the surrounding Git transport steps.

`gt web` starts a local-only GitHub-like web UI for the current repository. It
binds to loopback on port 12655 by default, retrying nearby random ports if that
port is occupied. `--local` is the default mode. `--live` starts the web UI and a
GitHub live sync daemon in the same process; the web UI remains loopback-only,
while the live webhook listener uses `--live-host`, `--live-port`, and
`--live-path`, defaults its outbound GitHub export pass to GraphQL, accepts
`--rest` to force REST export, requires `--webhook-url` unless `--no-subscribe`
is used, and requires `--secret-env` or `--secret-file` for authenticated
webhook deliveries. It opens on a committed-tree code explorer, also serves
issues/projects/workflows/events/refs pages, and can create signed issue
events and workflow run requests through the same storage path as the CLI. The
inbox menu shows recent notifications, and issue and pull request detail pages
can subscribe or unsubscribe the current principal from notifications. The
projects page renders kanban boards from signed project and issue placement
events and can create new project boards. The web server is intended for local
use only; Zig does not yet provide HTTP/2 server support, so Gitomi does not
treat this endpoint as production-facing infrastructure.

The web UI supports keyboard shortcuts across pages. Press Space by default to
show keystroke hints for visible clickable elements, press Space twice to open
the shortcut reference, and use unleadered Vim-style navigation keys such as
`h`, `j`, `k`, `l`, `/`, `t`, `n`, and `e`. Customize the click-hint keys in
`.git/gitomi/config.toml`:

```toml
web.shortcut_leader = "Space"
web.shortcut_keys = "A S D F J K L E R U I O W Q P Z X C V B N M G H Y T"
web.shortcut_timeout_ms = 900
```
