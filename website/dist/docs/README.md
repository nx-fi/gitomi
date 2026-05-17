# Gitomi

**A local-first forge that lives inside Git.**

Gitomi adds issues, pull requests, project boards, milestones, comments, access
control, and workflow runs to an ordinary Git repository. There is no central
database, no required server, and no custom transport. The project state is
stored as signed Git commits under `refs/gitomi/*`, so it moves with the same
`git fetch` and `git push` workflow you already use for code.

Use it when you want GitHub-like collaboration without making a hosted service
the source of truth.

## Why Gitomi?

- **Local-first collaboration**: create and read issues, PRs, projects, and
  workflow history from your clone.
- **Plain Git replication**: sync social and automation state through ordinary
  Git refs, remotes, bundles, and mirrors.
- **Signed history**: every user-facing change is a native signed Git commit in
  an append-only event log.
- **Offline-friendly by design**: each device writes to its own inbox ref, then
  replicas merge state deterministically when they sync.
- **No lock-in data plane**: source code remains standard branches, tags, trees,
  and blobs.
- **GitHub migration path**: import existing GitHub issues and pull requests, or
  export Gitomi state back to GitHub.

## What You Get

| Area | Included |
| --- | --- |
| Issues | Open, edit, label, assign, close, comment, react, and link to milestones or projects |
| Pull requests | Track base/head refs, reviewers, labels, assignees, comments, reactions, and merges |
| Projects | Create kanban boards and move issue cards across columns |
| Milestones | Create, edit, close, reopen, and assign milestones |
| Workflows | Discover GitHub Actions-style workflows and run them locally with `act` |
| Web UI | Browse code, issues, projects, workflows, events, and refs from a local web interface |
| Sync | Fetch, validate, quarantine, and publish Gitomi refs through a normal Git remote |
| Integrity | Verify signed event logs with `gt fsck` and rebuild disposable local indexes |

## Quick Start

Build the CLI:

```sh
cd cli
zig build
./zig-out/bin/gt --help
```

Initialize Gitomi in an existing Git repository:

```sh
gt init --principal alice --device laptop
gt issue open --title "Write the release notes" --body "Collect highlights for v1."
gt issue list
```

Start the local web UI:

```sh
gt web
```

Gitomi serves a loopback-only browser interface by default. It includes code
browsing, issue and project views, workflow pages, event inspection, ref
diagnostics, and keyboard shortcuts for fast navigation. The web server is
intended for local use only; Zig does not yet provide HTTP/2 server support, so
Gitomi does not treat this endpoint as production-facing infrastructure.

To run the web UI and GitHub live sync together:

```sh
gt web --live --repo OWNER/REPO --webhook-url https://example.test/github/webhook --secret "$WEBHOOK_SECRET"
```

## Sync With a Remote

Gitomi state is published as Git refs. After a repository is initialized, use:

```sh
gt sync
```

Sync fetches remote Gitomi refs into a staging namespace, validates signatures,
event chains, genesis compatibility, and event envelopes, then admits valid
history into the local projection. Invalid or diverged inbox heads are moved to
local quarantine refs for inspection.

To join an existing Gitomi repository, clone or add the remote and run `gt sync`
before `gt init`. The remote genesis ref becomes the local trust anchor.

## Workflows

Gitomi reads native workflow files from `.gitomi/workflows/*.yml` and
`.gitomi/workflows/*.yaml`, and can also run GitHub Actions-compatible workflow
files from `.github/workflows/*.yml` and `.github/workflows/*.yaml`.
Pull-triggered workflows default to trusted base-side definitions running
against head-side code, with both source OIDs recorded in run metadata.

```sh
gt actions workflows
gt actions run --event push --ref HEAD --dry-run
gt actions daemon
```

Workflow requests and completions are signed Gitomi events. Local logs and run
diagnostics are retained separately under `refs/gitomi/runs/*` and can be
pruned without losing the durable workflow result.

## GitHub Import, Export, and Sync

Bring existing GitHub project history into Gitomi:

```sh
gt github import --repo OWNER/REPO
```

Export accepted Gitomi issue, pull request, and comment transitions back to
GitHub:

```sh
gt github export --repo OWNER/REPO --dry-run
```

Run a two-way live bridge through the GitHub CLI and a local webhook receiver:

```sh
gt github live --repo OWNER/REPO --webhook-url https://example.test/github/webhook --secret-env WEBHOOK_SECRET
```

Or poll GitHub for two-way API sync. GraphQL is the default API mode for
GitHub import/export/sync/live; pass `--rest` to use the older REST paths:

```sh
gt github sync --repo OWNER/REPO
```

Imports preserve GitHub issue and pull request numbers as secondary aliases, so
references such as `#123`, `gh#123`, and `github:123` continue to work.

## How It Works

Gitomi separates a repository into two planes:

- **Data plane**: ordinary Git branches, tags, trees, and blobs for source code.
- **Control plane**: signed, append-only event commits in
  `refs/gitomi/inbox/<principal>/<device>`.

The current view of issues, pull requests, projects, milestones, comments,
actions, identities, and ACLs is derived from those events by deterministic
reducers. The local SQLite index in `.git/gitomi/index.sqlite` is a disposable
cache and can be rebuilt from Git refs.

## Requirements

- Git
- Zig, for building the `gt` CLI
- Git commit signing configured for the actor device
- Optional: [`nektos/act`](https://github.com/nektos/act) for local execution
  of GitHub Actions-compatible workflows
- Optional: GitHub CLI credentials for GitHub import/export and live sync

## CLI Reference

The implemented command set includes:

- `gt init`, `gt status`, `gt sync`, `gt fsck`, `gt refs`
- `gt issue ...`, `gt pr ...`, `gt comment ...`
- `gt project ...`, `gt milestone ...`
- `gt actions ...`, `gt runs prune`
- `gt github import`, `gt github export`, `gt github sync`, `gt github live`
- `gt web`

See [cli/README.md](cli/README.md) for build instructions, command syntax, and
operational details.

## Specification

The normative design lives in [spec/](spec/):

| Document | Contents |
| --- | --- |
| [01_PRODUCT.md](spec/01_PRODUCT.md) | Event model, object types, reducers, sync, and actions engine |
| [02_REFS.md](spec/02_REFS.md) | Ref namespaces, commit format, and validation pipeline |
| [03_RBAC.md](spec/03_RBAC.md) | Roles, permissions, bootstrap trust, ACLs, and identity reducers |
| [04_WORKFLOWS.md](spec/04_WORKFLOWS.md) | Native workflows, backend pipelines, scheduling, run refs, and agent execution |
| [05_PROJECTS_WEBUI.md](spec/05_PROJECTS_WEBUI.md) | Projects web UI, issue-centered project fields, saved views, and templates |
| [06_PULL_REQUEST_MERGE_SEMANTICS.md](spec/06_PULL_REQUEST_MERGE_SEMANTICS.md) | Remote-first pull request merges, leases, and conflict resolution |

## License

[MIT](LICENSE)
