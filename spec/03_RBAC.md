# Gitomi RBAC Specification v1.0

## 1. Introduction

This document defines the normative role-based access control (RBAC) system for Gitomi. It specifies the role hierarchy, the permission matrix, the bootstrap trust model, and the reducer rules that derive effective permissions from the event DAG.

Initial authorization state is seeded from the signed genesis manifest at
`refs/gitomi/genesis`. Subsequent authorization state is event-sourced from
`acl.role_granted`, `acl.role_revoked`, `acl.delegation_granted`,
`acl.delegation_revoked`, `identity.device_added`, and
`identity.device_revoked` events as required by the product specification
(§5.3).

### 1.1. Conformance Keywords

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119.

### 1.2. Security Model Limitations

Gitomi RBAC is an admission and projection policy for signed Control Plane
events. It decides whether an event is allowed to change the local materialized
state.

Gitomi RBAC does protect:

*   whether accepted `issue.*`, `pull.*`, `project.*`, `milestone.*`,
    `comment.*`, `action.*`, `acl.*`, and `identity.*` events affect the
    projection;
*   whether a signing key is authorized for `actor.principal` and
    `actor.device` at the event's causal frontier; and
*   whether owners can grant or revoke roles and device bindings without
    violating the self-protection and privilege-escalation rules below.

Gitomi RBAC does not protect:

*   Git objects, packs, bundles, or working-tree bytes that have already reached
    another replica;
*   Data Plane refs exposed by the underlying Git transport;
*   ref-name ownership on ordinary Git remotes; or
*   auxiliary snapshot and run refs when they conflict with accepted inbox
    history.

Read permissions are therefore cooperative policy signals for future UI and
sync-server access. Confidentiality requires hosting, transport, or encryption
controls outside the v1 RBAC reducer.

## 2. Roles

### 2.1. Role Definitions

Gitomi defines five built-in roles, ordered from least to most privileged:

| Role         | Description                                                      |
|--------------|------------------------------------------------------------------|
| `reader`     | Read-only access to issues, pull requests, projects, milestones, and comments. |
| `reporter`   | Can open issues and add comments.                                |
| `contributor`| Can open issues and pull requests, comment, and manage own objects. |
| `maintainer` | Full read/write on issues, pulls, projects, milestones, and comments; can manage labels, assignees, project placements, and milestones on any object; can trigger action runs. |
| `owner`      | All maintainer permissions plus ACL and identity management.     |

Implementations MUST recognize these five role names. Implementations MAY define additional custom roles, but custom roles MUST NOT override the semantics of the built-in roles.

### 2.2. Role Hierarchy

Roles are strictly ordered:

```
owner > maintainer > contributor > reporter > reader
```

A principal with a higher role implicitly holds all permissions of every lower role. Implementations MUST enforce this inheritance when evaluating permissions.

### 2.3. Teams

Teams are repository-local RBAC groups. A team is identified by a ref-safe slug
and receives ACL grants through the canonical team principal `@<slug>`, for
example `@core`.

A user principal's effective write role is the highest ranked role from:

*   the user's direct ACL grant; and
*   all active team ACL grants for teams where the user is an active member.

Team membership does not bind signing keys and teams do not sign events. Device
authorization remains scoped to the user principal and device in the event
actor. v1 teams are not nested and are not issue assignees, pull reviewers, or
project members.

## 3. Permission Matrix

### 3.1. Permissions

The following table defines the minimum permission set and the lowest role required for each:

| Permission                  | reader | reporter | contributor | maintainer | owner |
|-----------------------------|--------|----------|-------------|------------|-------|
| `issue.read`                | ✓      | ✓        | ✓           | ✓          | ✓     |
| `pull.read`                 | ✓      | ✓        | ✓           | ✓          | ✓     |
| `project.read`              | ✓      | ✓        | ✓           | ✓          | ✓     |
| `milestone.read`            | ✓      | ✓        | ✓           | ✓          | ✓     |
| `comment.read`              | ✓      | ✓        | ✓           | ✓          | ✓     |
| `issue.open`                |        | ✓        | ✓           | ✓          | ✓     |
| `comment.add`               |        | ✓        | ✓           | ✓          | ✓     |
| `reaction.add`              |        | ✓        | ✓           | ✓          | ✓     |
| `reaction.remove_own`       |        | ✓        | ✓           | ✓          | ✓     |
| `notification.manage_own`   |        | ✓        | ✓           | ✓          | ✓     |
| `pull.open`                 |        |          | ✓           | ✓          | ✓     |
| `issue.edit_own`            |        |          | ✓           | ✓          | ✓     |
| `comment.edit_own`          |        |          | ✓           | ✓          | ✓     |
| `pull.edit_own`             |        |          | ✓           | ✓          | ✓     |
| `issue.edit_any`            |        |          |             | ✓          | ✓     |
| `pull.edit_any`             |        |          |             | ✓          | ✓     |
| `comment.edit_any`          |        |          |             | ✓          | ✓     |
| `comment.redact_any`        |        |          |             | ✓          | ✓     |
| `issue.manage_labels`       |        |          |             | ✓          | ✓     |
| `issue.manage_assignees`    |        |          |             | ✓          | ✓     |
| `issue.manage_projects`     |        |          |             | ✓          | ✓     |
| `issue.manage_milestones`   |        |          |             | ✓          | ✓     |
| `pull.manage_labels`        |        |          |             | ✓          | ✓     |
| `pull.manage_assignees`     |        |          |             | ✓          | ✓     |
| `pull.manage_reviewers`     |        |          |             | ✓          | ✓     |
| `pull.merge`                |        |          |             | ✓          | ✓     |
| `project.manage`            |        |          |             | ✓          | ✓     |
| `milestone.manage`          |        |          |             | ✓          | ✓     |
| `label.manage`              |        |          |             | ✓          | ✓     |
| `action.run_request`        |        |          |             | ✓          | ✓     |
| `notification.manage_any`   |        |          |             | ✓          | ✓     |
| `delegation.manage`         |        |          |             | ✓          | ✓     |
| `acl.grant`                 |        |          |             |            | ✓     |
| `acl.revoke`                |        |          |             |            | ✓     |
| `identity.manage`           |        |          |             |            | ✓     |

The `*.read` permissions are cooperative access-control signals for Gitomi
servers and user interfaces. They cannot revoke bytes already cloned through
Git, copied from a bundle, or retained in another replica. Operators that need
confidentiality MUST combine Gitomi with transport, hosting, or encryption
controls outside the v1 event format.

### 3.2. Own-Object Scope

Permissions suffixed with `_own` apply only when the actor principal matches the principal that created the object (the actor on the opening event). For `contributor`-level actors:

*   `issue.edit_own` permits `issue.title_set`, `issue.body_set`, and `issue.state_set` on issues the actor opened.
*   `pull.edit_own` permits `pull.title_set`, `pull.body_set`, `pull.state_set`, `pull.base_set`, and `pull.head_set` on pull requests the actor opened.
*   `comment.edit_own` permits `comment.body_set` and `comment.redacted` on comments the actor authored.

The creating event MUST be accepted and reachable from the event being
authorized. A current projection row is not sufficient evidence of authorship
for `_own` permissions if the creation event is absent from the causal frontier.

A `maintainer` or `owner` MAY edit any object regardless of authorship via the `_any` permissions.
`comment.edit_any` permits rewriting another principal's comment body.
`comment.redact_any` permits redacting another principal's comment, but it does
not imply permission to rewrite that comment body.

### 3.3. Event-to-Permission Mapping

Every event type MUST map to a required permission. The following defines the mapping:

| Event type                | Required permission       | Scope   |
|---------------------------|---------------------------|---------|
| `issue.opened`            | `issue.open`              | —       |
| `issue.updated`           | field-specific permissions below | mixed |
| `issue.title_set`         | `issue.edit_own` or `issue.edit_any` | object |
| `issue.body_set`          | `issue.edit_own` or `issue.edit_any` | object |
| `issue.state_set`         | `issue.edit_own` or `issue.edit_any` | object |
| `issue.priority_set`      | `issue.edit_own` or `issue.edit_any` | object |
| `issue.status_set`        | `issue.edit_own` or `issue.edit_any` | object |
| `issue.label_added`       | `issue.manage_labels`     | —       |
| `issue.label_removed`     | `issue.manage_labels`     | —       |
| `issue.assignee_added`    | `issue.manage_assignees`  | —       |
| `issue.assignee_removed`  | `issue.manage_assignees`  | —       |
| `issue.milestone_set`     | `issue.manage_milestones` | —       |
| `issue.project_added`     | `issue.manage_projects`   | —       |
| `issue.project_removed`   | `issue.manage_projects`   | —       |
| `issue.project_field_set` | `issue.manage_projects`   | —       |
| `issue.project_field_cleared` | `issue.manage_projects` | —       |
| `issue.reaction_added`    | `reaction.add`            | —       |
| `issue.reaction_removed`  | `reaction.remove_own`     | actor   |
| `pull.opened`             | `pull.open`               | —       |
| `pull.updated`            | field-specific permissions below | mixed |
| `pull.title_set`          | `pull.edit_own` or `pull.edit_any` | object |
| `pull.body_set`           | `pull.edit_own` or `pull.edit_any` | object |
| `pull.state_set`          | `pull.edit_own` or `pull.edit_any` | object |
| `pull.base_set`           | `pull.edit_own` or `pull.edit_any` | object |
| `pull.head_set`           | `pull.edit_own` or `pull.edit_any` | object |
| `pull.label_added`        | `pull.manage_labels`      | —       |
| `pull.label_removed`      | `pull.manage_labels`      | —       |
| `pull.assignee_added`     | `pull.manage_assignees`   | —       |
| `pull.assignee_removed`   | `pull.manage_assignees`   | —       |
| `pull.reviewer_added`     | `pull.manage_reviewers`   | —       |
| `pull.reviewer_removed`   | `pull.manage_reviewers`   | —       |
| `pull.merged`             | `pull.merge`              | —       |
| `pull.reaction_added`     | `reaction.add`            | —       |
| `pull.reaction_removed`   | `reaction.remove_own`     | actor   |
| `project.created`         | `project.manage`          | —       |
| `project.updated`         | `project.manage`          | —       |
| `project.column_added`    | `project.manage`          | —       |
| `project.column_removed`  | `project.manage`          | —       |
| `project.field_created`   | `project.manage`          | —       |
| `project.field_updated`   | `project.manage`          | —       |
| `project.field_removed`   | `project.manage`          | —       |
| `project.field_option_added` | `project.manage`       | —       |
| `project.field_option_updated` | `project.manage`     | —       |
| `project.field_option_removed` | `project.manage`     | —       |
| `project.view_created`    | `project.manage`          | —       |
| `project.view_updated`    | `project.manage`          | —       |
| `project.view_removed`    | `project.manage`          | —       |
| `milestone.created`       | `milestone.manage`        | —       |
| `milestone.updated`       | `milestone.manage`        | —       |
| `milestone.state_set`     | `milestone.manage`        | —       |
| `label.created`           | `label.manage`            | —       |
| `label.updated`           | `label.manage`            | —       |
| `label.deleted`           | `label.manage`            | —       |
| `comment.added`           | `comment.add`             | —       |
| `comment.body_set`        | `comment.edit_own` or `comment.edit_any` | object |
| `comment.redacted`        | `comment.edit_own` or `comment.redact_any` | object |
| `comment.reaction_added`  | `reaction.add`            | —       |
| `comment.reaction_removed`| `reaction.remove_own`     | actor   |
| `acl.role_granted`        | `acl.grant`               | —       |
| `acl.role_revoked`        | `acl.revoke`              | —       |
| `acl.delegation_granted`  | `delegation.manage`       | —       |
| `acl.delegation_revoked`  | `delegation.manage`       | —       |
| `identity.device_added`   | `identity.manage`         | —       |
| `identity.device_revoked` | `identity.manage`         | —       |
| `action.run_requested`    | `action.run_request`      | —       |
| `action.run_completed`    | `action.run_request`      | —       |
| `notification.subscribed` | `notification.manage_own` or `notification.manage_any` | principal |
| `notification.unsubscribed` | `notification.manage_own` or `notification.manage_any` | principal |
| `notification.read`      | `notification.manage_own` or `notification.manage_any` | principal |
| `notification.read_all`  | `notification.manage_own` or `notification.manage_any` | principal |
| `team.created`           | `identity.manage`         | —       |
| `team.updated`           | `identity.manage`         | —       |
| `team.member_added`      | `identity.manage`         | —       |
| `team.member_removed`    | `identity.manage`         | —       |

When the scope column says "object", the reducer MUST check whether `_own` is sufficient (actor authored the object) or whether `_any` is required.
When the scope column says "actor", the event is limited by event shape to the
actor's own projection entries and MUST NOT remove or mutate another
principal's reaction.
When the scope column says "principal", `notification.manage_own` is sufficient
only when `payload.principal` equals `actor.principal`; otherwise
`notification.manage_any` is required.

An `issue.opened` event that includes `payload.labels` MUST also require
`issue.manage_labels`. An `issue.opened` event that includes
`payload.assignees` MUST also require `issue.manage_assignees`. These
collection additions cannot bypass RBAC by being batched into the issue creation
event. An `issue.opened` event that includes `payload.milestone` MUST also
require `issue.manage_milestones`, and one that includes `payload.projects`
MUST also require `issue.manage_projects`.

`issue.updated` and `pull.updated` are batch update events. Each populated
payload field MUST satisfy the same permission as its single-purpose event; for
example, `issue.updated.payload.title` requires issue edit permission, while
`issue.updated.payload.labels_added` requires `issue.manage_labels`.

## 4. Bootstrap Trust

### 4.1. Genesis Manifest

A repository MUST bootstrap from the signed genesis manifest at
`refs/gitomi/genesis`. The manifest grants the initial `owner` role and binds the
initial owner device to public signing key material.

The genesis manifest is equivalent to these accepted facts at causal frontier
zero:

*   `acl.role_granted` for `owner.principal` with role `owner`;
*   `identity.device_added` for the owner's initial device; and
*   a signing-key binding for that `(principal, device)`.

No inbox event is allowed to create the initial owner or initial device from an
empty ACL state. This removes the circular dependency where
`acl.role_granted` required an authorized device before any device existed.

### 4.2. First Inbox Events

After genesis is accepted, the first event on every inbox ref MUST use the
genesis commit as its first Git parent, MUST use `parent_hashes.log` equal to
the empty string, and MUST use `parent_hashes.anchor` equal to the genesis
commit OID. The first inbox event from the genesis device is authorized against
the genesis ACL and identity state.

The first inbox event from any later device is also rooted at genesis, but it
MUST be authorized against the event's causal frontier. If the device or role
was established by inbox events after genesis, those authorization events MUST
be reachable through the root event's additional parents or related security
frontier. A root inbox event is therefore not self-authorizing merely because it
links to genesis.

### 4.3. Post-Bootstrap State

After genesis is accepted, all inbox events MUST satisfy the standard
authorization rules (§5). There is no self-authorizing ACL grant special case.

### 4.4. Missing or Conflicting Genesis

Before genesis is accepted, implementations MUST treat all principals and
devices as unauthorized. If a repository has inbox refs but no valid genesis ref,
those inbox events MUST NOT be admitted into the projection. An inbox root whose
first parent is missing, not the local genesis commit, or inconsistent with
`parent_hashes.anchor` MUST be rejected as chain-invalid.

A fetched genesis ref that conflicts with an existing local genesis ref is a
trust-root conflict and MUST NOT be auto-merged.

### 4.5. `gt init` Behavior

When a user runs `gt init`, the implementation SHOULD create and sign
`refs/gitomi/genesis`, then initialize the configured principal and device from
that manifest. It SHOULD NOT emit a self-authorizing genesis
`acl.role_granted` event.

## 5. ACL Reducer

### 5.1. State Model

The ACL projection MUST maintain a mapping:

```
principal → { role, grant_event_hash }
```

Each principal has at most one effective role at any point in time.

### 5.2. Reduction Rules

The ACL reducer MUST process `acl.role_granted` and `acl.role_revoked` events
using causal order first, then deterministic event-hash order for concurrent
events, consistent with the general reducer rules in the product specification
(§6.1):

*   **`acl.role_granted`**: Sets the effective role of `payload.principal` to `payload.role`.
*   **`acl.role_revoked`**: Requires `payload.role` to match the target principal's effective role at the event's causal frontier, then removes that effective role (the principal becomes unauthorized).

When concurrent `acl.role_granted` and `acl.role_revoked` events target the same principal:

1.  A causally later event wins over its ancestor.
2.  If the events are concurrent, the event with the lexicographically larger
    event hash wins.

### 5.3. Self-Protection Rules

To prevent accidental lockout:

*   An `owner` MUST NOT revoke their own `owner` role if they are the last remaining `owner`. Implementations MUST reject such events.
*   An `owner` MAY revoke their own role if at least one other `owner` exists in the current projection.

### 5.4. Privilege Escalation Prevention

*   A principal MUST NOT grant a role higher than their own effective role. An `acl.role_granted` event where `payload.role` outranks `actor`'s effective role MUST be rejected.
*   A principal MUST NOT revoke the role of a principal whose effective role is equal to or higher than their own, unless the actor is an `owner`. Specifically:
    *   An `owner` MAY revoke any role.
    *   A non-owner MUST NOT emit `acl.role_revoked` (only `owner` has `acl.revoke`).

### 5.5. Role Validation

The `payload.role` in `acl.role_granted` and `acl.role_revoked` MUST be one of
the five built-in role names. Events with an unrecognized role name MUST be
rejected by the reducer.

For `acl.role_revoked`, `payload.role` is a required audit assertion. It MUST
equal the target principal's effective role at the event's causal frontier.
Events that attempt to revoke a principal with no effective role, or with a
different effective role than `payload.role`, MUST be rejected.

### 5.6. Delegation Reducer

The ACL projection MAY also maintain scoped delegations:

```
(principal, device, capability, scope) → { key_fingerprint, public_key, grant_event_hash }
```

`acl.delegation_granted` delegates one bounded capability to a principal/device
pair and binds that delegated actor to explicit signing key material.
`acl.delegation_revoked` removes the active delegation for the same
`principal`, `device`, `capability`, and `scope`.

Delegations do not grant an RBAC role. They authorize only the capability named
in `payload.capability` and only when a reducer has explicit rules for that
capability. A delegated event MUST still be signed by the key fingerprint in the
active delegation at the event's causal frontier. If the actor also has an
ordinary role and device binding, normal role authorization applies first.

The v1 built-in delegated capability is `github.import` with scope `github:*`.
It authorizes a delegated bot actor to emit imported GitHub `issue.*`,
`pull.*`, and `comment.*` events supported by the GitHub importer. It does not
authorize ACL, identity, action, or arbitrary project/milestone management
events. A `maintainer` or `owner` MAY grant or revoke this delegation.

## 6. Identity Reducer

### 6.1. State Model

The identity projection MUST maintain a mapping:

```
principal → device → active { key_fingerprint, public_key, added_event_hash }
```

Implementations MUST also retain historical public keys and revocation metadata
needed to verify already accepted commits.

### 6.2. Reduction Rules

*   **`identity.device_added`**: Adds or rotates `payload.device` and its signing key for `payload.principal`.
*   **`identity.device_revoked`**: Removes `payload.device` from the active device set of `payload.principal`.

For each `(principal, device)`, the active key is a causal last-writer-wins
register. A causally later `identity.device_added` for the same device rotates
the active key to the new `signing_key`. Concurrent `identity.device_added`
events for the same device are resolved by deterministic event-hash order, and
the non-winning key MUST NOT be considered active after both events are observed.

Device revocation is remove-wins. A revocation for `(principal, device)` disables
the device regardless of the active key fingerprint. A re-add after revocation
MUST causally descend from the revocation and SHOULD use fresh key material.
Concurrent add and remove for the same device MUST resolve to revoked.

### 6.3. Self-Device Bootstrap

The genesis device is established by the genesis manifest. All later device
management for any principal requires the `identity.manage` permission (i.e.,
the `owner` role).

### 6.4. Key Rotation Workflow

To rotate a signing key on an existing device without changing the device id:

1.  Emit `identity.device_added` for the same `principal` and `device` with fresh
    `signing_key.public_key` and `signing_key.fingerprint`.
2.  Sign that rotation event with a key that is active at the event's causal
    frontier. This MAY be the old key being replaced.
3.  Rebuild the verifier's allowed-signers cache from genesis plus accepted
    identity events. The cache MUST include historical keys needed for old
    commits and MUST mark only the projected active key as authorizing future
    events for that device.

Multiple active keys for the same `(principal, device)` are not valid in the v1
projection. Operators that need an overlap window SHOULD add a second device id,
publish events from the new device, and then revoke the old device id after the
new path is verified.

### 6.5. Device Revocation Effects

When a device is revoked, events from that device that were accepted before the revocation remain in the projection. Only new events signed by the revoked device MUST be rejected.

Historical public keys MUST remain available to verifiers so old signed commits
can be checked after rotation or revocation. Implementations SHOULD rebuild
their SSH `allowedSignersFile` cache from genesis plus accepted identity events
instead of manually editing it as the authorization source of truth.

Authorization for a new event MUST be evaluated against the identity and ACL state at the event's causal frontier, not at the wall-clock time of ingestion.

## 7. Authorization Evaluation

### 7.1. Evaluation Order

When ingesting an event, the authorization check (product specification §5.4, step 4) MUST proceed as follows:

1.  **Resolve effective role**: Look up `actor.principal` in the ACL projection at the event's causal frontier, seeded by genesis.
2.  **Resolve device authorization**: If the actor has an effective role, verify `actor.device` is in the identity projection for `actor.principal` at the causal frontier, seeded by genesis. If not, reject the event.
3.  **Map event type to required permission**: Use the table in §3.3.
4.  **Check own-object scope**: For scoped permissions, look up the accepted creating event of the target object in the event's causal frontier to determine authorship.
5.  **Evaluate role authorization**: Accept if the effective role satisfies the required permission per the matrix in §3.1.
6.  **Evaluate delegation authorization**: If the actor has no effective role, look for an active delegation for `(actor.principal, actor.device)` whose capability explicitly authorizes the event type. Verify the commit signer fingerprint matches the delegated key. Accept only if the delegation authorizes that event; otherwise reject.

### 7.2. Causal Frontier

The "causal frontier" of an event is the set of accepted events reachable through its parent commits. Authorization MUST be evaluated against the projection state derived from this frontier, not from the global latest state.

This ensures that an actor who was authorized when they created the event is not retroactively rejected by a concurrent revocation they could not have observed.

Revocation events are the exception to pure causal-frontier authorization. A
replica that has already accepted an `acl.role_revoked`,
`acl.delegation_revoked`, or `identity.device_revoked` event for the actor,
delegation, or device being checked MUST apply a revocation-wins rule when
validating any later-ingested event: the revocation disables all prior or
concurrent grants/adds for that same authorization target, even when the event
under validation omitted the revocation from its parents. A grant, delegation,
or device-add becomes usable again only if it causally descends from the known
revocation. This freshness rule prevents a revoked key from remaining
indefinitely authorized by publishing events with stale cross-device frontiers.

Because v1 bounds cross-device additional parents, an event is not required to
name every observed inbox head. Security-sensitive events MUST still make the
latest observed related ACL or identity event for the same target reachable
through their bounded parent set when such an event exists, and SHOULD also
record that event in `parent_hashes.related`. Omitted unrelated heads are
treated as concurrent and MUST NOT expand or shrink the authorization frontier.

### 7.3. Rejection Behavior

Events that fail authorization MUST NOT affect the materialized projection. They MUST be preserved in the event log for auditability but marked as rejected.

Implementations SHOULD record the rejection reason (e.g., "insufficient role", "device revoked", "privilege escalation") for diagnostic purposes.

## 8. Materialized ACL Storage

### 8.1. SQLite Schema

Implementations MUST materialize the ACL and identity projections in the local index database (`.git/gitomi/index.sqlite`).

The following tables are REQUIRED:

```sql
CREATE TABLE acl_roles (
    principal TEXT PRIMARY KEY,
    role TEXT NOT NULL,
    grant_event_hash TEXT NOT NULL
);

CREATE TABLE acl_delegations (
    principal TEXT NOT NULL,
    device TEXT NOT NULL,
    capability TEXT NOT NULL,
    scope TEXT NOT NULL,
    key_fingerprint TEXT NOT NULL,
    public_key TEXT NOT NULL,
    grant_event_hash TEXT NOT NULL,
    PRIMARY KEY (principal, device, capability, scope, key_fingerprint)
);

CREATE TABLE identity_devices (
    principal TEXT NOT NULL,
    device TEXT NOT NULL,
    key_fingerprint TEXT NOT NULL,
    public_key TEXT NOT NULL,
    added_event_hash TEXT NOT NULL,
    revoked_event_hash TEXT,
    PRIMARY KEY (principal, device, key_fingerprint)
);
```

These tables are disposable caches rebuilt from the event log, consistent with the general cache-rebuild rule (product specification §6.6).

### 8.2. Rebuild Order

During cache rebuild, the reducer MUST process events in causal order:

1.  Process all `acl.role_granted`, `acl.role_revoked`,
    `acl.delegation_granted`, and `acl.delegation_revoked` events to build the
    ACL and delegation projection.
2.  Process all `identity.device_added` and `identity.device_revoked` events to build the identity projection.
3.  Re-evaluate authorization for all other events against the built ACL and identity projections.

In practice, since the event log is a DAG, implementations SHOULD topologically sort events and process them in a single pass, applying ACL/identity state changes and authorization checks incrementally.

## 9. Wire Format

### 9.1. ACL Event Payloads

`acl.role_granted`:

```json
{
    "principal": "bob",
    "role": "maintainer"
}
```

The corresponding event envelope uses `object.kind = "acl"` and
`object.id = "acl:bob"`.

`acl.role_revoked`:

```json
{
    "principal": "bob",
    "role": "maintainer"
}
```

The corresponding event envelope uses `object.kind = "acl"` and
`object.id = "acl:bob"`.

Note: `acl.role_revoked` removes the target principal's single effective role.
The required `role` field records the role the actor intended to revoke and MUST
match the target's effective role at the causal frontier; it is not a selective
partial revoke mechanism.

`acl.delegation_granted`:

```json
{
    "principal": "import-bot",
    "device": "github",
    "capability": "github.import",
    "scope": "github:*",
    "signing_key": {
        "scheme": "ssh",
        "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...",
        "fingerprint": "SHA256:..."
    }
}
```

The corresponding event envelope uses `object.kind = "acl"` and
`object.id = "acl:import-bot"`. The `signing_key` is the key that MUST sign
delegated events from `import-bot/github`.

`acl.delegation_revoked`:

```json
{
    "principal": "import-bot",
    "device": "github",
    "capability": "github.import",
    "scope": "github:*"
}
```

The corresponding event envelope uses `object.kind = "acl"` and
`object.id = "acl:import-bot"`.

### 9.2. Identity Event Payloads

`identity.device_added`:

```json
{
    "principal": "bob",
    "device": "workstation",
    "signing_key": {
        "scheme": "ssh",
        "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...",
        "fingerprint": "SHA256:..."
    }
}
```

The corresponding event envelope uses `object.kind = "identity"` and
`object.id = "identity:bob:workstation"`.

`identity.device_revoked`:

```json
{
    "principal": "bob",
    "device": "workstation"
}
```

The corresponding event envelope uses `object.kind = "identity"` and
`object.id = "identity:bob:workstation"`.

## 10. CLI Surface

### 10.1. Commands

Implementations SHOULD provide the following commands:

*   `gt acl grant <principal> <role>`: Emit an `acl.role_granted` event.
*   `gt acl revoke <principal>`: Emit an `acl.role_revoked` event containing the principal's current effective role.
*   `gt acl list`: Display the current ACL projection.
*   `gt identity add-device <principal> <device>`: Emit an `identity.device_added` event.
*   `gt identity revoke-device <principal> <device>`: Emit an `identity.device_revoked` event.
*   `gt identity list`: Display the current identity projection.

### 10.2. Pre-Flight Checks

Before emitting an ACL or identity event, the CLI MUST:

1.  Verify the current user holds a sufficient role for the operation.
2.  Validate the target role name (for grants).
3.  Check self-protection rules (§5.3).
4.  Check privilege escalation rules (§5.4).

If any check fails, the CLI MUST refuse to create the event and report the reason.
