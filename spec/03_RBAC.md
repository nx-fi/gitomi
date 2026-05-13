# Gitomi RBAC Specification v1.0

## 1. Introduction

This document defines the normative role-based access control (RBAC) system for Gitomi. It specifies the role hierarchy, the permission matrix, the bootstrap trust model, and the reducer rules that derive effective permissions from the event DAG.

All authorization state is event-sourced from `acl.role_granted`, `acl.role_revoked`, `identity.device_added`, and `identity.device_revoked` events as required by the product specification (§5.3).

### 1.1. Conformance Keywords

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119.

## 2. Roles

### 2.1. Role Definitions

Gitomi defines five built-in roles, ordered from least to most privileged:

| Role         | Description                                                      |
|--------------|------------------------------------------------------------------|
| `reader`     | Read-only access to issues, pull requests, and comments.         |
| `reporter`   | Can open issues and add comments.                                |
| `contributor`| Can open issues and pull requests, comment, and manage own objects. |
| `maintainer` | Full read/write on issues, pulls, and comments; can manage labels and assignees on any object; can trigger action runs. |
| `owner`      | All maintainer permissions plus ACL and identity management.     |

Implementations MUST recognize these five role names. Implementations MAY define additional custom roles, but custom roles MUST NOT override the semantics of the built-in roles.

### 2.2. Role Hierarchy

Roles are strictly ordered:

```
owner > maintainer > contributor > reporter > reader
```

A principal with a higher role implicitly holds all permissions of every lower role. Implementations MUST enforce this inheritance when evaluating permissions.

## 3. Permission Matrix

### 3.1. Permissions

The following table defines the minimum permission set and the lowest role required for each:

| Permission                  | reader | reporter | contributor | maintainer | owner |
|-----------------------------|--------|----------|-------------|------------|-------|
| `issue.read`                | ✓      | ✓        | ✓           | ✓          | ✓     |
| `pull.read`                 | ✓      | ✓        | ✓           | ✓          | ✓     |
| `comment.read`              | ✓      | ✓        | ✓           | ✓          | ✓     |
| `issue.open`                |        | ✓        | ✓           | ✓          | ✓     |
| `comment.add`               |        | ✓        | ✓           | ✓          | ✓     |
| `pull.open`                 |        |          | ✓           | ✓          | ✓     |
| `issue.edit_own`            |        |          | ✓           | ✓          | ✓     |
| `comment.edit_own`          |        |          | ✓           | ✓          | ✓     |
| `pull.edit_own`             |        |          | ✓           | ✓          | ✓     |
| `issue.edit_any`            |        |          |             | ✓          | ✓     |
| `pull.edit_any`             |        |          |             | ✓          | ✓     |
| `comment.redact_any`        |        |          |             | ✓          | ✓     |
| `issue.manage_labels`       |        |          |             | ✓          | ✓     |
| `issue.manage_assignees`    |        |          |             | ✓          | ✓     |
| `pull.manage_labels`        |        |          |             | ✓          | ✓     |
| `pull.manage_assignees`     |        |          |             | ✓          | ✓     |
| `pull.manage_reviewers`     |        |          |             | ✓          | ✓     |
| `pull.merge`                |        |          |             | ✓          | ✓     |
| `action.run_request`        |        |          |             | ✓          | ✓     |
| `acl.grant`                 |        |          |             |            | ✓     |
| `acl.revoke`                |        |          |             |            | ✓     |
| `identity.manage`           |        |          |             |            | ✓     |

### 3.2. Own-Object Scope

Permissions suffixed with `_own` apply only when the actor principal matches the principal that created the object (the actor on the opening event). For `contributor`-level actors:

*   `issue.edit_own` permits `issue.title_set`, `issue.body_set`, and `issue.state_set` on issues the actor opened.
*   `pull.edit_own` permits `pull.title_set`, `pull.body_set`, `pull.state_set`, `pull.base_set`, and `pull.head_set` on pull requests the actor opened.
*   `comment.edit_own` permits `comment.body_set` on comments the actor authored.

A `maintainer` or `owner` MAY edit any object regardless of authorship via the `_any` permissions.

### 3.3. Event-to-Permission Mapping

Every event type MUST map to a required permission. The following defines the mapping:

| Event type                | Required permission       | Scope   |
|---------------------------|---------------------------|---------|
| `issue.opened`            | `issue.open`              | —       |
| `issue.title_set`         | `issue.edit_own` or `issue.edit_any` | object |
| `issue.body_set`          | `issue.edit_own` or `issue.edit_any` | object |
| `issue.state_set`         | `issue.edit_own` or `issue.edit_any` | object |
| `issue.label_added`       | `issue.manage_labels`     | —       |
| `issue.label_removed`     | `issue.manage_labels`     | —       |
| `issue.assignee_added`    | `issue.manage_assignees`  | —       |
| `issue.assignee_removed`  | `issue.manage_assignees`  | —       |
| `pull.opened`             | `pull.open`               | —       |
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
| `comment.added`           | `comment.add`             | —       |
| `comment.body_set`        | `comment.edit_own` or `comment.redact_any` | object |
| `comment.redacted`        | `comment.edit_own` or `comment.redact_any` | object |
| `acl.role_granted`        | `acl.grant`               | —       |
| `acl.role_revoked`        | `acl.revoke`              | —       |
| `identity.device_added`   | `identity.manage`         | —       |
| `identity.device_revoked` | `identity.manage`         | —       |
| `action.run_requested`    | `action.run_request`      | —       |
| `action.run_completed`    | `action.run_request`      | —       |

When the scope column says "object", the reducer MUST check whether `_own` is sufficient (actor authored the object) or whether `_any` is required.

## 4. Bootstrap Trust

### 4.1. Repository Initializer

A repository has no ACL state before its first event. The principal that creates the first `acl.role_granted` event in the repository is the **initializer**.

The initializer's first ACL event MUST grant the `owner` role to itself. This is a self-bootstrap: no prior authorization is required for this single event.

Formally:

1.  If the repository contains zero accepted `acl.role_granted` or `acl.role_revoked` events, the next valid `acl.role_granted` event is the **genesis grant**.
2.  The genesis grant MUST have `payload.principal` equal to `actor.principal`.
3.  The genesis grant MUST have `payload.role` equal to `owner`.
4.  If the genesis grant violates rule 2 or 3, it MUST be rejected.

### 4.2. Post-Bootstrap State

After the genesis grant is accepted, all subsequent events MUST satisfy the standard authorization rules (§5). There is no further special-casing.

### 4.3. Implicit Permissions Before Bootstrap

Before the genesis grant is accepted, implementations MUST treat all principals as having no permissions. Events other than the genesis grant that arrive before bootstrap MUST be rejected.

This means the very first event in a Gitomi repository MUST be a valid genesis `acl.role_granted`.

### 4.4. `gt init` Behavior

When a user runs `gt init`, the implementation SHOULD automatically emit the genesis `acl.role_granted` event granting `owner` to the configured principal. This ensures the repository is immediately usable.

## 5. ACL Reducer

### 5.1. State Model

The ACL projection MUST maintain a mapping:

```
principal → { role, grant_event_uuid, occurred_at }
```

Each principal has at most one effective role at any point in time.

### 5.2. Reduction Rules

The ACL reducer MUST process `acl.role_granted` and `acl.role_revoked` events using last-writer-wins semantics, consistent with the general reducer rules in the product specification (§6.1):

*   **`acl.role_granted`**: Sets the effective role of `payload.principal` to `payload.role`.
*   **`acl.role_revoked`**: Removes the effective role of `payload.principal` (the principal becomes unauthorized).

When concurrent `acl.role_granted` and `acl.role_revoked` events target the same principal:

1.  The event with the later `occurred_at` wins.
2.  Ties MUST be broken by `(actor.principal, event_uuid)` as specified in §6.1 of the product specification.

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

The `payload.role` in `acl.role_granted` MUST be one of the five built-in role names. Events with an unrecognized role name MUST be rejected by the reducer.

## 6. Identity Reducer

### 6.1. State Model

The identity projection MUST maintain a mapping:

```
principal → set of { device, added_event_uuid, occurred_at }
```

### 6.2. Reduction Rules

*   **`identity.device_added`**: Adds `payload.device` to the device set of `payload.principal`.
*   **`identity.device_revoked`**: Removes `payload.device` from the device set of `payload.principal`.

Device sets are Observed-Remove Sets. Concurrent add and remove of the same device MUST be resolved using the same LWW rules as ACL events (§5.2).

### 6.3. Self-Device Bootstrap

A principal's first `identity.device_added` event for its own device is self-attesting: it establishes the initial device binding. This event MUST still be signed, and the signing key MUST map to the claimed principal.

Subsequent device management for any principal requires the `identity.manage` permission (i.e., the `owner` role).

### 6.4. Device Revocation Effects

When a device is revoked, events from that device that were accepted before the revocation remain in the projection. Only new events signed by the revoked device MUST be rejected.

Authorization for a new event MUST be evaluated against the identity and ACL state at the event's causal frontier, not at the wall-clock time of ingestion.

## 7. Authorization Evaluation

### 7.1. Evaluation Order

When ingesting an event, the authorization check (product specification §5.4, step 4) MUST proceed as follows:

1.  **Resolve effective role**: Look up `actor.principal` in the ACL projection at the event's causal frontier. If the principal has no role, reject the event (except during bootstrap per §4).
2.  **Resolve device authorization**: Verify `actor.device` is in the identity projection for `actor.principal` at the causal frontier. If not, reject the event (except for self-device bootstrap per §6.3).
3.  **Map event type to required permission**: Use the table in §3.3.
4.  **Check own-object scope**: For scoped permissions, look up the creating event of the target object to determine authorship.
5.  **Evaluate**: Accept if the effective role satisfies the required permission per the matrix in §3.1. Reject otherwise.

### 7.2. Causal Frontier

The "causal frontier" of an event is the set of accepted events reachable through its parent commits. Authorization MUST be evaluated against the projection state derived from this frontier, not from the global latest state.

This ensures that an actor who was authorized when they created the event is not retroactively rejected by a concurrent revocation they could not have observed.

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
    grant_event_uuid TEXT NOT NULL,
    occurred_at TEXT NOT NULL
);

CREATE TABLE identity_devices (
    principal TEXT NOT NULL,
    device TEXT NOT NULL,
    added_event_uuid TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    PRIMARY KEY (principal, device)
);
```

These tables are disposable caches rebuilt from the event log, consistent with the general cache-rebuild rule (product specification §6.6).

### 8.2. Rebuild Order

During cache rebuild, the reducer MUST process events in causal order:

1.  Process all `acl.role_granted` and `acl.role_revoked` events to build the ACL projection.
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

`acl.role_revoked`:

```json
{
    "principal": "bob"
}
```

Note: `acl.role_revoked` removes whatever role the principal currently holds. The `role` field from the product specification's minimum payload (§4.6) is included for auditability but MUST NOT be used to selectively revoke — there is only one role per principal.

### 9.2. Identity Event Payloads

`identity.device_added`:

```json
{
    "principal": "bob",
    "device": "workstation"
}
```

`identity.device_revoked`:

```json
{
    "principal": "bob",
    "device": "workstation"
}
```

## 10. CLI Surface

### 10.1. Commands

Implementations SHOULD provide the following commands:

*   `gt acl grant <principal> <role>`: Emit an `acl.role_granted` event.
*   `gt acl revoke <principal>`: Emit an `acl.role_revoked` event.
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
