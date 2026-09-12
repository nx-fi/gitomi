# ADR 002: Claims With Optional Orchestration

Status: Accepted product and implementation direction; the corresponding CLI
features and normative protocol amendments are not yet implemented.

Date: 2026-09-12

## Context

Gitomi serves humans and autonomous agents, including agents working offline in
separate worktrees. The product's primary purpose is signed collaboration with
no central service ([product §1](../01_PRODUCT.md#1-introduction)). Agent
pipelines are an important consumer: they adapt existing local agent tools,
provide execution policy, and support cancellation
([pipelines §1–§3](../07_AGENT_PIPELINES.md#1-purpose),
[adapter operations](../07_AGENT_PIPELINES.md#82-required-adapter-operations)).

An orchestrator is increasingly likely, but is not guaranteed. Claims must be
useful to a single adopter and offer Git hooks independent of the agent tool
([claims §17](../08_CLAIMS.md#17-enforcement-and-graceful-degradation)).
Orchestrators, standalone agents, and humans can also coexist in one repository.

Two gaps were identified during implementation: `claims.admin` has no defined
role or delegation scope, and non-empty re-rooting has no authentication format
for carrying other holders' claims into a parentless commit. These are product
and engineering decisions; users need not design the authorization protocol.

## Decision

### Coordination works without an orchestrator

The single ledger ref and its CAS remain the serialization mechanism. Every
participant uses the same acquisition, renewal, fencing, and release rules.
Starting a pipeline, creating a worktree, or naming a run does not confer
authority over other claims. Ordinary claims need no orchestrator approval.

Each concurrently editing worker gets its own `run_id`, retained across that
worker's claim calls and Git processes. A pipeline can associate these worker
IDs with its overall run in diagnostic state. Giving parallel workers the same
holder/run triple would exempt them from one another's conflict checks.
Run IDs provide cooperative isolation; separate signing identities are needed
when workers must have different signing authority.

The next enforcement feature is local supervised execution with a fencing token
and a deadline watchdog. The CLI provides this for standalone use; a pipeline
adapter may supply equivalent supervision. The supervisor must remain effective
while the worker is blocked or paused. Unsupported cancellation must refuse a
gated operation whose duration cannot be bounded within the lease.

An orchestrator stops a worker and confirms it has stopped before releasing its
lease. If it cannot establish that, it lets the lease expire. Administrative
revocation blocks renewal and preserves the remaining exclusion window. None of
these paths require a remote fetch at the fence.

### Claim administration follows existing RBAC

Assign `claims.admin` to `maintainer` and `owner`, including effective roles
inherited through teams. This follows the existing treatment of managing other
actors' objects, requesting workflow runs, and managing delegations
([RBAC §3.1](../03_RBAC.md#31-permissions)). Requiring ownership would make
routine operational recovery depend on the role reserved for ACL and identity
management.

Support explicit, key-bound `claims.admin` delegations through the existing ACL
delegation mechanism, with two exact scopes:

| Scope | Authority |
| --- | --- |
| `claims:run:<UUIDv7>` | Revoke claims whose `holder.run_id` equals this worker ID in this repository. |
| `claims:*` | Revoke claims in this repository, including claims with an empty run ID. |

Prefer a worker scope for an orchestrator managing a specific worker. Maintainers
and owners may grant or revoke these delegations. A delegated administrator
cannot grant onward authority or widen its scope. The delegation binds the
principal, device, and exact signing key; it grants no general role, no right to
renew as another holder, and no authority to rewrite claim records.

The run scope is an exact claim selector, not proof that the administrator
created that run. A grant must explicitly name the scope. Repository identity
continues to bind every signed operation, so a delegation does not cross repos.

A steal requires an explicit operator command or an already authorized workflow
policy. A conflict alone never triggers automatic stealing. Existing unattended
workflow policy can authorize that action without a new human prompt for each
lease ([pipeline permissions](../07_AGENT_PIPELINES.md#14-permissions-and-approvals)).

An authorized steal changes only `revoked: false` to `true`, including when the
administrator shares a signing device with the target worker. It preserves the
holder, sequence, paths, deadline, acquisition time, and original reason. Its
own explanation belongs in the signed steal action as audit data. It does not
free paths immediately. The normative amendment must distinguish this action
from ordinary holder modifications, which advance the sequence.

Authorization evidence must be bound to the signed administrative operation.
New administrative writes must honor current revocations; later role or key
changes must not retroactively invalidate an already admitted ledger history.
Implementing this requires an explicit authorization-evidence format using
accepted ACL/identity history. It must not route claim commits through the inbox
reducer or treat an arbitrary old grant as current authority.

### Initial compaction waits for an empty ledger

Implement re-rooting only when the verified ledger contains no claim records.
Expired records are first removed through ordinary signed reap operations, with
the full skew allowance. Compaction itself removes no records.

The operation reads and validates the current head, creates a signed parentless
commit with exactly the same Git tree OID, and replaces the ledger by CAS against
that exact head. If a concurrent acquisition wins, compaction re-reads and
defers while claims remain. Any accepted signing device may perform this empty
state maintenance; it does not require an orchestrator or `claims.admin`.

The new root uses the ordinary repository/writer/timestamp delta envelope with
`actions: []`. The implementation must allow that empty diff only for an empty
root, without manufacturing an acquisition or reinterpreting retained records.
The root still requires normal signature and identity verification. Comparing
and swapping the verified old head is essential: a valid signature on an empty
tree alone does not authorize replacing a non-empty ledger.

Above the history threshold, automatic single-store compaction is deferred
until the ledger becomes empty. An explicit compaction request against a
non-empty ledger explains that condition and leaves claims intact. No lease is
revoked or released merely to compact history. Federated re-rooting remains
outside the initial implementation; ordinary sync must not acquire a general
exception to its fast-forward rule.

Non-empty re-rooting is deferred until a separate design supplies verifiable
claim provenance and completeness. Accepting an administrator's signature as
authority for every retained or omitted claim would broaden trust and could
remove exclusion beneath a live worker. Keeping a replaced commit OID in JSON
alone would not solve this: Git does not retain referenced history through JSON
strings, and a cold verifier would still need that history.

## Consequences and Delivery

Standalone users have the complete coordination path. Orchestrators can add
assignment, supervision, and narrowly delegated recovery without becoming a
required service or a special signing authority.

Empty-ledger compaction trades storage reclamation during uninterrupted activity
for a small, verifiable implementation. A busy repository retains its history;
an optional verified-head cache can reduce repeated verification costs while
remaining disposable. Cache loss must fall back to validation from refs.

Delivery order is supervised execution, claim administration with explicit
authorization evidence, then empty-ledger compaction and verification caching.
The decisions above resolve the product questions; wire-format and code changes
must be implemented and tested together. The existing CLI does not yet implement
these new features.

Before changing the normative authorization or transition rules, update
`03_RBAC.md` and `08_CLAIMS.md` and the relevant formal models. Run
`just formal-claims` and `just formal-federated`, retaining the unsafe-steal
counterexample. The existing bounded checks abstract away signatures, RBAC
evidence, and Git history; they do not prove the new authorization encoding.
Integration tests must cover those concrete boundaries as well as the modelled
lease-state transitions.
