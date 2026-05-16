# Pull Request Merge Semantics

This document specifies the Git behavior behind Gitomi pull request merge and
conflict-resolution operations. ADR 001 records the architectural decision:
[Remote-First Pull Request Merges](ADR/001_REMOTE_FIRST_PULL_REQUEST_MERGES.md).

## Model

Gitomi pull request metadata is stored as signed events. The base and head are
Git refs or ref-like names that resolve to ordinary Git commits.

The merge UI must operate on object IDs, not on mutable checkout state. A page
render or API response that offers a merge operation must include, directly or
implicitly, the exact base object ID and head object ID used to calculate the
displayed result.

## Mergeability

To determine whether a pull request is mergeable:

1. Fetch the configured remote when remote publication is available.
2. Resolve the base and head refs to commits.
3. Compute the merge result from those commits using Git object operations such
   as `git merge-tree --write-tree`.
4. Treat conflicts as a property of that exact `(base_oid, head_oid)` pair.

The active worktree, local index, local branch checkout, and local dirty state
must not affect mergeability.

## Merge Publication

Merging a pull request publishes a result commit to the base branch.

The default publish target is the configured remote branch. The local
`refs/heads/*` branch is not updated by the web UI.

The merge operation must:

1. Resolve the base branch to `expected_base_oid`.
2. Resolve the pull request head to `expected_head_oid`.
3. Create the requested result from those exact commits:
   - merge commit: a merge commit with `expected_base_oid` and
     `expected_head_oid` as parents,
   - squash merge: one new commit on top of `expected_base_oid`,
   - rebase merge: rewritten head commits on top of `expected_base_oid`.
4. Verify that the result is a fast-forward from `expected_base_oid` unless the
   selected strategy explicitly requires another policy.
5. Publish to the remote base branch only if the remote branch still equals
   `expected_base_oid`.
6. Record `pull.merged` only after the remote branch update succeeds.

If any expected object ID no longer matches, Gitomi must abort the operation and
ask the user to refresh. It must not opportunistically recompute and publish a
different merge than the one the user confirmed.

## Conflict Resolution

Conflict resolution updates the pull request head, not the base branch.

The conflict resolver must:

1. Resolve the base and head to `expected_base_oid` and `expected_head_oid`.
2. Prepare a detached temporary worktree or equivalent temporary index at the
   head commit.
3. Merge the base commit into that temporary state without committing.
4. Apply the user-submitted resolutions.
5. Verify that no unmerged paths or conflict markers remain for editable files.
6. Commit the resolution.
7. Publish the new commit to the remote head branch only if the remote head
   still equals `expected_head_oid`.

After conflict resolution, the pull request remains open. A separate merge
operation is still required to publish the pull request to the base branch.

If the head ref cannot be safely updated on the remote, Gitomi must create a
new writable head branch and update pull request metadata, or refuse web
conflict resolution.

## Local-Only Repositories

When no writable remote is configured, the web UI must not silently update local
branches. Acceptable future behavior is one of:

- publish result commits to explicit Gitomi integration refs,
- require the user to perform the final local branch update with Git,
- offer an explicit local-publish mode guarded by ADR 001's local-only checks.

## Events

`pull.merged` is an audit event for a completed data-plane update. It is not a
substitute for moving the base branch.

The event payload should record:

- `merge_oid` for a merge commit result,
- `target_oid` for a squash or rebase result,
- the base/head object IDs that were confirmed,
- the remote/ref that was updated.
