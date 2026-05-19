# Gitomi Specification v1.0

## 1. Introduction

Gitomi is a local-first, Git-native forge that layers issues, pull requests,
projects, milestones, notifications, ACLs, and workflow execution over a
standard Git repository.

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

### 2.1. Security Model Limitations

Gitomi RBAC protects the Control Plane projection. It determines which signed
events affect issues, pull requests, projects, milestones, comments, workflow
requests, ACL state, and identity state.

Gitomi RBAC does not, by itself, provide all repository security boundaries:

*   It does not make Git ref names an ownership boundary. A remote may receive a
    write to any visible ref; compliant replicas MUST still validate signatures,
    actor identity, causal ancestry, and RBAC before admitting effects.
*   It does not revoke bytes already distributed through Git objects, packs,
    bundles, working trees, or another replica's cache.
*   It does not hide Data Plane refs or blobs from a party that can fetch them
    through the underlying Git transport.
*   It does not protect auxiliary run or snapshot refs as authoritative state.
    Those refs are optional caches or diagnostics and MUST be ignored when they
    conflict with accepted inbox events.

Operators that require confidentiality or server-enforced read isolation MUST
combine Gitomi with hosting policy, transport authorization, narrow fetch
refspecs, or encryption outside the v1 event format.

## 3. Storage Layout

### 3.1. Ref Namespaces

Implementations MUST manage the following ref namespaces:

*   `refs/gitomi/genesis`: The signed repository bootstrap manifest that pins the initial `repo_id`, owner, device, and device signing key.
*   `refs/gitomi/inbox/<principal-id>/<device-id>`: The authoritative append-only event logs. `<principal-id>` and `<device-id>` MUST be ref-safe path segments, typically lowercase hex or base32 encodings of the actor principal and device identifiers. This path is a naming convention, not a server-enforced ownership boundary.
*   `refs/gitomi/quarantine/<remote>/inbox/...`: Local diagnostic refs for fetched inbox heads that failed chain or signature admission. These refs are not authoritative.
*   `refs/gitomi/main`: OPTIONAL synthesized merge ref for inspection, bootstrap, or checkpointing. It MUST NOT be treated as the sole source of truth.
*   `refs/gitomi/snapshots/<snapshot-id>`: OPTIONAL additive checkpoints containing projection manifests and compact bootstrap state.
*   `refs/gitomi/runs/<runner-id>/<run-id>`: OPTIONAL workflow run streams for incremental logs, traces, or artifacts. These refs are retention-managed diagnostics, not authoritative state.

### 3.2. Empty-Tree Rule

All commits written to `refs/gitomi/inbox/*` and `refs/gitomi/main` MUST reference the repository's empty tree object.

Commits written to `refs/gitomi/genesis`, `refs/gitomi/snapshots/*`, or
`refs/gitomi/runs/*` MAY reference non-empty trees or blobs when storing
manifests, logs, or compacted state.

### 3.3. Local Device State

Implementations MUST maintain a local cache outside version control. The RECOMMENDED location is `.git/gitomi/`.

The following local paths are RECOMMENDED:

*   `.git/gitomi/config.toml`: Repo-local Gitomi configuration.
*   `.git/gitomi/index.sqlite`: Materialized state for issues, pull requests,
    projects, milestones, comments, ACLs, and workflow status.
*   `.git/gitomi/cursors.sqlite`: Per-ref replay cursors and snapshot metadata.

The local cache is disposable. A compliant implementation MUST be able to rebuild it from valid Gitomi refs alone.

## 4. Event Model

The bootstrap source of trust is the signed manifest at `refs/gitomi/genesis`.
The authoritative event source of truth after bootstrap is the set of all valid
commits reachable from `refs/gitomi/inbox/*`.

Valid snapshot and run refs are auxiliary bootstrap or trace data. They MAY accelerate reconstruction, but they MUST NOT override accepted inbox events.

### 4.1. Event Commit Format

Every event commit in `refs/gitomi/inbox/*` MUST satisfy the following:

*   **Tree**: MUST be the repository's empty tree object.
*   **Signature**: MUST use native Git commit signing.
*   **Subject line**: SHOULD be a short human-readable summary.
*   **Body**: MUST contain exactly one UTF-8 JSON object.
*   **First parent**: MUST be the previous commit on the same inbox ref, or the
    genesis commit for the root event on that ref.
*   **Additional parents**: SHOULD encode a bounded set of latest Gitomi
    commits known to the writer when the event was created. These extra parents
    define cross-device causal knowledge.
*   **Event hash**: The event's authoritative identity is the signed commit OID.
*   **Parent hashes**: The event envelope MUST record the first-parent and additional-parent event hashes.

Reducers MUST tolerate missing additional parents. When no cross-device parent exists, or when observed heads are omitted because the bounded parent set is full, events from different inbox refs are treated as concurrent unless an object-specific rule is satisfied by explicit payload fields.

### 4.2. Event Envelope

Every event body MUST conform to the following envelope:

```json
{
  "$schema": "urn:gitomi:event:v1",
  "repo_id": "string, UUIDv7",
  "event_uuid": "string, UUIDv7",
  "event_type": "string",
  "object": {
    "kind": "string (issue | pull | comment | acl | identity | action | notification)",
    "id": "string, UUIDv7 of the logical object"
  },
  "idempotency_key": "string, UUIDv7",
  "actor": {
    "principal": "string",
    "device": "string"
  },
  "parent_hashes": {
    "log": "string, previous commit OID or empty string",
    "anchor": "string, genesis OID for inbox root or empty string",
    "causal": ["string, observed commit OID, bounded by v1 parent policy"],
    "related": ["string, domain-related commit OID"]
  },
  "seq": "integer, strictly increasing per actor/device; gaps allowed",
  "occurred_at": "string, RFC 3339 timestamp in UTC",
  "legacy": {
    "github_issue_number": "integer (OPTIONAL)",
    "github_pull_number": "integer (OPTIONAL)"
  },
  "payload": {}
}
```

The `(actor.principal, actor.device, seq)` tuple MUST be unique within a
repository. `event_uuid` is user generated and MUST NOT be used as the
authoritative event identity, security tie-breaker, or collection add tag. Use
the derived event hash for those purposes.

### 4.3. Object Identifiers and Human References

Issue, pull request, project, milestone, comment, action run, and notification
event identifiers MUST be UUIDv7. ACL and identity events target stable system
objects rather than user-facing content objects:

*   `acl.*`: `object.id` MUST be `acl:<principal>`, where `<principal>` is the
    canonical target principal in `payload.principal`.
*   `identity.*`: `object.id` MUST be `identity:<principal>:<device>`, where
    the components match `payload.principal` and `payload.device`.
*   `notification.*`: `object.id` MUST be a UUIDv7 notification event id. The
    target issue or pull request is carried in `payload.target_kind` and
    `payload.target_id` for subscription events.
*   `action.run_requested` and `action.run_completed`: `object.id` MUST be the
    run UUID. For `action.run_completed`, `payload.run_id` MUST equal
    `object.id`.

Gitomi v1 does not require a native repo-wide integer allocator. The canonical
human reference form for issue, pull, and comment UUIDs is a unique SHA-256
prefix derived from the UUID:

*   `#<object-ref>` for issues in issue contexts
*   `pr:<object-ref>` for pull requests outside an explicit pull context
*   `comment:<comment-ref>` or `~<comment-ref>` for comments
*   `project:<uuid-prefix>` or `@<slug>` for projects
*   `milestone:<uuid-prefix>` or `^<slug>` for milestones
*   issue, pull, and comment refs are lowercase hex prefixes of `sha256(object.id)`
*   minimum issue/pull/comment ref length: 7 lowercase hex characters
*   implementations MUST extend the displayed prefix when 7 characters are ambiguous within the local projection

Project and milestone slugs are display aliases, not Git ref names and not
security identifiers. They MUST be ref-safe path segments as defined by the ref
format specification, generated from the human name by lowercasing, replacing
disallowed characters with hyphens, and appending a deterministic disambiguator
when required. A kanban column reference is written as
`@<project-slug>/<column-slug>` when both sides have slugs; payloads MUST still
carry the human project and column names used for display.

Imported GitHub numbers MAY be preserved as secondary aliases in `legacy.*`, but native Gitomi objects MUST remain addressable without allocating sequential integers.

### 4.4. Idempotency

Clients MUST generate an `idempotency_key` for every logical action.

Reducers MUST suppress duplicate effects when the same logical action is replayed or retried. At minimum, duplicate `idempotency_key` values for the same `repo_id` MUST be ignored after the first accepted event.

Suppressed duplicate idempotency keys MUST NOT change projections. They SHOULD
remain inspectable as rejected domain events when the implementation can
preserve them without admitting malformed history.

### 4.5. Minimum v1 Event Families

Compliant implementations MUST understand the following event families:

*   `issue.opened`, `issue.updated`, `issue.title_set`, `issue.body_set`, `issue.state_set`, `issue.priority_set`, `issue.status_set`, `issue.label_added`, `issue.label_removed`, `issue.assignee_added`, `issue.assignee_removed`, `issue.milestone_set`, `issue.project_added`, `issue.project_removed`
*   `issue.reaction_added`, `issue.reaction_removed`
*   `pull.opened`, `pull.updated`, `pull.title_set`, `pull.body_set`, `pull.state_set`, `pull.base_set`, `pull.head_set`, `pull.label_added`, `pull.label_removed`, `pull.assignee_added`, `pull.assignee_removed`, `pull.reviewer_added`, `pull.reviewer_removed`, `pull.merged`
*   `pull.reaction_added`, `pull.reaction_removed`
*   `project.created`, `project.updated`, `project.column_added`, `project.column_removed`
*   `milestone.created`, `milestone.updated`, `milestone.state_set`
*   `comment.added`, `comment.body_set`, `comment.redacted`, `comment.reaction_added`, `comment.reaction_removed`
*   `acl.role_granted`, `acl.role_revoked`, `acl.delegation_granted`, `acl.delegation_revoked`
*   `identity.device_added`, `identity.device_revoked`
*   `team.created`, `team.updated`, `team.member_added`, `team.member_removed`
*   `action.run_requested`, `action.run_completed`
*   `notification.subscribed`, `notification.unsubscribed`, `notification.read`, `notification.read_all`

Implementations MAY support additional event types. Unknown event types MUST be preserved and SHOULD be ignored unless the implementation explicitly understands them.

### 4.6. Minimum Payload Requirements

The following payload members are REQUIRED for interoperable v1 implementations:

*   `issue.opened`: `title`; OPTIONAL `body`, `labels`, `assignees`, `milestone`, `priority`, `status`, `projects`
*   `issue.updated`: OPTIONAL `title`, `body`, `state`, `milestone`, `priority`, `status`, `projects`, `labels_added`, `labels_removed`, `assignees_added`, `assignees_removed`; at least one field MUST be present
*   `issue.title_set`: `title`
*   `issue.body_set`: `body`
*   `issue.state_set`: `state`
*   `issue.priority_set`: `priority`
*   `issue.status_set`: `status`
*   `issue.label_added` / `issue.label_removed`: `label`
*   `issue.assignee_added` / `issue.assignee_removed`: `assignee`
*   `issue.milestone_set`: `milestone`; OPTIONAL `milestone_ref`. An empty `milestone` clears the assignment.
*   `issue.project_added` / `issue.project_removed`: `project`, `column`; OPTIONAL `project_ref`, `column_ref`
*   `issue.reaction_added` / `issue.reaction_removed`: `emoji`; for removal, OPTIONAL `add_hashes`
*   `pull.opened`: `title`, `base_ref`, `head_ref`; OPTIONAL `body`, `draft`
*   `pull.updated`: OPTIONAL `title`, `body`, `state`, `base_ref`, `head_ref`, `labels_added`, `labels_removed`, `assignees_added`, `assignees_removed`, `reviewers_added`, `reviewers_removed`; at least one field MUST be present
*   `pull.title_set`: `title`
*   `pull.body_set`: `body`
*   `pull.state_set`: `state` (`open` or `closed`)
*   `pull.base_set`: `base_ref`
*   `pull.head_set`: `head_ref`
*   `pull.label_added` / `pull.label_removed`: `label`
*   `pull.assignee_added` / `pull.assignee_removed`: `assignee`
*   `pull.reviewer_added` / `pull.reviewer_removed`: `reviewer`
*   `pull.merged`: `merge_oid` or `target_oid`
*   `pull.reaction_added` / `pull.reaction_removed`: `emoji`; for removal, OPTIONAL `add_hashes`
*   `project.created`: `name`; OPTIONAL `description`, `slug`, `columns`
*   `project.updated`: OPTIONAL `name`, `description`, `state`, `status`, `priority`, `start_at`, `end_at`, `leads_added`, `leads_removed`, `members_added`, `members_removed`, `labels_added`, `labels_removed`, `milestones_added`, `milestones_removed`, `update_health`, `update_body`; `status` MUST be one of `Backlog`, `Planned`, `In Progress`, `Completed`, or `Canceled`; `priority` MUST be one of `P0`, `P1`, `P2`, or `P3`; `update_health` MUST be one of `on_track`, `at_risk`, or `off_track`; at least one field MUST be present
*   `project.column_added` / `project.column_removed`: `column`; OPTIONAL `column_ref`
*   `milestone.created`: `title`; OPTIONAL `description`, `slug`, `due_at`, `state`
*   `milestone.updated`: OPTIONAL `title`, `description`, `due_at`, `state`; at least one field MUST be present
*   `milestone.state_set`: `state` (`open` or `closed`)
*   `comment.added`: `parent_kind`, `parent_id`, `body`; OPTIONAL `reply_parent_id`, `reply_parent_hash`
*   `comment.body_set`: `body`
*   `comment.redacted`: OPTIONAL `reason`
*   `comment.reaction_added` / `comment.reaction_removed`: `emoji`; for removal, OPTIONAL `add_hashes`
*   `acl.role_granted` / `acl.role_revoked`: `principal`, `role`
*   `acl.delegation_granted`: `principal`, `device`, `capability`, `scope`, `signing_key.public_key`, `signing_key.fingerprint`
*   `acl.delegation_revoked`: `principal`, `device`, `capability`, `scope`
*   `identity.device_added`: `principal`, `device`, `signing_key.public_key`, `signing_key.fingerprint`
*   `identity.device_revoked`: `principal`, `device`
*   `team.created`: `slug`; OPTIONAL `name`, `description`
*   `team.updated`: OPTIONAL `name`, `description`; at least one field MUST be present
*   `team.member_added` / `team.member_removed`: `slug`, `principal`
*   `action.run_requested`: `workflow`, `target_ref` or `target_oid`; OPTIONAL `event_name`, `gitomi_event_type`
*   `action.run_completed`: `run_id`, `conclusion`, `target_ref` or `target_oid`; OPTIONAL `workflow`, `event_name`
*   `notification.subscribed` / `notification.unsubscribed`: `principal`, `target_kind` (`issue` or `pull`), `target_id`; OPTIONAL `reason`
*   `notification.read`: `principal`, `event_hash`
*   `notification.read_all`: `principal`

### 4.7. Notification Product Model

Gitomi notifications are a pub/sub projection over the accepted Control Plane
event stream. Subscriptions and read markers are themselves signed events, so a
replica can rebuild a user's inbox from Gitomi refs without a central server.

The canonical subscription target in v1 is an issue or pull request. Explicit
subscribe and unsubscribe operations are represented by `notification.subscribed`
and `notification.unsubscribed` events. A subscription event MUST target an
accepted issue or pull request by `payload.target_kind` and `payload.target_id`.
Subscription events for missing targets MUST be domain-rejected with reason
`object_not_created`.

Reducers SHALL also derive subscriptions as part of normal issue and pull
request event processing:

*   the actor that opens an issue or pull request is subscribed as the author;
*   principals assigned to an issue or pull request are subscribed as assignees;
*   principals requested as pull request reviewers are subscribed as reviewers;
*   the actor that comments on an issue or pull request is subscribed as a commenter; and
*   principals mentioned as `@<principal>` in an issue or pull request comment body are subscribed as mentions.

When an accepted issue, pull request, or attached comment event occurs, the
notification reducer SHALL publish an inbox item to every active subscriber of
that target except the event actor. The inbox item records the subscriber,
source event hash, target kind, target id, source event type, source actor,
timestamp, and subscription reason. Implementations MAY add richer display
metadata in local indexes, but the event hash and target identity are the
portable notification identity.

Read state is event-sourced. `notification.read` marks one inbox item read for
`payload.principal` by source `payload.event_hash`. `notification.read_all`
marks all current inbox items read for `payload.principal`. Read events MUST
NOT delete inbox rows or alter the source event.

The command-line interface SHOULD expose listing unread and recent inbox
events, subscribing and unsubscribing issue or pull request targets, listing
subscriptions, and marking one or all notifications read. The web interface
SHOULD expose a top-right inbox affordance that shows recent and unread
notifications and links to an inbox view. Issue and pull request detail pages
SHOULD expose a subscribe/unsubscribe control that writes the same notification
subscription events as the CLI.

### 4.8. Pull Request Product Model

Gitomi pull requests are first-class Control Plane objects that coordinate a
proposed Data Plane change. A pull request MUST NOT contain or own source code
bytes. It records review metadata around ordinary Git refs and commits.

A compliant forge UI SHOULD expose pull requests separately from issues. The
minimum pull request surface is:

*   a pull request list filtered by `open`, `closed`, and `merged` state;
*   a pull request detail page containing the conversation, status summary, and
    branch relationship;
*   derived commit and file-change views for `base_ref` and `head_ref`;
*   visible labels, assignees, reviewers, comments, draft state, merge state,
    and imported legacy GitHub number aliases when present.

The canonical branch relationship is `head_ref` proposed for integration into
`base_ref`. Implementations SHOULD compute the default diff using the merge base
between `base_ref` and `head_ref` and the current `head_ref` tip. If either ref
is missing locally, the pull request remains valid but the derived commit and
file-change views SHOULD explain that the data is unavailable.

`pull.merged` records the accepted merge result in the Control Plane. The
payload's `merge_oid` SHOULD identify the merge commit when the integration
created one. The payload's `target_oid` SHOULD identify the resulting target
commit when the integration was a fast-forward, squash, rebase, or externally
applied update. A pull request with an accepted `pull.merged` event is displayed
as merged even if a local clone cannot currently prove that `base_ref` contains
the recorded commit. Implementations SHOULD separately report whether the local
Data Plane confirms the recorded merge result.

Gitomi pull request state does not own the Data Plane branch lifecycle. Merging
or closing a pull request MUST NOT implicitly delete a local branch or remote
tracking ref. A branch whose name is the `head_ref` of a merged or closed pull
request and is not referenced by any open pull request is an inactive pull
request branch for presentation purposes. Forge UIs SHOULD hide inactive pull
request branches from default branch selectors and branch counts, while keeping
them reachable by direct ref lookup and in explicit refs/admin views. This
matches the practical effect of GitHub's "delete branch after merge" workflow
without destroying local-first user state.

Deleting a remote branch after a merge is a Git ref deletion in that remote
repository, not a pull request metadata change. Local clones MAY continue to
hold stale `refs/remotes/<remote>/...` tracking refs until an explicit prune
operation, such as `git fetch --prune <remote>`, removes them. Implementations
SHOULD expose pruning as an explicit user action and MUST distinguish it from
deleting local `refs/heads/...` branches.

Structured reviews are optional in v1. Requested reviewers are modeled directly
on the pull request. General review discussion is represented by comments whose
`parent_kind` is `pull`. Implementations MAY add future `review.*` events or
line-scoped comment metadata while preserving this base pull request model.

### 4.9. Issue and Pull Request Filter Language

Issue and pull request list search boxes use one canonical, GitHub-like filter
language. A query is a whitespace-separated sequence of terms. A term is either
free text or a predicate of the form `key:value`. Values containing whitespace,
literal colons, backslashes, or double quotes MUST be double-quoted; inside
double quotes, `\"` represents a literal double quote and `\\` represents a
literal backslash. Predicate keys and enumerated values are ASCII
case-insensitive. Unknown predicates are treated as free text so newer query
terms do not break older readers.

The canonical issue predicate order is:

`is:issue state:<state> author:<principal> label:<label> project:<project> milestone:<milestone> assignee:<principal> sort:<sort> <free-text>`

Issue state values are `open`, `closed`, and `all`. Issue sort values are
`newest`, `oldest`, and `updated`. The `is:<state>` form MAY be accepted as a
state alias, but canonical renderers MUST emit `state:<state>`.

The canonical pull request predicate order is:

`is:pr state:<state> author:<principal> label:<label> assignee:<principal> reviewer:<principal> base:<ref> head:<ref> sort:<sort> <free-text>`

Pull request state values are `open`, `merged`, `closed`, and `all`. Pull
request sort values are `newest`, `oldest`, and `updated`. The `is:pull` and
`is:pull-request` object aliases and `is:<state>` state aliases MAY be
accepted, but canonical renderers MUST emit `is:pr state:<state>`.

## 5. Identity, Signing, and Authorization

### 5.1. Signing Backends

Events MUST be signed using native Git commit signing.

Implementations MUST support SSH signing (`gpg.format=ssh`) and verification against an `allowedSignersFile`. OpenPGP or Sigstore-based signing MAY be supported as additional backends.

The normative signing-key registry is the accepted genesis manifest plus
accepted `identity.device_added` and `identity.device_revoked` events. An SSH
`allowedSignersFile` is an implementation cache derived from that registry, not
the source of truth. Implementations SHOULD generate a repository-local
allowed-signers file from `.git/gitomi/` state and MAY point Git at it for
verification.

Past signatures remain verifiable after key rotation or device revocation. A
revocation changes authorization for later events; it MUST NOT require deleting
historical public keys needed to verify already accepted commits.

Same-device key rotation is expressed by a later `identity.device_added` event
for the same `(principal, device)` with fresh `signing_key` material. That event
MUST be signed by a device that is authorized at the event's causal frontier,
which can be the old key being rotated out. The new key supersedes the previous
active key for future events whose causal frontier includes the rotation event.
Historical key material remains in the verifier cache for old commits.

Gitomi v1 exposes at most one active signing key per `(principal, device)` in the
identity projection. Concurrent rotations for the same device are resolved by
causal order, then deterministic event-hash order; the non-winning key is not an
active key after both events are observed. `identity.device_revoked` disables the
device as a signing endpoint. A later re-add of the same device after revocation
MUST causally descend from the revocation and normally requires another active
owner device to sign it.

### 5.2. Actor and Device Model

An actor principal is a stable human or bot identity. A device is a concrete signing endpoint for that principal.

The event payload identity and the commit signature MUST agree:

*   the signing key MUST map to `actor.principal`
*   the active device record MUST authorize `actor.device`

`identity.device_added` and `identity.device_revoked` events define the valid device set for each principal.
`identity.device_added` MUST bind the device identifier to public signing key
material and a key fingerprint so a clone can rebuild trust from refs alone.

For delegated actors, the signing key MAY map through an accepted
`acl.delegation_granted` event instead of an identity device record. In that
case the event is authorized only for the delegated capability and scope, and
the commit signer fingerprint MUST match the delegation's signing key.

### 5.3. ACL Model

Authorization is event-sourced.

Compliant implementations MUST derive effective permissions by replaying:

*   `acl.role_granted`
*   `acl.role_revoked`
*   `acl.delegation_granted`
*   `acl.delegation_revoked`
*   `identity.device_added`
*   `identity.device_revoked`

Permissions are role-based. The built-in role-to-permission matrix is defined
normatively by the RBAC specification (`03_RBAC.md`) and MUST be applied
consistently by all compliant replicas. Implementations MAY add custom roles or
permissions, but they MUST NOT weaken the built-in role semantics.

Read permissions are not cryptographic revocation. A replica that has already
cloned refs, bundles, packs, or working-tree data can retain and copy that data
after its role is revoked. Gitomi `*.read` permissions are cooperative UI and
sync-server policy for future access; they do not claw back data already
distributed.

### 5.4. Validation Pipeline

When ingesting an event, implementations MUST:

1.  parse and validate the JSON envelope;
2.  verify the Git commit signature;
3.  verify that the signature maps to `actor.principal` and an authorized device;
4.  evaluate authorization against the event's causal frontier; and
5.  either accept the event into the projection or reject it from the projection.

Authorization MUST be evaluated from causal ancestry, not from wall-clock timestamps alone. `occurred_at` is for ordering and presentation, not for bypassing revocations or grants.

Known ACL, delegation, and device revocations are security barriers, not merely
ordinary concurrent updates. Once a replica has accepted an `acl.role_revoked`,
`acl.delegation_revoked`, or `identity.device_revoked` event, authorization for
later-ingested events MUST treat that revocation as effective unless the event's
causal frontier contains a later grant, delegation, or device-add event for the
same target that causally descends from the revocation. A signed event whose
frontier omits an already accepted revocation of its actor role, delegated
capability, or signing device MUST be rejected from the projection even if the
actor was authorized at the stale frontier it names.

Invalid, unverifiable, or unauthorized events MUST NOT affect the materialized projection.

Implementations MUST distinguish:

*   **structural admission failures**, such as malformed JSON, invalid parent
    hashes, unverifiable signatures, wrong `repo_id`, duplicate `(principal,
    device, seq)`, or oversized event bodies. These events are not admitted into
    the projection input.
*   **domain rejection**, where an event is structurally valid and signed but
    fails an object-level rule such as a missing creation precondition,
    duplicate object creation, unauthorized actor, or invalid ACL/identity
    transition. These events MUST remain auditable by event hash and rejection
    reason, but MUST NOT affect current projections.

## 6. Reducers and Conflict Resolution

Clients materialize current state by reducing the valid event DAG. The log acts as an operation-based CRDT.

### 6.1. General Rules

Reducers MUST apply the following rules:

*   Causal ancestry takes precedence over presentation order.
*   Concurrent events MUST be resolved by the object-specific CRDT rules below.
*   For scalar registers, a causally later event wins over its ancestor.
*   Concurrent scalar events MUST be resolved by deterministic event-hash order.
*   `occurred_at` is for display and import provenance only; it MUST NOT decide security state or reducer precedence.
*   All accepted events MUST remain auditable even when their current visible effect is superseded.

### 6.2. Issues

An issue is created by `issue.opened`.

An issue event other than `issue.opened` has a creation precondition: the target
issue MUST already have an accepted `issue.opened` event in the event's
effective replay history. If not, the event MUST be domain-rejected with reason
`object_not_created` and MUST NOT begin applying later if an `issue.opened`
event for the same UUID is subsequently observed.

If more than one structurally valid `issue.opened` event targets the same
`object.id`, one creation event wins by the implementation's deterministic
reducer order; all other creation events for that ID MUST be domain-rejected
with reason `duplicate_object_id`.

The following issue fields MUST be modeled as causal scalar registers:

*   `title`
*   `body`
*   `state` (`open` or `closed`)
*   `pipeline` (work pipeline stage, such as `Todo`, `WIP`, `Review`, or
    `Done`)
*   `priority` (planning priority, such as `P0`, `P1`, `P2`, or `P3`)
*   `type` (issue kind, such as `bug`, `feature`, or `task`)
*   `milestone`

The following issue collections MUST be modeled as Observed-Remove Sets:

*   labels
*   assignees
*   project placements, keyed by `(project, column)`
*   emoji reactions, keyed by `(emoji, actor.principal)`

The add tag for an OR-Set member is the add event hash. A remove affects only
add tags reachable from the remove event's causal frontier or explicitly listed
in the remove payload. A concurrent add whose event hash is not observed by the
remove MUST remain visible.

For `issue.updated`, each array member in `labels_added`, `labels_removed`,
`assignees_added`, and `assignees_removed` is reduced as if the corresponding
single-field event had been emitted at the same event hash. Implementations
SHOULD prefer `issue.updated` for user-facing edit flows that change multiple
fields, to avoid one signed commit per small UI mutation.

The visible issue projection MUST be bounded. A v1 implementation MUST NOT
project more than 256 labels, more than 128 assignees, or more than 256 project
placements on one issue. A v1 implementation MUST NOT project more than 64
distinct reaction emoji or 1024 visible reaction actors on one issue. An event
that would exceed those limits after reduction MUST be domain-rejected with
reason `collection_limit_exceeded`.

Reducers MUST preserve all accepted events in the issue timeline, even when the visible projection only shows the latest scalar values.

### 6.3. Pull Requests

A pull request is created by `pull.opened`.

A pull request event other than `pull.opened` has a creation precondition: the
target pull request MUST already have an accepted `pull.opened` event in the
event's effective replay history. If not, the event MUST be domain-rejected with
reason `object_not_created`.

If more than one structurally valid `pull.opened` event targets the same
`object.id`, one creation event wins by the implementation's deterministic
reducer order; all other creation events for that ID MUST be domain-rejected
with reason `duplicate_object_id`.

The following pull-request fields MUST be modeled as causal scalar registers:

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
*   emoji reactions, keyed by `(emoji, actor.principal)`

For `pull.updated`, each scalar and collection member is reduced as if the
corresponding single-field event had been emitted at the same event hash.
Implementations SHOULD prefer `pull.updated` for user-facing edit flows that
change multiple fields.

The visible pull-request projection MUST be bounded. A v1 implementation MUST
NOT project more than 256 labels, 128 assignees, or 128 reviewers on one pull
request. A v1 implementation MUST NOT project more than 64 distinct reaction
emoji or 1024 visible reaction actors on one pull request. An event that would
exceed those limits after reduction MUST be domain-rejected with reason
`collection_limit_exceeded`.

`pull.merged` MUST record enough payload to identify the resulting merge outcome, typically a merge commit OID or a fast-forward target OID.
`pull.state_set` MUST NOT set `state` to `merged`; the merged state is derived
only from an accepted `pull.merged` event so merge metadata and state cannot
diverge.

`pull.merged` has the same creation precondition as other pull events. A merge
event before an accepted `pull.opened` event MUST be domain-rejected with reason
`object_not_created`.

### 6.4. Comments

Comments are append-only event histories attached to a stable comment UUID.

*   `comment.added` creates the comment object and attaches it to an issue or pull request.
*   `comment.body_set` updates the current rendered body using causal order,
    with event-hash order for concurrent body updates.
*   `comment.redacted` marks the comment as semantically removed while preserving audit history.
*   `comment.reaction_added` and `comment.reaction_removed` update visible
    emoji reactions on the comment.

`comment.added` MAY include `reply_parent_id`, `reply_parent_hash`, or both to
represent a reply. When either field is present, the referenced parent MUST be
an accepted `comment.added` event in the same top-level issue or pull request
conversation. `reply_parent_hash` SHOULD be the event hash of the parent
comment's accepted creation event and SHOULD be listed in
`parent_hashes.related`. A reply whose parent comment is missing, rejected, or
attached to a different issue or pull request MUST be domain-rejected with
reason `parent_not_created`.

`comment.body_set` and `comment.redacted` require an accepted `comment.added`
event for the target comment. If no accepted creation event exists, the update
or redaction MUST be domain-rejected with reason `object_not_created`.

If more than one structurally valid `comment.added` event targets the same
`object.id`, one creation event wins by the implementation's deterministic
reducer order; all other creation events for that ID MUST be domain-rejected
with reason `duplicate_object_id`.

Redaction is a tombstone in v1. Once an accepted `comment.redacted` event
applies to a comment, the current visible projection MUST remain redacted
regardless of later or concurrent `comment.body_set` events. Implementations MAY
retain prior and later comment bodies as explicit history, but they MUST NOT use
`comment.body_set` to restore visible content after redaction.

For a comment that has not been redacted, the current visible body MUST be
derived from the latest accepted `comment.body_set` or the initial
`comment.added` payload.

Comment reactions are Observed-Remove Sets keyed by `(emoji, actor.principal)`.
The add tag is the `comment.reaction_added` event hash. A
`comment.reaction_removed` event removes only add tags for the removing actor
that are reachable from the remove event's causal frontier or explicitly listed
in `payload.add_hashes`. A v1 implementation MUST NOT project more than 64
distinct reaction emoji or 1024 visible reaction actors on one comment.

### 6.5. Reactions

Emoji reactions are lightweight acknowledgements attached directly to issues,
pull requests, and comments. The reaction payload's `emoji` member is the
canonical UTF-8 emoji presentation string. Writers SHOULD use a single Unicode
emoji grapheme or an established emoji sequence and MUST NOT use control
characters. Implementations MAY normalize known shortcodes such as `+1` or
`heart` to emoji before writing the event, but the event payload MUST contain
the canonical emoji string.

Reactions are not scalar fields. Repeated accepted adds by the same actor for
the same `(object, emoji)` are displayed as one visible reaction by that actor,
but each accepted add remains auditable by event hash. Reaction removals affect
only the removing actor's adds. They MUST NOT remove another principal's
reaction.

### 6.6. Notifications

Notification subscriptions are reduced before publishing inbox rows for the
source event being processed. This means opening an issue or pull request can
subscribe its author, assignees, and reviewers in the same event that creates
the object; the actor still does not receive an inbox item for their own event.

`notification.subscribed` and `notification.unsubscribed` are last-writer-wins
register updates keyed by `(principal, target_kind, target_id)`, using causal
order and deterministic event-hash order for concurrent changes. A subscription
with `active = false` suppresses future inbox delivery until a later subscribed
event wins for the same key.

Inbox publication is deterministic and idempotent. A reducer MUST NOT create
more than one inbox row for the same `(principal, source_event_hash)`. If a
principal is subscribed through multiple reasons, the reducer MAY preserve one
stable reason for display but MUST still deliver at most one inbox item.

### 6.7. Projects and Kanban Boards

A project is created by `project.created`.

A project event other than `project.created` has a creation precondition: the
target project MUST already have an accepted `project.created` event in the
event's effective replay history. If not, the event MUST be domain-rejected
with reason `object_not_created`.

If more than one structurally valid `project.created` event targets the same
`object.id`, one creation event wins by the implementation's deterministic
reducer order; all other creation events for that ID MUST be domain-rejected
with reason `duplicate_object_id`.

The following project fields MUST be modeled as causal scalar registers:

*   `name`
*   `description`
*   `state` (`open` or `closed`)

Kanban columns MUST be modeled as an Observed-Remove Set keyed by column name.
The add tag for a column is the `project.created` or `project.column_added`
event hash. A `project.column_removed` event removes only column add tags
reachable from the remove event's causal frontier or explicitly listed in the
remove payload.

The `columns` array in `project.created` is reduced as if each column had been
added at the same event hash. Implementations SHOULD create new projects with
a small default column set such as `Draft`, `Todo`, `WIP`, `Review`, `Done`,
and `Failed` when the user did not provide columns.

Issue membership in a project is expressed with `issue.project_added` and
`issue.project_removed`, not by mutating the project object. This keeps project
membership causally attached to the issue history. Implementations MAY display
imported or legacy placements for projects that do not have a corresponding
accepted `project.created` event, but created project objects are the canonical
way to preserve empty boards, board metadata, and empty columns.

Project board movement in the richer projects model is expressed by updating the
issue's `pipeline` scalar, not by removing and re-adding project membership. The
legacy `(project, column)` placement remains a compatibility representation for
imported or older kanban boards; clients MUST NOT silently translate conflicting
legacy columns from multiple projects into a single issue pipeline value.

A visible project projection MUST NOT expose more than 128 kanban columns. An
event that would exceed this limit after reduction MUST be domain-rejected with
reason `collection_limit_exceeded`.

### 6.8. Milestones

A milestone is created by `milestone.created`.

A milestone event other than `milestone.created` has a creation precondition:
the target milestone MUST already have an accepted `milestone.created` event in
the event's effective replay history. If not, the event MUST be
domain-rejected with reason `object_not_created`.

If more than one structurally valid `milestone.created` event targets the same
`object.id`, one creation event wins by deterministic reducer order; all other
creation events for that ID MUST be domain-rejected with reason
`duplicate_object_id`.

The following milestone fields MUST be modeled as causal scalar registers:

*   `title`
*   `description`
*   `due_at`
*   `state` (`open` or `closed`)

An issue milestone assignment is expressed by `issue.milestone_set`, whose
target is the issue. The assignment MAY use a plain milestone title for
compatibility with imported trackers. If `milestone_ref` is present and
resolves locally, implementations SHOULD use the referenced milestone for UI
linking; absence of a created milestone MUST NOT make the issue assignment
invalid.

Interactive milestone update surfaces SHOULD emit `milestone.updated` when
changing one or more milestone scalar fields. Empty `description` and `due_at`
values clear those fields; `title` MUST NOT be empty. Convenience close/reopen
surfaces SHOULD emit `milestone.state_set` with `state` set to `closed` or
`open`.

### 6.9. Derived References From Code Commits

Implementations MUST parse Data Plane commit messages to derive links from code to Gitomi objects.

*   **Syntax**: `#<object-ref>`, `issue:<object-ref>`, or `pr:<object-ref>`
*   **Resolution**: the object ref MUST resolve against the local issue and pull index as a lowercase hex prefix of `sha256(object.id)`
*   **Ambiguity**: if multiple objects share the prefix, the implementation SHOULD prompt for a longer prefix or ignore the reference

These links are derived projection data. They MUST NOT be written back as explicit control-plane events.

Issue and pull request bodies and comments MAY also contain reference message
directives as defined in the ref format specification. Implementations SHOULD
derive issue and pull relationships from accepted, non-redacted body/comment
text that uses those directives. These relationships are presentation data and
MUST NOT change object state or admission decisions.

### 6.10. Cache Rebuild

`.git/gitomi/index.sqlite` and `.git/gitomi/cursors.sqlite` are disposable caches.

If missing or corrupted, a compliant implementation MUST rebuild state by:

1.  loading the newest valid snapshot, if any; and
2.  replaying all valid events not covered by that snapshot.

## 7. Sync and History Rules

### 7.1. Transport

Synchronization MUST use standard Git transport and refs. Implementations MUST be able to fetch and push Gitomi refs over normal Git protocol v2 transports such as SSH, HTTPS, or bundles.

Default push MUST publish `refs/gitomi/genesis` and every local authoritative
inbox ref under `refs/gitomi/inbox/*`. A replica MAY therefore relay inbox refs
that it fetched and admitted from another replica. Default push MUST NOT publish
local cache or diagnostic refs, including `refs/gitomi/staging/*`,
`refs/gitomi/quarantine/*`, `refs/gitomi/snapshots/*`, or
`refs/gitomi/runs/*`.

### 7.2. `repo_id` Discovery and Forks

The canonical `repo_id` is learned from the signed manifest at
`refs/gitomi/genesis`. Local `.git/gitomi/config.toml` stores the current actor
configuration and a cached `repo_id`; it is not authoritative. If local config
conflicts with a valid local genesis manifest, implementations MUST report the
conflict and refuse to write new events until the operator resolves it.

A fresh clone discovers `repo_id` by fetching and validating
`refs/gitomi/genesis` before admitting inbox events. A fetched genesis that
differs from an existing local genesis is a trust-root conflict and MUST NOT be
auto-merged.

A normal Git fork that preserves `refs/gitomi/genesis` is the same logical
Gitomi repository and keeps the same `repo_id`. A detached fork that wants an
independent control plane MUST create a new genesis with a new `repo_id` and
MUST NOT replay the old repository's inbox refs as authoritative history except
through an explicit import process.

### 7.3. Sequence Numbers

`seq` is scoped to `(actor.principal, actor.device)`. It MUST be unique and
strictly increasing along that principal-device inbox history. It is not
required to be gap-free.

Writers SHOULD emit the previous accepted local sequence plus one. If local
configuration is missing or stale only with respect to `seq`, an implementation
MUST recover by scanning the local authoritative inbox ref for the configured
principal/device and continuing from the largest structurally valid sequence it
can observe. A corrupted `repo_id`, principal, or device remains a configuration
error and MUST NOT be guessed.

### 7.4. Append-Only Rule

Shared inbox refs are immutable after publication.

*   An implementation MUST NOT force-push or rewrite `refs/gitomi/inbox/*` that may already be visible to another replica.
*   A device MAY rewrite its own unpublished local inbox ref before first publication.
*   Once published, corrections MUST be expressed as new events, not history edits.

Implementations SHOULD debounce local UI edits, batch logically-related edits
into `issue.updated` or `pull.updated`, and MAY rewrite a device's unpublished
local outbox before first publication. These mechanisms reduce event volume
without weakening the append-only rule for shared inbox refs.

### 7.5. Snapshots

Snapshots are additive bootstrap aids, not replacements for the authoritative event history.

A snapshot manifest SHOULD record:

*   the snapshot schema version;
*   the set of inbox heads covered by the snapshot;
*   the projected object state included in the snapshot; and
*   any preserved legacy alias mappings.

Snapshots MAY accelerate clone, bootstrap, or cache rebuild, but v1 does not define destructive compaction of shared inbox history. Repository-wide history rewriting is out of scope for this version.

Implementations that fetch, retain, or load snapshots MUST apply explicit size
and count limits. The v1 default maximum snapshot tree size SHOULD be no more
than 64 MiB, and the default retained snapshot count SHOULD be no more than 32
per repository unless the operator explicitly configures larger values.

## 8. Actions Engine

### 8.1. Workflow Definitions

Workflows MUST be read from `.github/workflows/*.yml` or `.github/workflows/*.yaml`.

Gitomi SHOULD preserve GitHub Actions syntax compatibility for workflow files.
At minimum, implementations MUST recognize top-level `on` declarations in the
scalar, array, mapping, and block forms commonly used by GitHub Actions. A
workflow is eligible when its trigger matches the Gitomi event type, the GitHub
event name derived from that type, or the Gitomi event family.

### 8.2. Scheduler

The scheduler MUST observe both:

*   Data Plane events such as branch updates; and
*   Control Plane events such as `issue.*`, `pull.*`, and `action.run_requested`.

Implementations MUST provide a scheduler service or daemon mode that can run
continuously without user interaction. The daemon MUST maintain local,
disposable scheduler cursors outside the Data Plane, normally under
`.git/gitomi/`, so it can resume after restart without replaying already
scheduled events. On first start it SHOULD initialize its cursors to the current
accepted event frontier and current `HEAD` unless the operator explicitly asks
to replay existing events.

When an event matches a workflow trigger, the scheduler MUST create an
`action.run_requested` inbox event before execution. The request payload MUST
record the workflow file path and the target code state as `target_oid`, and MAY
also record the human ref as `target_ref`. The payload SHOULD record both the
GitHub-compatible `event_name` used to execute the workflow and the original
Gitomi `gitomi_event_type`.

The scheduler MUST then construct a GitHub-like event payload and invoke the
execution core against the referenced code state. For Gitomi Control Plane
events, the GitHub-compatible event names are:

| Gitomi event | GitHub event name |
|--------------|-------------------|
| `issue.*` | `issues` |
| `pull.*` | `pull_request` |
| `action.run_requested` | `workflow_dispatch` |
| `push` | `push` |
| other event types | unchanged event type string |

### 8.3. Execution Core

Implementations SHOULD use `nektos/act` or a compatible derivative as the local
execution core. The v1 CLI execution contract is:

1.  Resolve the target to a commit OID.
2.  Create a temporary detached worktree at that commit.
3.  Write the synthesized event payload to a local file outside the data-plane
    tree, normally under `.git/gitomi/action-events/`.
4.  Invoke `act` from the temporary worktree as:

    ```text
    act <event_name> -W <workflow-path> -e <event-payload-path> [extra args...]
    ```

The execution payload MUST include `ref`, `after`, `repository`, `workflow`, and
`gitomi` fields. `gitomi.run_id` MUST equal the run request UUID, and
`gitomi.event_type` MUST carry the original Gitomi event type. For issue and
pull request events, implementations SHOULD set the payload `action` field from
the suffix of the Gitomi event type (for example `issue.opened` becomes
`opened`) and include minimal `issue` or `pull_request` objects containing the
Gitomi object ID when known.

Implementations MAY pass through additional `act` arguments supplied by the
operator after Gitomi's required arguments. A missing or failing execution core
MUST NOT remove the run request event; it MUST be represented by a completion
event with an appropriate non-success conclusion when the runner is able to
write one.

### 8.4. Run Storage and Results

Workflow execution results MUST be summarized by a signed `action.run_completed` event in an inbox ref.
The completion `conclusion` MUST be one of `success`, `failure`, `cancelled`,
`skipped`, `neutral`, `timed_out`, or `action_required`.

Implementations MAY additionally stream incremental logs, traces, or artifacts into `refs/gitomi/runs/<runner-id>/<run-id>` or external object storage.

When external storage is used, the final event payload MUST contain a stable content reference such as a Git OID or SHA-256 digest.

Run refs are auxiliary diagnostics. They MUST NOT be replayed by reducers, MUST
NOT be pushed or fetched by default sync, and MAY be deleted according to local
or server retention policy without changing repository state. Implementations
SHOULD provide retention controls for maximum age, maximum retained run count,
and maximum retained bytes. The signed `action.run_completed` event is the
durable workflow result; logs and artifacts SHOULD be content-addressed or
externally stored when they are large.

Implementations MUST bound diagnostic storage. v1 implementations SHOULD cap
default retained run diagnostics to 256 MiB total, SHOULD reject or externalize
large individual artifacts, and MUST require an explicit diagnostic path to
fetch or push run refs.

### 8.5. Web UI

Implementations that provide a web UI MUST expose workflow automation state.
The UI SHOULD include:

*   discovered workflow files and their triggers for the selected code state;
*   accepted run requests, pending runs, completions, and conclusions;
*   enough target information to identify the ref or commit being run; and
*   controls to request a workflow run when the local actor can write signed
    `action.run_requested` events.

The web UI MAY expose a local-only "run pending" control that invokes the same
execution core as the daemon. Long-running or privileged runner operation
SHOULD remain an explicit local action and MUST NOT require publishing run refs.

## 9. Migration Compatibility

### 9.1. GitHub Import

When importing from GitHub:

1.  each issue or pull request MUST receive a new UUIDv7;
2.  the original GitHub number MUST be preserved in `legacy.github_issue_number` or `legacy.github_pull_number`;
3.  historical labels, comments, and state transitions SHOULD be backfilled as Gitomi events; and
4.  imported events SHOULD be authored by a clearly identified `import-bot` principal.

The `import-bot` SHOULD be authorized through an `acl.delegation_granted` event
emitted by the actor executing the import. The delegation MUST bind the bot
principal/device, the `github.import` capability, and the signing key that will
sign imported events. This preserves a stable bot event stream for later
two-way sync while keeping the import auditable as a maintainer-approved action.

Imported numeric identifiers are compatibility metadata, not the native identity model.

### 9.2. GitHub Export

When exporting to GitHub:

1.  Data Plane refs are pushed with standard Git;
2.  Gitomi UUIDs MUST be mapped to GitHub-assigned numeric identifiers for the target repository; and
3.  accepted Gitomi state transitions SHOULD be replayed through the GitHub API.

When a Gitomi issue or pull request is first created in GitHub, the resulting
GitHub number SHOULD be published back into Gitomi as durable compatibility
metadata on the shared bridge actor, for example as an alias-only
`issue.updated` or `pull.updated` event carrying `legacy.github_issue_number`
or `legacy.github_pull_number`. Importers and later exporters MUST treat that
alias as the identity mapping for the target GitHub repository so replicas with
empty private map files do not create duplicate native objects or duplicate
GitHub issues/pulls after they have pulled the bridge event.

This alias publication is not a distributed lock for simultaneous outbound
creates. Operators that enable Gitomi-to-GitHub export from multiple machines
SHOULD serialize those writers or otherwise use an external lease.
