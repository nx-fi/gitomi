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

### 2.1. Security Model Limitations

Gitomi RBAC protects the Control Plane projection. It determines which signed
events affect issues, pull requests, comments, workflow requests, ACL state, and
identity state.

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
*   `.git/gitomi/index.sqlite`: Materialized state for issues, pull requests, comments, ACLs, and workflow status.
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
*   **First parent**: MUST be the previous commit on the same inbox ref, except for the root event on that ref.
*   **Additional parents**: SHOULD encode a bounded set of latest Gitomi commits known to the writer when the event was created. These extra parents define cross-device causal knowledge.
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
    "kind": "string (issue | pull | comment | acl | identity | action)",
    "id": "string, UUIDv7 of the logical object"
  },
  "idempotency_key": "string, UUIDv7",
  "actor": {
    "principal": "string",
    "device": "string"
  },
  "parent_hashes": {
    "log": "string, previous commit OID or empty string",
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

Issue, pull request, comment, and action run identifiers MUST be UUIDv7. ACL
and identity events target stable system objects rather than user-facing
content objects:

*   `acl.*`: `object.id` MUST be `acl:<principal>`, where `<principal>` is the
    canonical target principal in `payload.principal`.
*   `identity.*`: `object.id` MUST be `identity:<principal>:<device>`, where
    the components match `payload.principal` and `payload.device`.
*   `action.run_requested` and `action.run_completed`: `object.id` MUST be the
    run UUID. For `action.run_completed`, `payload.run_id` MUST equal
    `object.id`.

Gitomi v1 does not require a native repo-wide integer allocator. The canonical human reference form is a unique UUID prefix:

*   `#<uuid-prefix>` for issues and pull requests
*   minimum prefix length: 7 lowercase hex characters
*   implementations MUST extend the displayed prefix when 7 characters are ambiguous within the local projection

Imported GitHub numbers MAY be preserved as secondary aliases in `legacy.*`, but native Gitomi objects MUST remain addressable without allocating sequential integers.

### 4.4. Idempotency

Clients MUST generate an `idempotency_key` for every logical action.

Reducers MUST suppress duplicate effects when the same logical action is replayed or retried. At minimum, duplicate `idempotency_key` values for the same `repo_id` MUST be ignored after the first accepted event.

Suppressed duplicate idempotency keys MUST NOT change projections. They SHOULD
remain inspectable as rejected domain events when the implementation can
preserve them without admitting malformed history.

### 4.5. Minimum v1 Event Families

Compliant implementations MUST understand the following event families:

*   `issue.opened`, `issue.updated`, `issue.title_set`, `issue.body_set`, `issue.state_set`, `issue.label_added`, `issue.label_removed`, `issue.assignee_added`, `issue.assignee_removed`
*   `pull.opened`, `pull.updated`, `pull.title_set`, `pull.body_set`, `pull.state_set`, `pull.base_set`, `pull.head_set`, `pull.label_added`, `pull.label_removed`, `pull.assignee_added`, `pull.assignee_removed`, `pull.reviewer_added`, `pull.reviewer_removed`, `pull.merged`
*   `comment.added`, `comment.body_set`, `comment.redacted`
*   `acl.role_granted`, `acl.role_revoked`
*   `identity.device_added`, `identity.device_revoked`
*   `action.run_requested`, `action.run_completed`

Implementations MAY support additional event types. Unknown event types MUST be preserved and SHOULD be ignored unless the implementation explicitly understands them.

### 4.6. Minimum Payload Requirements

The following payload members are REQUIRED for interoperable v1 implementations:

*   `issue.opened`: `title`; OPTIONAL `body`, `labels`, `assignees`
*   `issue.updated`: OPTIONAL `title`, `body`, `state`, `labels_added`, `labels_removed`, `assignees_added`, `assignees_removed`; at least one field MUST be present
*   `issue.title_set`: `title`
*   `issue.body_set`: `body`
*   `issue.state_set`: `state`
*   `issue.label_added` / `issue.label_removed`: `label`
*   `issue.assignee_added` / `issue.assignee_removed`: `assignee`
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
*   `comment.added`: `parent_kind`, `parent_id`, `body`
*   `comment.body_set`: `body`
*   `comment.redacted`: OPTIONAL `reason`
*   `acl.role_granted` / `acl.role_revoked`: `principal`, `role`
*   `identity.device_added`: `principal`, `device`, `signing_key.public_key`, `signing_key.fingerprint`
*   `identity.device_revoked`: `principal`, `device`
*   `action.run_requested`: `workflow`, `target_ref` or `target_oid`
*   `action.run_completed`: `run_id`, `conclusion`, `target_ref` or `target_oid`

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

### 5.3. ACL Model

Authorization is event-sourced.

Compliant implementations MUST derive effective permissions by replaying:

*   `acl.role_granted`
*   `acl.role_revoked`
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
*   implementation-defined scalar metadata such as `priority` or `milestone`

The following issue collections MUST be modeled as Observed-Remove Sets:

*   labels
*   assignees

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
project more than 256 labels or more than 128 assignees on one issue. An event
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

For `pull.updated`, each scalar and collection member is reduced as if the
corresponding single-field event had been emitted at the same event hash.
Implementations SHOULD prefer `pull.updated` for user-facing edit flows that
change multiple fields.

The visible pull-request projection MUST be bounded. A v1 implementation MUST
NOT project more than 256 labels, 128 assignees, or 128 reviewers on one pull
request. An event that would exceed those limits after reduction MUST be
domain-rejected with reason `collection_limit_exceeded`.

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

Default push MUST publish only `refs/gitomi/genesis` and the configured local
actor's own inbox ref. It MUST NOT republish other locally replicated inbox refs
unless the operator selects an explicit mirror or backup mode.

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
