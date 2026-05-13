# Gitomi Specification v1.0

## 1. Introduction

Gitomi is a local-first, Git-native forge that layers issues, pull requests, ACLs, and workflow execution over a standard Git repository.

Gitomi separates:

*   the **Data Plane** for ordinary source code refs; and
*   the **Control Plane** for signed social and automation events.

This document defines the normative rules required for a compliant Gitomi client, daemon, or runner.

### 1.1. Conformance Keywords

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119.

## 2. Architecture Overview

Gitomi MUST preserve standard Git behavior for normal code collaboration.

*   **Data Plane**: Standard Git branches, tags, trees, and blobs. Gitomi MUST NOT write issue or workflow state into the working tree.
*   **Control Plane**: A distributed event DAG stored in specialized Git refs. Event commits are signed, append-only, and reduced into current state by deterministic reducers.

Gitomi v1 deliberately avoids a single shared writable control-plane branch. The authoritative log is the union of per-device append-only refs under `refs/gitomi/inbox/*`. This design avoids shared-ref contention, tolerates offline work, and keeps the replication protocol plain Git.

Under stock Git, ref names are not an enforceable authorization boundary. `refs/gitomi/inbox/*` partitions replication state, but trust MUST be derived from signed-event validation and reducer admission rules rather than from assumptions about who was able to update a ref on a remote.

## 3. Storage Layout

### 3.1. Ref Namespaces

Implementations MUST manage the following ref namespaces:

*   `refs/gitomi/inbox/<principal-id>/<device-id>`: The authoritative append-only event logs. `<principal-id>` and `<device-id>` MUST be ref-safe path segments, typically lowercase hex or base32 encodings of the actor principal and device identifiers. This path is a naming convention, not a server-enforced ownership boundary.
*   `refs/gitomi/main`: OPTIONAL synthesized merge ref for inspection, bootstrap, or checkpointing. It MUST NOT be treated as the sole source of truth.
*   `refs/gitomi/snapshots/<snapshot-id>`: OPTIONAL additive checkpoints containing projection manifests and compact bootstrap state.
*   `refs/gitomi/runs/<runner-id>/<run-id>`: OPTIONAL workflow run streams for incremental logs, traces, or artifacts.

### 3.2. Empty-Tree Rule

All commits written to `refs/gitomi/inbox/*` and `refs/gitomi/main` MUST reference the repository's empty tree object.

Commits written to `refs/gitomi/snapshots/*` or `refs/gitomi/runs/*` MAY reference non-empty trees or blobs when storing manifests, logs, or compacted state.

### 3.3. Local Device State

Implementations MUST maintain a local cache outside version control. The RECOMMENDED location is `.git/gitomi/`.

The following local paths are RECOMMENDED:

*   `.git/gitomi/config.toml`: Repo-local Gitomi configuration.
*   `.git/gitomi/index.sqlite`: Materialized state for issues, pull requests, comments, ACLs, and workflow status.
*   `.git/gitomi/cursors.sqlite`: Per-ref replay cursors and snapshot metadata.

The local cache is disposable. A compliant implementation MUST be able to rebuild it from valid Gitomi refs alone.

## 4. Event Model

The authoritative source of truth is the set of all valid commits reachable from `refs/gitomi/inbox/*`.

Valid snapshot and run refs are auxiliary bootstrap or trace data. They MAY accelerate reconstruction, but they MUST NOT override accepted inbox events.

### 4.1. Event Commit Format

Every event commit in `refs/gitomi/inbox/*` MUST satisfy the following:

*   **Tree**: MUST be the repository's empty tree object.
*   **Signature**: MUST use native Git commit signing.
*   **Subject line**: SHOULD be a short human-readable summary.
*   **Body**: MUST contain exactly one UTF-8 JSON object.
*   **First parent**: MUST be the previous commit on the same inbox ref, except for the root event on that ref.
*   **Additional parents**: SHOULD encode the latest Gitomi commits known to the writer when the event was created. These extra parents define cross-device causal knowledge.

Reducers MUST tolerate missing additional parents. When no cross-device parent exists, events from different inbox refs are treated as concurrent.

### 4.2. Event Envelope

Every event body MUST conform to the following envelope:

```json
{
  "$schema": "urn:gitomi:event:v1",
  "repo_id": "string, UUIDv7",
  "event_uuid": "string, UUIDv7",
  "event_type": "string",
  "object": {
    "kind": "string (issue | pull | comment | acl | identity | action)",
    "id": "string, UUIDv7 of the logical object"
  },
  "idempotency_key": "string, UUIDv7",
  "actor": {
    "principal": "string",
    "device": "string"
  },
  "seq": "integer, monotonic per actor/device",
  "occurred_at": "string, RFC 3339 timestamp in UTC",
  "legacy": {
    "github_issue_number": "integer (OPTIONAL)",
    "github_pull_number": "integer (OPTIONAL)"
  },
  "payload": {}
}
```

The `(actor.principal, actor.device, seq)` tuple MUST be unique within a repository.

### 4.3. Object Identifiers and Human References

Logical object identifiers MUST be UUIDv7.

Gitomi v1 does not require a native repo-wide integer allocator. The canonical human reference form is a unique UUID prefix:

*   `#<uuid-prefix>` for issues and pull requests
*   minimum prefix length: 7 lowercase hex characters
*   implementations MUST extend the displayed prefix when 7 characters are ambiguous within the local projection

Imported GitHub numbers MAY be preserved as secondary aliases in `legacy.*`, but native Gitomi objects MUST remain addressable without allocating sequential integers.

### 4.4. Idempotency

Clients MUST generate an `idempotency_key` for every logical action.

Reducers MUST suppress duplicate effects when the same logical action is replayed or retried. At minimum, duplicate `idempotency_key` values for the same `repo_id` MUST be ignored after the first accepted event.

### 4.5. Minimum v1 Event Families

Compliant implementations MUST understand the following event families:

*   `issue.opened`, `issue.title_set`, `issue.body_set`, `issue.state_set`, `issue.label_added`, `issue.label_removed`, `issue.assignee_added`, `issue.assignee_removed`
*   `pull.opened`, `pull.title_set`, `pull.body_set`, `pull.state_set`, `pull.base_set`, `pull.head_set`, `pull.label_added`, `pull.label_removed`, `pull.assignee_added`, `pull.assignee_removed`, `pull.reviewer_added`, `pull.reviewer_removed`, `pull.merged`
*   `comment.added`, `comment.body_set`, `comment.redacted`
*   `acl.role_granted`, `acl.role_revoked`
*   `identity.device_added`, `identity.device_revoked`
*   `action.run_requested`, `action.run_completed`

Implementations MAY support additional event types. Unknown event types MUST be preserved and SHOULD be ignored unless the implementation explicitly understands them.

### 4.6. Minimum Payload Requirements

The following payload members are REQUIRED for interoperable v1 implementations:

*   `issue.opened`: `title`; OPTIONAL `body`, `labels`, `assignees`
*   `issue.title_set`: `title`
*   `issue.body_set`: `body`
*   `issue.state_set`: `state`
*   `issue.label_added` / `issue.label_removed`: `label`
*   `issue.assignee_added` / `issue.assignee_removed`: `assignee`
*   `pull.opened`: `title`, `base_ref`, `head_ref`; OPTIONAL `body`, `draft`
*   `pull.title_set`: `title`
*   `pull.body_set`: `body`
*   `pull.state_set`: `state`
*   `pull.base_set`: `base_ref`
*   `pull.head_set`: `head_ref`
*   `pull.label_added` / `pull.label_removed`: `label`
*   `pull.assignee_added` / `pull.assignee_removed`: `assignee`
*   `pull.reviewer_added` / `pull.reviewer_removed`: `reviewer`
*   `pull.merged`: `merge_oid` or `target_oid`
*   `comment.added`: `parent_kind`, `parent_id`, `body`
*   `comment.body_set`: `body`
*   `comment.redacted`: OPTIONAL `reason`
*   `acl.role_granted` / `acl.role_revoked`: `principal`, `role`
*   `identity.device_added` / `identity.device_revoked`: `principal`, `device`
*   `action.run_requested`: `workflow`, `target_ref` or `target_oid`
*   `action.run_completed`: `run_id`, `conclusion`, `target_ref` or `target_oid`

## 5. Identity, Signing, and Authorization

### 5.1. Signing Backends

Events MUST be signed using native Git commit signing.

Implementations MUST support SSH signing (`gpg.format=ssh`) and verification against an `allowedSignersFile`. OpenPGP or Sigstore-based signing MAY be supported as additional backends.

### 5.2. Actor and Device Model

An actor principal is a stable human or bot identity. A device is a concrete signing endpoint for that principal.

The event payload identity and the commit signature MUST agree:

*   the signing key MUST map to `actor.principal`
*   the active device record MUST authorize `actor.device`

`identity.device_added` and `identity.device_revoked` events define the valid device set for each principal.

### 5.3. ACL Model

Authorization is event-sourced.

Compliant implementations MUST derive effective permissions by replaying:

*   `acl.role_granted`
*   `acl.role_revoked`
*   `identity.device_added`
*   `identity.device_revoked`

Permissions are role-based. The precise role-to-permission matrix is implementation-defined, but a repository MUST apply the same matrix consistently for all replicas.

### 5.4. Validation Pipeline

When ingesting an event, implementations MUST:

1.  parse and validate the JSON envelope;
2.  verify the Git commit signature;
3.  verify that the signature maps to `actor.principal` and an authorized device;
4.  evaluate authorization against the event's causal frontier; and
5.  either accept the event into the projection or reject it from the projection.

Authorization MUST be evaluated from causal ancestry, not from wall-clock timestamps alone. `occurred_at` is for ordering and presentation, not for bypassing revocations or grants.

Invalid, unverifiable, or unauthorized events MUST NOT affect the materialized projection.

## 6. Reducers and Conflict Resolution

Clients materialize current state by reducing the valid event DAG. The log acts as an operation-based CRDT.

### 6.1. General Rules

Reducers MUST apply the following rules:

*   Causal ancestry takes precedence over presentation order.
*   Concurrent events MUST be resolved by the object-specific CRDT rules below.
*   `occurred_at` is the primary LWW timestamp for concurrent scalar updates.
*   Ties in LWW resolution MUST be broken deterministically by `(actor.principal, event_uuid)`.
*   All accepted events MUST remain auditable even when their current visible effect is superseded.

### 6.2. Issues

An issue is created by `issue.opened`.

The following issue fields MUST be modeled as last-writer-wins registers:

*   `title`
*   `body`
*   `state` (`open` or `closed`)
*   implementation-defined scalar metadata such as `priority` or `milestone`

The following issue collections MUST be modeled as Observed-Remove Sets:

*   labels
*   assignees

Reducers MUST preserve all accepted events in the issue timeline, even when the visible projection only shows the latest scalar values.

### 6.3. Pull Requests

A pull request is created by `pull.opened`.

The following pull-request fields MUST be modeled as last-writer-wins registers:

*   `title`
*   `body`
*   `base_ref`
*   `head_ref`
*   `state` (`open`, `closed`, or `merged`)
*   implementation-defined scalar metadata such as `draft`

The following pull-request collections MUST be modeled as Observed-Remove Sets:

*   labels
*   assignees
*   reviewers

`pull.merged` MUST record enough payload to identify the resulting merge outcome, typically a merge commit OID or a fast-forward target OID.

### 6.4. Comments

Comments are append-only event histories attached to a stable comment UUID.

*   `comment.added` creates the comment object and attaches it to an issue or pull request.
*   `comment.body_set` updates the current rendered body using LWW semantics on the comment UUID.
*   `comment.redacted` marks the comment as semantically removed while preserving audit history.

Implementations MAY retain prior comment bodies as explicit history, but the current visible body MUST be derived from the latest accepted `comment.body_set` or the initial `comment.added` payload.

### 6.5. Derived References From Code Commits

Implementations MUST parse Data Plane commit messages to derive links from code to Gitomi objects.

*   **Syntax**: `#<uuid-prefix>`
*   **Resolution**: the prefix MUST resolve against the local issue and pull index
*   **Ambiguity**: if multiple objects share the prefix, the implementation SHOULD prompt for a longer prefix or ignore the reference

These links are derived projection data. They MUST NOT be written back as explicit control-plane events.

### 6.6. Cache Rebuild

`.git/gitomi/index.sqlite` and `.git/gitomi/cursors.sqlite` are disposable caches.

If missing or corrupted, a compliant implementation MUST rebuild state by:

1.  loading the newest valid snapshot, if any; and
2.  replaying all valid events not covered by that snapshot.

## 7. Sync and History Rules

### 7.1. Transport

Synchronization MUST use standard Git transport and refs. Implementations MUST be able to fetch and push Gitomi refs over normal Git protocol v2 transports such as SSH, HTTPS, or bundles.

### 7.2. Append-Only Rule

Shared inbox refs are immutable after publication.

*   An implementation MUST NOT force-push or rewrite `refs/gitomi/inbox/*` that may already be visible to another replica.
*   A device MAY rewrite its own unpublished local inbox ref before first publication.
*   Once published, corrections MUST be expressed as new events, not history edits.

### 7.3. Snapshots

Snapshots are additive bootstrap aids, not replacements for the authoritative event history.

A snapshot manifest SHOULD record:

*   the snapshot schema version;
*   the set of inbox heads covered by the snapshot;
*   the projected object state included in the snapshot; and
*   any preserved legacy alias mappings.

Snapshots MAY accelerate clone, bootstrap, or cache rebuild, but v1 does not define destructive compaction of shared inbox history. Repository-wide history rewriting is out of scope for this version.

## 8. Actions Engine

### 8.1. Workflow Definitions

Workflows MUST be read from `.github/workflows/*.yml` or `.github/workflows/*.yaml`.

Gitomi SHOULD preserve GitHub Actions syntax compatibility for workflow files.

### 8.2. Scheduler

The scheduler MUST observe both:

*   Data Plane events such as branch updates; and
*   Control Plane events such as `issue.*`, `pull.*`, and `action.run_requested`

When an event matches a workflow trigger, the scheduler MUST construct a GitHub-like event payload and invoke the execution core against the referenced code state.

### 8.3. Execution Core

Implementations SHOULD use `nektos/act` or a compatible derivative as the local execution core.

### 8.4. Run Storage and Results

Workflow execution results MUST be summarized by a signed `action.run_completed` event in an inbox ref.

Implementations MAY additionally stream incremental logs, traces, or artifacts into `refs/gitomi/runs/<runner-id>/<run-id>` or external object storage.

When external storage is used, the final event payload MUST contain a stable content reference such as a Git OID or SHA-256 digest.

## 9. Migration Compatibility

### 9.1. GitHub Import

When importing from GitHub:

1.  each issue or pull request MUST receive a new UUIDv7;
2.  the original GitHub number MUST be preserved in `legacy.github_issue_number` or `legacy.github_pull_number`;
3.  historical labels, comments, and state transitions SHOULD be backfilled as Gitomi events; and
4.  imported events SHOULD be signed by a clearly identified `import-bot` principal.

Imported numeric identifiers are compatibility metadata, not the native identity model.

### 9.2. GitHub Export

When exporting to GitHub:

1.  Data Plane refs are pushed with standard Git;
2.  Gitomi UUIDs MUST be mapped to GitHub-assigned numeric identifiers for the target repository; and
3.  accepted Gitomi state transitions SHOULD be replayed through the GitHub API.
