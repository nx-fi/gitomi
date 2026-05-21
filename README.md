# Gitomi

**Where your coding agents file issues, open PRs, and review each other — offline, signed, and merged by Git.**

Gitomi is a collaboration and provenance layer for software teams that include
autonomous coding agents. Every issue, pull request, comment, review, label
change, and workflow run is a signed Git commit attributable to a specific
human or agent on a specific device. Agents work in isolated worktrees, file
work through the same surfaces a human does, and replicas merge concurrent
activity deterministically through plain `git fetch` and `git push`.

The result is a single auditable log of *who — human or agent — did what, on
what code, with what authority*, that does not require an online API, a
shared service account, or a hosted forge to function.

## Why Gitomi

If you are running Claude Code, Codex, Aider, or any other coding agent in a
loop, the agent's work-state has nowhere safe to live. Either it writes to
GitHub through a shared token (no per-agent identity, online-only,
rate-limited, every action is a public round-trip) or it writes nowhere and
the context evaporates between runs.

Gitomi gives each agent:

- **Its own signed identity.** Per-agent, per-device signing keys are issued
  through delegated capabilities from a human owner. Every event the agent
  emits — opening an issue, commenting on a PR, applying a label, requesting a
  merge — is attributable and non-repudiable.
- **A native place to file work.** Agents call `gt issue open`,
  `gt pr review`, `gt comment add`, `gt label set`, etc., as ordinary local
  commands. No API token, no network, no rate limit.
- **Offline isolation.** Each pipeline step runs in its own Git worktree under
  a scoped capability grant. Two agents working concurrently on the same
  repository cannot corrupt each other's state.
- **Deterministic multi-agent merge.** Concurrent inbox refs are reduced by
  the same CRDT-style reducers regardless of arrival order, so independent
  agents — and the humans reviewing them — converge on the same view.
- **A proposed-effects approval gate.** Pipelines can request high-impact
  effects (merge, force-push, publish, external write) as *proposed* events
  that a human approves before they are admitted. Routine effects flow
  through.
- **Exportable provenance.** `gt log --provenance` and the attestation
  exporter produce a signed record of which agent — under which delegation,
  on which device, against which commit — produced any given change.

For air-gapped, regulated, or compliance-sensitive teams that cannot use a
hosted forge at all, the same machinery gives you a signed, offline,
Git-transported collaboration log with no agent framing required.

## What Gitomi Is Not

Gitomi is not a replacement for GitHub, Gitea, or Forgejo for *humans serving
humans through a hosted UI*. It is not a code-browsing portal, it is not a
multi-tenant SaaS, and the local web interface is a loopback control panel,
not a public-facing forge. If your only requirement is "host a repo for a few
people to browse," use one of the existing forges — they are mature and
excellent at that job.

Gitomi exists for the case those forges don't address: a fleet of humans and
semi-trusted agents collaborating on the same code, where every action must
be attributable, replayable, and able to happen offline.

## Two-Agent Quick Demo

The fastest way to see the point: drive two different agent CLIs against the
same repository and watch them open, review, and merge a PR without a network
round-trip, then sync and observe the deterministic merge.

```sh
# Initialize a repo with one human owner.
gt init --principal alice --device laptop

# Delegate a signing key to two agents.
gt acl delegate --to agent:claude-code --device laptop-claude --can issue,pr,comment,review
gt acl delegate --to agent:codex      --device laptop-codex  --can issue,pr,comment,review

# Pipeline 1 (Claude Code): pick up the next open issue and open a PR.
gt pipeline run code-change --as agent:claude-code --issue 1

# Pipeline 2 (Codex): review the PR opened by the other agent.
gt pipeline run pr-review --as agent:codex --pr 1

# Show the signed timeline and prove provenance.
gt log --provenance --pr 1
```

When two replicas of this repo sync, the inbox refs merge deterministically
and the resulting view is identical on both sides.

## Agent Surface

Agents interact with Gitomi through three layers:

- **`gt` CLI** — the canonical local surface; every Gitomi operation a human
  can run, an agent can run.
- **MCP server** — `gt mcp serve` exposes `gt issue open`, `gt pr review`,
  `gt comment add`, `gt label set`, `gt pipeline run`, and friends as MCP
  tools so MCP-aware agents call them without shelling out.
- **SDK** — language bindings around the same event-emitting verbs for
  embedded agent harnesses.

All three paths emit the same signed events into the same `refs/gitomi/inbox/<principal>/<device>`
log, so an action taken through the MCP server, the CLI, or the SDK is
indistinguishable downstream.

## Provenance and Attestation

```sh
gt log --provenance                  # signed who-did-what over the whole repo
gt log --provenance --pr 42          # restricted to a PR's effects
gt attest export --pr 42 --out attest.json
```

The attestation export is a signed JSON document binding each effect on a
pull request to an actor principal, a device, the delegation chain that
authorized it, and the source commit it ran against. It is suitable as
evidence for AI-code-provenance compliance requirements.

## Installation

```sh
sh -c '
set -eu
base=$1
tmp="$(mktemp -d /tmp/gitomi-install.XXXXXX)"
trap "rm -rf \"$tmp\"" EXIT
curl -fsSL "$base/install.sh" -o "$tmp/install.sh"
curl -fsSL "$base/install.sh.sha256" -o "$tmp/install.sh.sha256"
cd "$tmp"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c install.sh.sha256
else
  shasum -a 256 -c install.sh.sha256
fi
sh install.sh
' sh 'https://raw.githubusercontent.com/nx-fi/gitomi/main'
gt --help
```

Or build from source:

```sh
cd cli
zig build
./zig-out/bin/gt --help
```

## Sync

Gitomi state is published as Git refs. After a repository is initialized:

```sh
gt sync
```

Sync fetches remote Gitomi refs into a staging namespace, validates
signatures, event chains, genesis compatibility, and event envelopes, then
admits valid history into the local projection. Invalid or diverged inbox
heads are moved to local quarantine refs for inspection.

To join an existing Gitomi repository, clone or add the remote and run
`gt sync` before `gt init`. The remote genesis ref becomes the local trust
anchor.

## Pipelines, Workflows, and Approval Gates

Gitomi's workflow runner is the substrate that executes agent pipelines and
their gates. It is not framed as a CI service: workflows exist primarily so
that *an agent's proposed effects can be deterministically reproduced, gated,
and signed* before they enter the event log.

```sh
gt pipeline list
gt pipeline run code-change --issue 12
gt pipeline run pr-review --pr 7
gt actions workflows
gt actions run --event push --ref HEAD --dry-run
```

Pull-triggered pipelines default to trusted base-side definitions running
against head-side code, with both source OIDs recorded in run metadata.
Pipeline requests and completions are signed Gitomi events; per-step logs
and traces live under `refs/gitomi/runs/*` and can be pruned without losing
the durable result.

For GitHub Actions-compatible workflow files (`.github/workflows/*.yml`),
Gitomi runs them locally through [`nektos/act`](https://github.com/nektos/act).
This is a convenience for teams whose existing CI happens to be expressible
that way; it is not the product.

## Approval Gate

```sh
gt approvals list                    # proposed effects awaiting human review
gt approvals approve <event-id>
gt approvals reject  <event-id>
```

An agent with a restricted delegation cannot, for example, merge a PR
directly. Its merge request is admitted as a *proposed* event that a human
with the appropriate role must approve before the reducer treats it as a
merge. The proposed event itself is signed and durable: rejections leave an
auditable record.

## Local Control Panel

```sh
gt web
```

Gitomi serves a loopback-only control panel at `http://gitomi.localhost:12655/`
for inspecting runs, approvals, the signed timeline, and ref diagnostics. It
is intentionally not a public-facing forge.

## GitHub / GitLab Bridges

Existing project history can be imported, and accepted Gitomi transitions can
be exported or two-way synced back to GitHub or GitLab when you need a
hosted-forge mirror for outside collaborators:

```sh
gt github import --repo OWNER/REPO
gt github export --repo OWNER/REPO --dry-run
gt github sync   --repo OWNER/REPO
gt github live   --repo OWNER/REPO --webhook-url https://example.test/github/webhook --secret-env WEBHOOK_SECRET

gt gitlab import --project GROUP/PROJECT
gt gitlab export --project GROUP/PROJECT --dry-run
gt gitlab sync   --project GROUP/PROJECT
```

GitHub sync uses one canonical delegated bridge inbox per GitHub repository,
`refs/gitomi/inbox/import-bot/github` by default. Any maintainer may run the
bridge: Gitomi grants that maintainer's signing key authority to append
`import-bot/github` events, publishes the maintainer's local inbox, then
pushes the bridge inbox fast-forward-only. Imports preserve GitHub and GitLab
issue / PR / MR numbers as aliases so `#123`, `gh#123`, `gl#123`, and
`github:123` continue to resolve.

## How It Works

Gitomi separates a repository into two planes:

- **Data plane**: ordinary Git branches, tags, trees, and blobs for source code.
- **Control plane**: signed, append-only event commits in
  `refs/gitomi/inbox/<principal>/<device>`.

The current view of issues, pull requests, projects, milestones, comments,
runs, identities, and ACLs is derived from those events by deterministic
reducers. The local SQLite index in `.git/gitomi/index.sqlite` is a
disposable cache and can be rebuilt from Git refs.

That same shape is why concurrent agents and humans can collaborate without a
coordinator: their effects are independent appends to per-actor refs and
converge under the reducers.

## Requirements

- Git
- Zig, for building the `gt` CLI
- Git commit signing configured for each actor/device
- Optional: [`nektos/act`](https://github.com/nektos/act) for running
  GitHub Actions-compatible workflow files locally
- Optional: GitHub CLI credentials for GitHub import/export and live sync
- Optional: GitLab API token for GitLab import/export/sync

## CLI Reference

- `gt init`, `gt status`, `gt sync`, `gt fsck`, `gt refs`
- `gt acl ...`, `gt approvals ...`
- `gt issue ...`, `gt pr ...`, `gt comment ...`, `gt label ...`, `gt review ...`
- `gt project ...`, `gt milestone ...`
- `gt pipeline ...`, `gt actions ...`, `gt runs prune`
- `gt log --provenance`, `gt attest export`
- `gt mcp serve`
- `gt github import|export|sync|live`
- `gt gitlab import|export|sync`
- `gt web`

See [cli/README.md](cli/README.md) for build instructions, command syntax, and
operational details.

## Specification

The normative design lives in [spec/](spec/):

| Document | Contents |
| --- | --- |
| [01_PRODUCT.md](spec/01_PRODUCT.md) | Event model, object types, reducers, sync, and runner overview |
| [02_REFS.md](spec/02_REFS.md) | Ref namespaces, commit format, and validation pipeline |
| [03_RBAC.md](spec/03_RBAC.md) | Roles, permissions, bootstrap trust, ACLs, delegation, and identity reducers |
| [04_WORKFLOWS.md](spec/04_WORKFLOWS.md) | Workflow substrate for pipelines, gates, scheduling, and run refs |
| [05_PROJECTS_WEBUI.md](spec/05_PROJECTS_WEBUI.md) | Local control-panel views: projects, runs, approvals, timeline |
| [06_PULL_REQUEST_MERGE_SEMANTICS.md](spec/06_PULL_REQUEST_MERGE_SEMANTICS.md) | Remote-first pull request merges, leases, and conflict resolution |
| [07_AGENT_PIPELINES.md](spec/07_AGENT_PIPELINES.md) | Agent adapters, pipeline graphs, isolated worktrees, and signed effects |

## License

[MIT](LICENSE)
