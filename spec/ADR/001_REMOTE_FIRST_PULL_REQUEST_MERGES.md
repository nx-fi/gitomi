# ADR 001: Remote-First Pull Request Merges

Status: Accepted

Date: 2026-05-16

## Context

Gitomi pull requests are modeled as signed Gitomi events, but the code being
reviewed lives in normal Git refs. The web UI runs against a local clone that
may also be used by humans, editor integrations, long-running agents, action
runners, and other Git worktrees.

Updating local `refs/heads/*` from the web UI is therefore unsafe. A local
branch can have unpushed commits, be checked out in a worktree, be in the
middle of a merge or rebase, or have edits that are meaningful only in that
local environment. A browser merge button should not silently change that
state.

GitHub avoids this class of problem because its web merge button operates on a
server-side repository. It computes mergeability from object IDs, creates
temporary merge results, and publishes by moving protected remote refs. Local
clones pull those updates later.

Gitomi needs the same mental model even though it runs locally.

## Decision

Pull request merge operations in Gitomi are remote-first by default.

The web UI and other non-interactive services must not update the user's active
worktree or local `refs/heads/*` branches as their default publish path. They
may create Git objects and temporary worktrees, but branch publication is a
separate ref transaction against the configured remote.

Merge computation is based on immutable snapshots:

- Resolve the pull request base and head to exact object IDs.
- Fetch the configured remote before mergeability checks.
- Prefer remote-tracking base/head refs for web-initiated publication when a
  writable remote exists.
- Compute mergeability with Git object operations such as `merge-tree`.
- Create merge, squash, rebase, or conflict-resolution commits in detached
  temporary worktrees or equivalent temporary indexes.

Publishing is an exact ref transaction:

- A merge into the base branch publishes the result to the remote base branch
  only if that remote branch still matches the expected base object ID.
- A conflict resolution publishes the new commit to the remote head branch only
  if that remote branch still matches the expected head object ID.
- If the expected object ID no longer matches, the operation aborts and the UI
  must refresh before retrying.
- Gitomi records `pull.merged` only after the data-plane branch update has
  succeeded.

Local branches are consumers of the result. After a remote-first merge, the
user may pull, fetch, or fast-forward their local branch with normal Git
commands.

## Conflict Resolution

Resolving conflicts is not the same operation as merging the pull request.

When a pull request cannot merge cleanly, the conflict resolver creates a new
commit on the pull request head branch that incorporates the current base. This
matches the GitHub web conflict editor model. The pull request remains open
after the conflict-resolution commit is published. A later merge operation then
publishes the pull request result to the base branch.

If the head branch is not writable through the configured remote, Gitomi must
either create a new writable head branch and update the pull request metadata,
or refuse web conflict resolution and require the user to resolve the conflict
with local Git commands.

## Local-Only Mode

A repository without a writable remote cannot safely simulate a hosted forge by
mutating local branches implicitly.

Future local-only support may publish merge results to explicit Gitomi
integration refs or require an opt-in local branch update with strong guards:

- the target branch is not checked out in any worktree,
- no merge, rebase, cherry-pick, or bisect operation is active,
- the branch still equals the expected object ID,
- the user explicitly chose local publication for this operation.

This is not the default web UI behavior.

## Consequences

The web UI becomes a coordinator over object creation and leased ref movement,
not an editor of the live checkout.

Action runners and agents can continue to use detached worktrees for execution.
Their existence does not make web merges unsafe because merge publication no
longer depends on the active local branch.

The current implementation has code paths that create results in temporary
worktrees and then update local branch refs. Those paths are legacy relative to
this decision and should be migrated to the remote-first publish model before
being treated as safe for unattended web use.

## Related Spec

See [Pull Request Merge Semantics](../06_PULL_REQUEST_MERGE_SEMANTICS.md) for
the normative merge and conflict-resolution flow.
