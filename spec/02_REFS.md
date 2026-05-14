# Gitomi Ref and Commit Format Specification v1.0

## 1. Introduction

This document defines the normative on-disk format for Gitomi's control-plane data stored inside a standard Git repository. It specifies ref naming, commit structure, parent linkage, the staging area used during sync, and the rules that make the event history a valid append-only DAG.

All Gitomi state lives in ordinary Git refs and commits. No custom object types, packfile extensions, or non-standard transport features are required.

### 1.1. Conformance Keywords

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119.

## 2. Ref Namespace Map

### 2.1. Overview

Gitomi partitions its refs under a single top-level prefix:

```
refs/gitomi/
├── genesis                         # signed repository trust manifest
├── inbox/<principal>/<device>     # authoritative event logs
├── staging/<remote>/inbox/…       # transient fetch targets
├── quarantine/<remote>/inbox/…     # rejected fetched inbox heads
├── main                           # optional synthesized merge
├── snapshots/<snapshot-id>        # optional bootstrap checkpoints
└── runs/<runner-id>/<run-id>      # optional workflow traces
```

Implementations MUST NOT write Gitomi data outside `refs/gitomi/`.

Gitomi object references such as `#018f000`, `@roadmap`, and `^v1.0` are
human-facing reference tokens, not Git refnames. They MUST NOT be stored as
refs under `refs/gitomi/`; they are aliases derived from accepted event
payloads and the local projection.

### 2.2. Genesis Ref

```
refs/gitomi/genesis
```

The genesis ref is the canonical bootstrap trust anchor for a Gitomi repository.
It MUST point to a signed commit whose tree contains exactly one manifest file at
`.gitomi/genesis.json`.

The manifest MUST contain:

*   the logical `repo_id`;
*   the initial owner principal and role;
*   the initial device identifier for that owner; and
*   the initial device signing key, including public key material and a
    fingerprint.

Example:

```json
{
    "$schema": "urn:gitomi:genesis:v1",
    "repo_id": "018f0000-0000-7000-8000-000000000001",
    "owner": {
        "principal": "alice",
        "role": "owner"
    },
    "device": {
        "principal": "alice",
        "id": "laptop",
        "signing_key": {
            "scheme": "ssh",
            "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...",
            "fingerprint": "SHA256:..."
        }
    }
}
```

The genesis commit MUST be signed by the manifest's initial device key. A clone
MUST treat the genesis commit hash, manifest `repo_id`, owner, device, and key
fingerprint as the repository's trust root. If a clone already has a local
genesis ref, a different fetched genesis commit MUST NOT be admitted
automatically.

The genesis ref is immutable after publication. Any later owner or device change
MUST be expressed through inbox events, not by rewriting `refs/gitomi/genesis`.

### 2.3. Inbox Refs

```
refs/gitomi/inbox/<principal>/<device>
```

Each inbox ref is the append-only event log for one principal–device pair. These refs are the sole authoritative source of control-plane events.

*   `<principal>` identifies the actor (human or bot).
*   `<device>` identifies the signing endpoint for that principal.
*   Both segments MUST be ref-safe path components (§3).
*   The ref path MUST contain exactly two segments after `inbox/`. Additional nesting (e.g., `inbox/alice/laptop/extra`) is invalid.

Every repository participant owns one inbox ref per device. A principal with multiple devices (e.g., laptop, phone) has multiple inbox refs.

### 2.4. Staging Refs

```
refs/gitomi/staging/<remote-name>/inbox/<principal>/<device>
```

Staging refs are transient intermediaries used during `gt sync pull`. They hold fetched remote inbox state before admission into the local `refs/gitomi/inbox/` namespace.

*   `<remote-name>` is derived from the Git remote name by sanitizing it into a ref-safe segment (§3.3).
*   The subtree under `<remote-name>/` mirrors the `inbox/<principal>/<device>` structure.
*   Staging refs MUST NOT be treated as authoritative. They exist only to allow validation before promotion.
*   Implementations MAY delete staging refs after successful admission.

### 2.5. Quarantine Refs

```
refs/gitomi/quarantine/<remote-name>/inbox/<principal>/<device>/<head-hash>
```

Quarantine refs are local diagnostic refs for fetched inbox heads that cannot be
admitted because they are structurally invalid, unverifiable, non-fast-forward,
or otherwise chain-invalid. Quarantine refs MUST NOT be treated as
authoritative, MUST NOT be replayed by reducers, and MUST NOT be pushed by
default.

The `<head-hash>` segment SHOULD be the staged head commit OID, or a unique
prefix of it that remains ref-safe in the local repository.

### 2.6. Main Ref (OPTIONAL)

```
refs/gitomi/main
```

An optional synthesized merge ref for inspection or tooling convenience. It
MUST NOT be treated as the sole source of truth. Implementations MAY update this
ref as a merge of all inbox heads after sync.

### 2.7. Snapshot Refs (OPTIONAL)

```
refs/gitomi/snapshots/<snapshot-id>
```

Additive checkpoint refs containing projection manifests and compact bootstrap state. Snapshot commits MAY reference non-empty trees containing serialized projections.

Snapshots are auxiliary bootstrap data, not reducer input. Implementations that
fetch, retain, or load snapshots MUST apply explicit limits to individual
snapshot tree size, total retained snapshot bytes, and retained snapshot count.
The v1 default maximum snapshot tree size SHOULD be no more than 64 MiB, and the
v1 default retained snapshot count SHOULD be no more than 32 unless the operator
explicitly configures larger values.

### 2.8. Run Refs (OPTIONAL)

```
refs/gitomi/runs/<runner-id>/<run-id>
```

Workflow execution trace refs for incremental logs, artifacts, or diagnostics. Run commits MAY reference non-empty trees.

Run refs are auxiliary and retention-managed. They MUST NOT be used as reducer
input, MUST NOT be included in default sync refspecs, and MAY be deleted by
local or server policy. Implementations SHOULD expose retention controls for
maximum age, maximum retained run count, and maximum retained bytes.
Implementations that fetch or retain run refs MUST apply explicit limits to
individual artifact size, total bytes per run, and total retained run bytes. The
v1 default maximum retained run bytes SHOULD be no more than 256 MiB unless the
operator explicitly configures a larger value.

## 3. Ref-Safe Segments

### 3.1. Character Set

A ref-safe segment MUST satisfy all of the following:

*   Non-empty.
*   Contains only lowercase and uppercase ASCII letters (`a-z`, `A-Z`), digits (`0-9`), underscore (`_`), hyphen (`-`), or period (`.`).
*   Does not equal `.` or `..`.
*   Does not end with `.lock`.
*   Does not contain consecutive periods (`..`).

These rules are a subset of the Git refname constraints (see `git-check-ref-format(1)`), scoped to single path segments.

### 3.2. Case Sensitivity

Implementations SHOULD treat ref segments as case-sensitive. However, since some filesystems and Git hosting platforms are case-insensitive, implementations SHOULD use lowercase segments for new principals and devices.

### 3.3. Sanitization

When deriving a ref segment from external input (e.g., a Git remote name, email address, or hostname), implementations SHOULD apply the following normalization:

1.  Convert to lowercase.
2.  Replace any character outside the allowed set with a hyphen (`-`). Collapse consecutive hyphens into one.
3.  Strip leading and trailing hyphens and periods.
4.  If the result is empty or invalid, generate a fallback (e.g., a UUID-prefix-based segment).

### 3.4. Human Object Reference Tokens

Gitomi uses a small reference-token grammar for user input, rendered links, and
payload aliases. These tokens are not Git refs and do not authorize access.

| Token | Target |
|-------|--------|
| `#<object-ref>` | Issue in issue context, or issue/pull when the caller resolves both |
| `issue:<object-ref>` | Issue |
| `pr:<object-ref>` or `pull:<object-ref>` | Pull request |
| `project:<uuid-prefix>` | Project by UUID prefix |
| `@<project-slug>` | Project by slug |
| `milestone:<uuid-prefix>` | Milestone by UUID prefix |
| `^<milestone-slug>` | Milestone by slug |
| `@<project-slug>/<column-slug>` | Kanban column on a project |

Issue and pull object refs MUST be lowercase hexadecimal prefixes of
`sha256(object.id)`, where `object.id` is the canonical UUID string from the
accepted event payload. They MUST be at least 7 characters and MUST be extended
when ambiguous. Project, milestone, and column slugs MUST be ref-safe segments
(§3.1) generated with the sanitization algorithm in §3.3. If a slug would
collide in the local projection, the writer MUST append a disambiguating
suffix, normally `-<uuid-prefix>`.

CLI and HTTP entry points SHOULD accept the typed long forms
`issue:<object-ref>`, `pull:<object-ref>`, `project:<uuid-prefix>`, and
`milestone:<uuid-prefix>` whenever the expected object kind is not otherwise
obvious from command context.

Accepted event payloads MUST carry display names (`project`, `column`, `name`,
or `title`) even when they also carry slug or UUID aliases. Reducers MUST treat
the UUID in `object.id` as authoritative for created project and milestone
objects.

## 4. Event Hashes and Inbox Commit Format

### 4.0. Event Hash Identity

The authoritative identity of an accepted inbox event is its event hash, not its
`event_uuid`. In v1, the event hash is the Git commit OID of the signed inbox
commit that carries the event envelope.

`event_uuid` is client generated and MUST NOT be used as a security boundary, as
the primary causal identity, or as the final reducer tie-breaker. It remains an
opaque idempotency and display label.

When a repository uses SHA-1 object IDs, implementations SHOULD expose event
hashes with an algorithm prefix such as `git-sha1:<hex>`. When the algorithm is
unambiguous in local storage, the raw hex commit OID MAY be used.

### 4.1. Tree Object

Every commit on an inbox ref MUST reference the repository's empty tree object.

The empty tree OID is the well-known SHA-1 `4b825dc642cb6eb9a060e54bf8d69288fbee4904` (or the equivalent under SHA-256 repositories). Implementations MUST compute it via `git hash-object -w -t tree --stdin < /dev/null` rather than hardcoding, to support both hash algorithms.

Rationale: inbox commits carry data exclusively in commit messages, not in tracked files. The empty-tree constraint ensures that Gitomi never pollutes the working tree and that `git diff` between inbox commits is always empty.

The genesis ref is an exception to the empty-tree rule: its commit MUST use a
non-empty tree containing `.gitomi/genesis.json`.

### 4.2. Commit Signature

Every inbox commit MUST be signed using Git's native commit signing mechanism (`-S` flag to `git commit-tree`).

Implementations MUST support SSH signing (`gpg.format=ssh`) with verification against an `allowedSignersFile`. OpenPGP and Sigstore signing MAY be supported additionally.

The signature binds the event content to a specific cryptographic identity. Unsigned or unverifiable inbox commits MUST be rejected during sync admission and fsck.

### 4.3. Commit Message Structure

An inbox commit message has two parts separated by a blank line, following standard Git conventions:

```
<subject line>\n
\n
<body: JSON event envelope>
```

*   **Subject line**: A short human-readable summary. SHOULD follow the pattern `<event_type> #<object-id-prefix> <title-or-summary>`. Example: `issue.opened #018f000 Fix login bug`.
*   **Body**: MUST contain exactly one UTF-8 JSON object conforming to the event envelope schema (see §5). The body MUST NOT contain any text before or after the JSON object.

The subject line MUST NOT exceed 512 bytes. The JSON body of a v1 inbox event
MUST NOT exceed 1 MiB before Git object compression.

### 4.4. Parent Linkage and Parent Hashes

Inbox commits use Git's multi-parent mechanism to encode sequential ordering and
cross-device causal knowledge. Event envelopes also record the same parent
hashes explicitly so reducers can reason about security and object-specific
relationships without trusting user-generated UUIDs.

#### 4.4.1. First Parent (Chain Link)

*   The first parent MUST be the immediately preceding commit on the same inbox ref.
*   The root commit (first event on an inbox ref) MUST have no first parent (it is a parentless commit).
*   This forms a strict linear chain when traversed with `--first-parent`.
*   For every non-root inbox event, `parent_hashes.log` in the event envelope
    MUST equal the first-parent commit OID.

#### 4.4.2. Additional Parents (Causal Knowledge)

*   After the first parent, a commit SHOULD include additional parents referencing a bounded set of latest known heads of other inbox refs at the time the event was created.
*   These additional parents encode the actor's causal knowledge: "when I created this event, I had observed these other inbox states."
*   Additional parents MUST be commit OIDs that exist in the repository. Implementations MUST tolerate missing additional parents during validation (the remote commits may not have arrived yet).
*   When no cross-device knowledge exists (e.g., the actor has never synced), the commit has only its first parent (or no parents for root commits).
*   A v1 event commit MUST NOT contain more than 32 additional parents. Writers SHOULD omit heads already reachable from the first parent before applying this cap, then select remaining heads deterministically by inbox ref name. Omitted heads are treated as concurrent.
*   `parent_hashes.causal` in the event envelope MUST contain the additional
    parent commit OIDs known to the writer. The JSON order MUST match the Git
    parent order after the first parent.

#### 4.4.3. Related Parent Hashes

`parent_hashes.related` records event hashes for domain-related events that the
writer used when creating the event. Related means one of:

*   the previous event in the same principal-device log (`parent_hashes.log`);
*   the latest observed event that affects the same scalar register, such as an
    issue title, pull state, comment body, merge state, ACL role for a
    principal, or identity device binding;
*   an add event hash being observed by a collection remove; or
*   a creation event for the object being modified.

For v1, the log parent is the minimum related parent for every non-root event.
Object-specific related parents SHOULD be recorded whenever the local projection
can identify them. Security-sensitive events (`acl.*`, `identity.*`, merge, and
redaction) MUST include the latest observed related event hash for the same
security target when such an event exists.

A v1 event envelope MUST NOT contain more than 256
`parent_hashes.related` entries.

#### 4.4.4. Parent Order

```
parent 1: previous commit on this inbox ref (chain link)
parent 2: latest known head of inbox ref A
parent 3: latest known head of inbox ref B
...
```

The order of additional parents (2, 3, …) is not semantically significant but SHOULD be stable (e.g., sorted by refname) for reproducibility.

### 4.5. Commit Construction

To create a new inbox event commit, an implementation MUST:

1.  Compute the empty tree OID.
2.  Resolve the current head of the actor's inbox ref (if it exists) as the first parent.
3.  Resolve the current heads of all other known inbox refs as additional parents.
4.  Resolve related parent hashes for the event's object, field, collection
    member, ACL target, identity target, or merge/redaction target.
5.  Format the subject line and JSON event body, including `parent_hashes`.
6.  Run `git commit-tree -S` with the empty tree, the formatted message, and the parent flags.
7.  Atomically update the inbox ref using `git update-ref` with the expected old value (compare-and-swap).

Step 7 ensures that concurrent local writes are detected. If the CAS fails, the
implementation MUST retry from step 2.

## 5. Event Envelope (Wire Format)

### 5.1. Schema

Every event body MUST be a single JSON object conforming to:

```json
{
    "$schema": "urn:gitomi:event:v1",
    "repo_id": "<UUIDv7>",
    "event_uuid": "<UUIDv7>",
    "event_type": "<family>.<action>",
    "object": {
        "kind": "<issue|pull|project|milestone|comment|acl|identity|action>",
        "id": "<object-id>"
    },
    "idempotency_key": "<UUIDv7>",
    "actor": {
        "principal": "<string>",
        "device": "<string>"
    },
    "parent_hashes": {
        "log": "<commit-oid or empty string>",
        "causal": ["<commit-oid>"],
        "related": ["<commit-oid>"]
    },
    "seq": <non-negative integer>,
    "occurred_at": "<RFC 3339 UTC timestamp ending in Z>",
    "legacy": {},
    "payload": {}
}
```

### 5.2. Field Semantics

| Field               | Type    | Description |
|---------------------|---------|-------------|
| `$schema`           | string  | MUST be `"urn:gitomi:event:v1"`. |
| `repo_id`           | UUIDv7  | Identifies the logical repository. All events in a repo MUST share the same `repo_id`. |
| `event_uuid`        | UUIDv7  | Client-generated idempotency/display label. MUST NOT be trusted as the event's authoritative identity. |
| `event_type`        | string  | Dot-separated family and action (e.g., `issue.opened`). |
| `object.kind`       | string  | Object type this event targets. MUST match the event family prefix. |
| `object.id`         | string  | Stable identifier for the logical object. Issue, pull, project, milestone, comment, and action run IDs are UUIDv7. ACL IDs are `acl:<principal>`. Identity IDs are `identity:<principal>:<device>`. |
| `idempotency_key`   | UUIDv7  | Deduplication key. Duplicate keys within the same `repo_id` MUST be suppressed. |
| `actor.principal`   | string  | The acting principal. MUST match the commit signature identity. |
| `actor.device`      | string  | The device that created the event. MUST be ref-safe. |
| `parent_hashes.log` | string  | First-parent event hash for this inbox log, or the empty string for a root event. |
| `parent_hashes.causal` | array | Additional Git parent event hashes representing observed inbox heads. |
| `parent_hashes.related` | array | Domain-related event hashes used by reducers and security checks. |
| `seq`               | integer | Strictly increasing per `(principal, device)` log. The tuple `(principal, device, seq)` MUST be unique within a repository. Gaps are allowed. |
| `occurred_at`       | string  | RFC 3339 UTC timestamp (MUST end with `Z`). Used for presentation only; MUST NOT decide security or reducer precedence. |
| `legacy`            | object  | Container for import-compatibility fields (e.g., `github_issue_number`). MAY be empty. |
| `payload`           | object  | Event-specific data. Required fields depend on `event_type`. |

### 5.3. Object Kind Constraints

The `object.kind` MUST agree with the `event_type` prefix:

| Event prefix    | Required `object.kind` |
|-----------------|------------------------|
| `issue.*`       | `issue`                |
| `pull.*`        | `pull`                 |
| `project.*`     | `project`              |
| `milestone.*`   | `milestone`            |
| `comment.*`     | `comment`              |
| `acl.*`         | `acl`                  |
| `identity.*`    | `identity`             |
| `action.*`      | `action`               |

Events with a mismatch MUST be rejected.

The `object.id` value MUST match the event family:

| Event family              | Required `object.id` form |
|---------------------------|---------------------------|
| `issue.*`                 | UUIDv7 issue id |
| `pull.*`                  | UUIDv7 pull id |
| `project.*`               | UUIDv7 project id |
| `milestone.*`             | UUIDv7 milestone id |
| `comment.*`               | UUIDv7 comment id |
| `acl.role_granted` / `acl.role_revoked` | `acl:<payload.principal>` |
| `identity.device_added` / `identity.device_revoked` | `identity:<payload.principal>:<payload.device>` |
| `action.run_requested`    | UUIDv7 run id |
| `action.run_completed`    | UUIDv7 run id equal to `payload.run_id` |

Events with an invalid object id for their family MUST be rejected.

### 5.4. Unknown Event Types

Implementations MUST preserve events with unrecognized `event_type` values in the log. Unknown events SHOULD be ignored by reducers unless the implementation explicitly understands them. They MUST NOT cause rejection of the entire inbox ref.

### 5.5. v1 Resource Limits

Implementations MUST enforce these default v1 limits during sync admission,
fsck, and index rebuild:

| Resource | v1 default limit |
|----------|------------------|
| Authoritative inbox refs per repository | 10,000 |
| New inbox commits admitted by one default pull | 100,000 |
| Inbox commit subject line | 512 bytes |
| Inbox event JSON body | 1 MiB before Git object compression |
| Additional Git parents / `parent_hashes.causal` | 32 |
| `parent_hashes.related` entries | 256 |
| Title fields | 512 bytes |
| Issue, pull request, and comment body fields | 64 KiB |
| Public signing key payload fields | 16 KiB |
| Principal, device, label, assignee, reviewer, workflow, and conclusion strings | 256 bytes each |
| Project, milestone, and kanban column names or slugs | 256 bytes each |
| Data Plane ref or object-id payload strings | 512 bytes each |
| Collection delta arrays in one event | 128 entries |
| Visible labels on one issue or pull request | 256 |
| Visible assignees or reviewers on one issue or pull request | 128 |
| Visible project placements on one issue | 256 |
| Visible kanban columns on one project | 128 |
| Snapshot tree size | 64 MiB |
| Retained snapshot refs per repository | 32 |

These are structural or domain limits, not serialization recommendations. An
event that exceeds a structural envelope limit MUST fail admission. An event that
is structurally valid but would exceed a per-object projection cardinality limit
MUST be domain-rejected and MUST NOT change the projection.

Implementations MAY expose explicit administrative flags to raise repository,
pull-admission, snapshot, or projection limits. They MUST NOT silently raise
defaults during normal sync.

## 6. Sync Protocol

### 6.1. Transport

Sync uses standard Git fetch and push over any Git protocol v2 transport (SSH, HTTPS, local path, bundles).

No custom protocol extensions are required.

### 6.2. Pull (Fetch + Admit)

A pull operation proceeds in two phases:

#### 6.2.1. Fetch Phase

```
git fetch <remote> \
  refs/gitomi/genesis:refs/gitomi/staging/<remote>/genesis \
  +refs/gitomi/inbox/*:refs/gitomi/staging/<remote>/inbox/*
```

The `+` prefix enables forced updates of staging refs. This is safe because staging refs are transient and not authoritative.

Default fetch MUST NOT include `refs/gitomi/runs/*`. Implementations MAY expose
an explicit diagnostic command for fetching run refs, subject to local retention
limits.

#### 6.2.2. Admission Phase

The staged genesis ref MUST be admitted before staged inbox refs. If
`refs/gitomi/genesis` is absent locally, the staged genesis commit MAY be
promoted after manifest and signature validation. If a local genesis ref exists,
a different staged genesis commit MUST be left in staging or copied to
quarantine and reported as a trust-root conflict.

For each staging inbox ref, the implementation MUST:

1.  Resolve the corresponding local inbox ref.
2.  Determine the relationship between the staged OID and the local OID:

    | Relationship          | Action |
    |-----------------------|--------|
    | Same OID              | Skip (already up to date). |
    | Staged is descendant  | Fast-forward: validate new commits, then update local ref. |
    | Local is descendant   | Skip (local is ahead; stale remote). |
    | Diverged              | Quarantine the staged head and report divergence. |
    | Local ref absent      | Create: validate all staged commits, then create local ref. |

3.  **Validate new commits**: For each new commit in first-parent order from the local base to the staged head:
    *   Verify the tree is the empty tree.
    *   Verify first-parent linkage (each commit's first parent is the preceding commit; root has no parent).
    *   Verify the commit signature.
    *   Parse and validate the event envelope.
    *   Verify `parent_hashes.log` and `parent_hashes.causal` against the Git
        parent list.

4.  If all commits pass, atomically update the local inbox ref.

A default pull MUST reject or defer admission when the local repository would
exceed 10,000 authoritative inbox refs after admission, or when more than 100,000
new inbox commits would be admitted in one operation.
Implementations MAY expose explicit administrative flags to raise these limits.

#### 6.2.3. Non-Fast-Forward Rejection

Inbox refs are append-only. A pull MUST NOT accept a staged ref that is not a
fast-forward of the local ref. Diverged or chain-invalid staged refs MUST be
placed under `refs/gitomi/quarantine/*` or otherwise recorded in a durable local
reject store so the same bad head does not permanently poison sync.

### 6.3. Push

```
git push <remote> \
  refs/gitomi/genesis:refs/gitomi/genesis \
  refs/gitomi/inbox/<principal>/<device>:refs/gitomi/inbox/<principal>/<device>
```

Default push MUST push the local genesis ref when present and the configured
local actor's own inbox ref, if that ref exists. It MUST NOT push locally
replicated inbox refs for other principals or other devices by default. This
prevents a replica from publishing third-party inbox heads to a remote that did
not already choose to receive them.

Implementations MAY expose an explicit administrative mirror or backup mode that
pushes additional inbox refs. Such a mode MUST be opt-in and SHOULD report the
exact ref set before pushing.

Force-push MUST NOT be used; if the remote rejects a non-fast-forward push, the
implementation MUST report the conflict. Quarantine refs MUST NOT be pushed by
default.

Default push MUST NOT include `refs/gitomi/runs/*`. Run diagnostics require an
explicit push path and remain subject to retention policy on both sides.

### 6.4. Bidirectional Sync

The default `gt sync` operation MUST perform pull then push, in that order. This ensures the local actor's inbox incorporates awareness of remote state (via additional parents) before pushing.

Command-line flags `--pull-only` and `--push-only` MUST be supported to run only one phase.

## 7. Append-Only Invariant

### 7.1. Rule

Once an inbox ref has been published (pushed to any remote or fetched by any other replica), its history is immutable.

*   Implementations MUST NOT force-push or rewrite `refs/gitomi/inbox/*` after publication.
*   A device MAY rewrite its own unpublished local inbox ref before first publication (e.g., to fix a signing error before the first push).
*   After publication, corrections MUST be expressed as new compensating events, not as history rewrites.

### 7.2. Enforcement

Implementations SHOULD detect non-fast-forward updates to inbox refs during pull and reject them. During push, the remote's built-in fast-forward check provides enforcement.

The `gt fsck` command MUST verify first-parent chain integrity for all inbox refs.

## 8. Validation Pipeline

### 8.1. Commit-Level Checks

When validating an inbox commit (during sync admission, fsck, or index rebuild), the following checks MUST be performed in order:

1.  **Empty tree**: The commit's tree OID MUST equal the empty tree.
2.  **First parent**: The commit's first parent MUST be the previous commit on the same inbox ref (or absent for root).
3.  **Signature**: The commit MUST have a valid Git signature verifiable against the configured signing backend.
4.  **Envelope**: The commit body MUST parse as valid JSON conforming to the event envelope schema (§5).
5.  **Repo ID**: The `repo_id` MUST match the repository's configured or observed `repo_id`.
6.  **Parent hashes**: `parent_hashes.log` and `parent_hashes.causal` MUST match the commit's first and additional parents, and `parent_hashes.causal` MUST NOT exceed the v1 additional-parent cap.
7.  **Resource limits**: The subject, JSON body, parent count, and
    `parent_hashes.related` count MUST satisfy the v1 limits.
8.  **Sequence uniqueness**: The `(actor.principal, actor.device, seq)` tuple MUST not duplicate any previously accepted event. Within a single principal-device inbox history, each event's `seq` MUST be greater than the previous event's `seq`; gaps are allowed.
9.  **Idempotency**: The `(repo_id, idempotency_key)` pair MUST not duplicate any previously accepted event.
10. **Event hash uniqueness**: The commit OID MUST not duplicate any previously accepted event hash.

### 8.2. Rejection Behavior

A structurally invalid, unverifiable, or chain-invalid commit MUST be rejected.
For sync admission, such a commit halts admission of the staged ref update, the
local inbox ref is not advanced, and the staged head MUST be quarantined or
recorded in a durable local reject store. For fsck, the error is reported but
scanning continues.

An event that is structurally valid and signed but unauthorized or invalid at
the domain layer MUST be preserved in the authoritative inbox log and marked as
rejected in the materialized index. Rejected domain events MUST NOT affect
projections but MUST remain auditable by event hash and rejection reason.

## 9. Local State Layout

### 9.1. Directory Structure

```
.git/gitomi/
├── config.toml       # repo-local Gitomi configuration
└── index.sqlite      # materialized projection cache
```

This directory and its contents are local, disposable caches. They MUST NOT be committed to Git or shared between replicas.

### 9.2. Config File

The config file uses TOML syntax with the following keys:

| Key         | Type    | Description |
|-------------|---------|-------------|
| `repo_id`   | string  | UUIDv7 identifying the logical repository. |
| `principal` | string  | The local actor's principal identity. |
| `device`    | string  | The local actor's device identifier. |
| `seq`       | integer | Cached last sequence number used by this device. Writers MUST recover from stale or invalid cached sequence values by scanning the local authoritative inbox ref. |

Example:

```toml
repo_id = "018f0000-0000-7000-8000-000000000001"
principal = "alice"
device = "laptop"
seq = 42
```

### 9.3. Index Database

The SQLite index materializes event data from inbox refs for fast querying. Its schema includes:

*   `meta`: Key-value table for schema version tracking.
*   `ref_heads`: Current OID for each indexed inbox ref (used for staleness detection).
*   `events`: Ordered event records extracted from inbox commits.
*   `projects` and `project_columns`: Current project metadata and kanban
    column projection.
*   `milestones`: Current milestone metadata.

The index is rebuilt from scratch when the ref heads diverge from the stored snapshot. See the product specification (§6.8) for rebuild rules.
