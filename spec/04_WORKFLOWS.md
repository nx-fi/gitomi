# Gitomi Workflows Specification v1.0

## 1. Introduction

This document defines Gitomi's workflow automation model. The workflow system
is the substrate that runs agent pipelines (see
[`07_AGENT_PIPELINES.md`](07_AGENT_PIPELINES.md)) and the proposed-effects
approval gate: it is what lets an agent's work be deterministically executed,
gated, signed, and admitted into the Control Plane event log. Ordinary
command automation and container jobs reuse the same engine.

It separates the Gitomi-native workflow orchestration layer from
backend-specific execution pipelines so that agentic workflows, command
automation, and container jobs share the same local-first event, permission,
run, and output model.

Gitomi workflows are not a GitHub Actions clone. The primary backend class is
`agent`; the `shell` and `container` backends are general-purpose execution.
GitHub Actions-style workflow files MAY be supported as an adapter for teams
whose existing CI happens to be expressible that way, but Gitomi MUST NOT
make GitHub runner quirks the semantic center of the workflow system.

### 1.1. Conformance Keywords

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be
interpreted as described in RFC 2119.

## 2. Design Goals

Gitomi workflows MUST support:

*   event-triggered automation from Data Plane and Control Plane events;
*   scheduled automation, including cron-like triggers;
*   backend-pluggable execution for shell, container, and agent runners;
*   versioned workflow definitions stored with the code they govern;
*   durable run requests and run results stored as signed Control Plane events;
*   ref-backed logs, intermediate outputs, final outputs, and artifacts; and
*   local-first operation without requiring a central workflow service.

Gitomi workflows SHOULD support GitHub Actions-compatible workflow discovery and
execution for common cases. They are not required to implement the full GitHub
Actions expression language, runner images, marketplace behavior, hosted-service
permissions, or edge-case semantics.

## 3. Core Concepts

### 3.1. Workflow

A workflow is a Gitomi orchestration document. It declares:

*   when automation is eligible to run;
*   filters that narrow those triggers;
*   the permissions requested by the automation;
*   the jobs to execute; and
*   the backend or pipeline used by each job.

Gitomi owns workflow orchestration. Execution backends own backend-specific
pipeline internals.

### 3.2. Pipeline

A pipeline is a backend-specific package referenced by a workflow job. A
pipeline MAY contain multiple internal steps, prompts, tool declarations, model
configuration, retries, and backend policies.

Gitomi MUST treat a pipeline as an execution backend artifact. Gitomi MAY parse
pipeline metadata required for permission checks and UI display, but it MUST NOT
require every backend to expose the same internal step model.

### 3.3. Backend

A backend is an executor implementation. Standard backend kinds are:

| Backend | Purpose |
|---------|---------|
| `shell` | Run local commands directly on the runner host or in a controlled worktree. |
| `container` | Run commands or pipeline steps inside one or more containers. |
| `agent` | Run an agentic pipeline with declared inputs, tools, permissions, and outputs. |
| `github-actions` | Adapt a supported subset of GitHub Actions-style workflows or delegate to a compatible runner. |

Implementations MAY define additional backend kinds. Unknown backend kinds MUST
cause the job to be skipped or failed with a structured conclusion; they MUST
NOT be silently treated as shell commands.

### 3.4. Run

A run is a durable invocation of a workflow at a specific workflow source state
and target code state. A run begins with a signed run-request event and ends
when one or more attempts produce terminal results.

### 3.5. Attempt

An attempt is one concrete execution of a run by one runner. Multiple attempts
MAY exist for a run because of retries, reruns, local duplicate scheduling, or
multiple replicas attempting the same run.

Implementations MUST retain enough attempt identity in diagnostic metadata to
distinguish attempts even when the durable v1 event family records only a
run-level completion.

### 3.6. Artifact, Log, and Output

Logs, traces, intermediate outputs, and artifacts are diagnostic run data. They
SHOULD be stored in `refs/gitomi/runs/<runner-id>/<run-id>` and MUST NOT be
treated as authoritative when they conflict with accepted inbox events.

Final workflow effects that change collaboration state, such as comments,
labels, review records, status records, or patches, MUST be represented by
normal signed Gitomi events.

## 4. Definition Locations

### 4.1. Native Workflow Files

Native Gitomi workflow definitions MUST be read from:

```
.gitomi/workflows/*.yml
.gitomi/workflows/*.yaml
```

Workflow files live in the Data Plane and are versioned with the repository.
They SHOULD be reviewed like source code. Implementations MUST NOT require full
workflow definitions to be stored as Control Plane events.

### 4.2. Pipeline Packages

Native pipeline packages SHOULD be stored under:

```
.gitomi/pipelines/<pipeline-name>/
```

A pipeline package SHOULD include a manifest named `pipeline.yml` or
`pipeline.yaml`. Backend-specific files such as prompts, tool definitions,
schemas, scripts, and policy files SHOULD be stored within the same package
directory unless the backend explicitly supports external content-addressed
references.

Example package:

```
.gitomi/pipelines/code-review/
|-- pipeline.yml
|-- prompts/review.md
|-- tools.yml
`-- policy.yml
```

### 4.3. GitHub Actions Adapter

Implementations MAY also discover GitHub Actions-style files from:

```
.github/workflows/*.yml
.github/workflows/*.yaml
```

Such files MUST be treated as an input dialect that compiles to the same
internal workflow plan model as native Gitomi workflows. Implementations MAY
support only a documented subset.

### 4.4. Control Plane Policy

Control Plane events MAY enable, disable, approve, revoke, request, cancel, or
rerun workflows. They SHOULD NOT contain full workflow definitions.

This keeps workflow bodies diffable, reviewable, and tied to the target code
state while leaving authority and operational decisions in the signed event log.

## 5. Native Workflow Document

### 5.1. Minimum Shape

A native workflow document MUST be a YAML mapping. The following top-level
fields are defined:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Human-readable workflow name. |
| `on` | yes | Trigger declarations. |
| `permissions` | no | Requested Gitomi permissions. |
| `source` | no | Workflow and target source policy. |
| `jobs` | yes | Job declarations keyed by job id. |

Example:

```yaml
name: PR review

on:
  pull.opened:
  pull.updated:
    paths:
      - "cli/**"
      - "spec/**"

permissions:
  contents: read
  pulls: write
  comments: write

source:
  workflow_from: base
  code_from: head

jobs:
  review:
    backend: agent
    uses: .gitomi/pipelines/code-review
    with:
      severity: normal
      post_comment: true
```

### 5.2. Jobs

Each job MUST be a YAML mapping. The following fields are defined:

| Field | Required | Description |
|-------|----------|-------------|
| `backend` | yes | Backend kind such as `shell`, `container`, `agent`, or `github-actions`. |
| `uses` | backend-specific | Pipeline package, action, image, or executor reference. |
| `needs` | no | List of job ids that must finish first. |
| `if` | no | Boolean condition evaluated against the normalized event context. |
| `with` | no | Backend input mapping. |
| `env` | no | Environment values passed to command-like backends. |
| `timeout` | no | Maximum job runtime. |
| `permissions` | no | Job-level permission override or reduction. |

Unknown job fields SHOULD be rejected unless the selected backend explicitly
declares that it owns those fields.

### 5.3. Internal Workflow Plan

Implementations SHOULD compile workflow files into an internal plan before
execution:

```text
WorkflowPlan
  id
  name
  source_path
  source_oid
  triggers[]
  permissions
  jobs[]

JobPlan
  id
  backend
  uses
  needs[]
  condition
  inputs
  permissions
```

All workflow dialects, including native Gitomi workflows and supported GitHub
Actions-style files, SHOULD use this same internal representation.

## 6. Triggers

### 6.1. Normalized Event Names

Gitomi workflow matching operates on normalized event names. Implementations
MUST recognize at least:

| Event | Meaning |
|-------|---------|
| `push` | A selected Data Plane ref changed. |
| `pull.opened` | A pull request was opened. |
| `pull.updated` | A pull request's source, target, metadata, or discussion changed. |
| `pull.merged` | A pull request was merged. |
| `issue.opened` | An issue was opened. |
| `issue.updated` | An issue's metadata changed. |
| `comment.added` | A comment was added. |
| `workflow.manual` | A user or bot explicitly requested a workflow. |
| `workflow.schedule` | A scheduler slot became due. |

Implementations MAY expose additional event names. Event names SHOULD follow the
`family.action` form for Control Plane events.

### 6.2. Trigger Forms

The `on` field MAY use scalar, array, or mapping forms.

```yaml
on: push
```

```yaml
on: [push, pull.opened]
```

```yaml
on:
  push:
    branches: ["main"]
    paths: ["cli/**"]
  pull.updated:
    paths_ignore: ["docs/**"]
```

### 6.3. Filters

Implementations SHOULD support the following filters where they are meaningful:

| Filter | Description |
|--------|-------------|
| `branches` | Include branch names or glob patterns. |
| `branches_ignore` | Exclude branch names or glob patterns. |
| `paths` | Include changed paths or glob patterns. |
| `paths_ignore` | Exclude changed paths or glob patterns. |
| `types` | Include event action types. |
| `actors` | Include actor principals. |
| `labels` | Include issue or pull labels. |

Filters MUST be evaluated deterministically against the normalized event
context. If a filter cannot be evaluated for an event type, the implementation
SHOULD treat the workflow as not matching and SHOULD record a diagnostic reason.

### 6.4. Schedule Triggers

Scheduled workflows are declared under `on.schedule`:

```yaml
on:
  schedule:
    - cron: "0 9 * * 1"
      timezone: "UTC"
```

Implementations MUST support five-field POSIX cron syntax. Timezone support is
OPTIONAL; if omitted, schedules MUST be interpreted in UTC.

A due schedule slot is normalized to the event name `workflow.schedule`.
Schedulers SHOULD include a stable schedule slot key in the run request payload,
derived from the workflow source, workflow path, cron expression, timezone,
target ref or target OID, and scheduled instant.

Because Gitomi is local-first, multiple replicas MAY independently observe the
same schedule slot. Reducers and user interfaces SHOULD group duplicate
schedule-derived runs by their schedule slot key. Operators that require exactly
one scheduled execution MUST configure a single authoritative runner or an
external coordination mechanism.

## 7. Source Policy

### 7.1. Workflow Source and Target Source

The workflow source is the commit from which the workflow and pipeline
definitions are loaded. The target source is the commit or ref being tested,
reviewed, analyzed, or modified.

For push-like events, the default policy is:

```yaml
source:
  workflow_from: target
  code_from: target
```

For pull-request events, the default policy SHOULD be:

```yaml
source:
  workflow_from: base
  code_from: head
```

This allows trusted workflow definitions from the base branch to operate on the
untrusted pull-request head.

### 7.2. Untrusted Workflow Changes

Implementations MUST NOT grant write permissions to a workflow definition loaded
from an untrusted pull-request head unless an authorized principal explicitly
approves that workflow source.

An implementation MAY allow untrusted head-defined workflows to run with reduced
read-only permissions. The reduced permission set MUST be visible in the run
metadata and completion summary.

## 8. Backend Contract

### 8.1. Inputs

Gitomi invokes a backend with:

*   the run id;
*   the attempt id;
*   the normalized trigger event;
*   the target source OID and optional ref;
*   the workflow source OID and path;
*   the selected job plan;
*   the effective permission grant;
*   a directory or object reference for backend outputs; and
*   implementation-defined local runner configuration.

Backends MUST treat the workflow source OID and target source OID as immutable
inputs. If they need a working tree, they SHOULD request or create a detached
worktree at the target source OID.

### 8.2. Results

A backend MUST return:

*   a conclusion;
*   structured outputs;
*   artifact references, if any;
*   log references, if any; and
*   published Gitomi event hashes, if the backend created collaboration effects.

Valid conclusions are `success`, `failure`, `cancelled`, `skipped`, `neutral`,
`timed_out`, and `action_required`.

### 8.3. Shell and Container Backends

Shell and container backends MAY expose a simple `steps` model:

```yaml
jobs:
  test:
    backend: container
    image: ziglang/zig:latest
    steps:
      - run: zig build test
      - run: zig fmt --check .
```

Implementations SHOULD keep this model intentionally smaller than GitHub
Actions. They SHOULD document supported fields instead of accepting arbitrary
GitHub Actions syntax.

### 8.4. Agent Backend

The agent backend MUST treat the referenced pipeline package as the owner of the
agentic pipeline. Gitomi owns the run identity, trigger context, target source,
permission grant, and output publication contract.

An agent pipeline SHOULD declare:

*   required inputs;
*   internal agent steps;
*   prompt files;
*   tool or capability requirements;
*   write actions that require approval;
*   output schemas; and
*   artifact retention policy.

Example pipeline manifest:

```yaml
name: code-review

inputs:
  pull:
  diff:
  changed_files:

steps:
  - id: inspect
    agent: reviewer
    prompt: prompts/review.md

  - id: summarize
    agent: reviewer
    needs: [inspect]

outputs:
  review_comment: steps.summarize.comment
```

Agent backends MUST NOT publish comments, labels, patches, commits, or other
Gitomi effects unless the effective permission grant allows that effect.
Backends SHOULD require explicit approval for high-impact effects such as
merging, closing objects, force-pushing, or editing broad path sets.

## 9. Run Events

### 9.1. Semantic Events

The semantic workflow event model contains:

| Semantic event | Required | Description |
|----------------|----------|-------------|
| `workflow.run_requested` | yes | A workflow run has been requested. |
| `workflow.run_started` | no | A runner started an attempt. |
| `workflow.job_started` | no | A job started within an attempt. |
| `workflow.job_completed` | no | A job completed within an attempt. |
| `workflow.run_completed` | yes | A run or attempt reached a terminal conclusion. |
| `workflow.output_published` | no | A final output was published or linked. |
| `workflow.run_cancelled` | no | A requested run was cancelled before completion. |

Gitomi v1 already defines the wire event names `action.run_requested` and
`action.run_completed`. Implementations MAY continue to emit those names for
wire compatibility. When this document says `workflow.run_requested`, a v1
implementation MAY emit an equivalent `action.run_requested` event. When this
document says `workflow.run_completed`, a v1 implementation MAY emit an
equivalent `action.run_completed` event.

### 9.2. Run Request Payload

A run-request payload SHOULD include:

```json
{
  "run_id": "UUIDv7",
  "workflow": {
    "path": ".gitomi/workflows/review.yml",
    "name": "PR review",
    "source_oid": "commit oid"
  },
  "target": {
    "ref": "refs/heads/main",
    "oid": "commit oid"
  },
  "trigger": {
    "event_name": "pull.updated",
    "event_hash": "optional Gitomi event hash",
    "object_id": "optional object id",
    "slot_key": "optional schedule slot key"
  },
  "backend": {
    "kind": "agent",
    "uses": ".gitomi/pipelines/code-review"
  },
  "permissions": {},
  "inputs": {}
}
```

For v1 `action.run_requested` compatibility, implementations MAY use the
existing flat payload fields `workflow`, `target_ref`, `target_oid`,
`event_name`, and `gitomi_event_type`. Implementations that use the flat form
SHOULD add extension fields rather than losing source policy, backend, or
schedule-slot information.

### 9.3. Run Completion Payload

A run-completion payload SHOULD include:

```json
{
  "run_id": "UUIDv7",
  "attempt_id": "UUIDv7",
  "runner_id": "runner id",
  "conclusion": "success",
  "workflow": {
    "path": ".gitomi/workflows/review.yml",
    "source_oid": "commit oid"
  },
  "target": {
    "ref": "refs/heads/main",
    "oid": "commit oid"
  },
  "diagnostics": {
    "ref": "refs/gitomi/runs/local-runner/018f...",
    "oid": "tree or commit oid"
  },
  "outputs": {},
  "published_events": []
}
```

The completion event MUST summarize the durable result even when logs or
artifacts are later pruned. If a backend cannot write a completion event after
starting execution, the absence of completion remains visible as a pending or
unknown run.

### 9.4. Duplicate Completions

Reducers MUST tolerate multiple accepted completion events for the same run id.
Implementations SHOULD expose them as distinct attempts when attempt metadata is
available. If a single run-level conclusion must be displayed, it MUST be chosen
by deterministic reducer order and the non-selected completions MUST remain
auditable.

## 10. Run Refs

### 10.1. Ref Name

Run diagnostics SHOULD be stored under:

```
refs/gitomi/runs/<runner-id>/<run-id>
```

`<runner-id>` and `<run-id>` MUST be ref-safe path segments. The ref SHOULD
point to the latest diagnostic commit for that runner's view of the run.

### 10.2. Tree Layout

The tree referenced by a run diagnostic ref SHOULD use this layout:

```
run.json
attempts/
  <attempt-id>/
    manifest.json
    logs/
      job-<job-id>.log
    outputs/
      job-<job-id>.json
      final.json
    artifacts/
      ...
    traces/
      ...
```

`run.json` SHOULD contain run-level metadata, including the run id, workflow
path, workflow source OID, target OID, runner id, known attempts, and the latest
diagnostic schema version.

Each attempt `manifest.json` SHOULD contain the attempt id, start time,
completion time if known, backend kind, backend version, job list, conclusion,
and object ids of important logs, outputs, and artifacts.

### 10.3. Streaming and Retention

Implementations MAY stream logs by appending commits to the run diagnostic ref.
They MAY also update the ref in larger chunks for performance.

Run refs are auxiliary diagnostics. They MUST NOT be fetched or pushed by
default sync, MUST NOT be replayed by reducers, and MAY be deleted according to
retention policy. Implementations MUST bound retained diagnostic storage.

Final outputs that must remain durable after diagnostic pruning MUST be copied
into signed inbox events or referenced from a signed completion event by stable
content hash.

## 11. Scheduler and Runner State

### 11.1. Local State

Schedulers and runners SHOULD store disposable local state under:

```
.git/gitomi/workflows/
.git/gitomi/runner/
```

This state MAY include schedule cursors, local claims, backend caches, container
cache metadata, and temporary execution directories. It MUST be rebuildable or
discardable without changing repository truth.

### 11.2. Claims

A runner SHOULD create a local claim before executing a pending run. Local claims
reduce duplicate execution on one machine but are not authoritative across
replicas.

If distributed duplicate execution is undesirable, operators MUST configure a
single authoritative runner, an external lease service, or a workflow policy
that limits which principals may complete runs.

### 11.3. Runner Identity

Each runner SHOULD have a stable local runner id. The runner id SHOULD be stored
outside the working tree and SHOULD be included in diagnostic refs and
completion payloads.

Runner identity is not the same as Gitomi actor identity. Durable events MUST
still be signed by an authorized Gitomi principal/device.

## 12. Permissions and Security

### 12.1. Permission Grant

Each run MUST have an effective permission grant derived from:

*   repository RBAC;
*   workflow-requested permissions;
*   job-requested permissions;
*   source trust policy;
*   backend policy; and
*   any explicit approval events.

The effective grant MUST be no broader than what the signing actor or delegated
runner principal is authorized to perform.

### 12.2. Backend Enforcement

Backends MUST receive the effective grant and SHOULD enforce it locally. Gitomi
reducers MUST still validate all signed events produced by a backend. A backend
bug or bypass MUST NOT be sufficient to admit unauthorized effects into the
projection.

### 12.3. Agent Tooling

Agent backends MUST declare the tool classes they require. Tool classes SHOULD
distinguish read-only operations from mutating operations.

Examples:

| Tool class | Examples |
|------------|----------|
| `repo.read` | Read files, inspect diffs, inspect commit metadata. |
| `repo.write` | Create commits, edit files, propose patches. |
| `issue.write` | Add comments, edit labels, edit assignees. |
| `pull.write` | Add review comments, request reviewers, merge. |
| `workflow.write` | Request, cancel, or rerun workflows. |

High-impact tool classes SHOULD require explicit approval unless the workflow
source is trusted and the actor has granted the backend that authority.

## 13. Compatibility With Existing Actions Engine

The existing Gitomi actions engine maps naturally onto this specification:

*   `.github/workflows/*.yml` files are a `github-actions` workflow dialect.
*   `action.run_requested` is the v1 wire form of `workflow.run_requested`.
*   `action.run_completed` is the v1 wire form of `workflow.run_completed`.
*   `refs/gitomi/runs/<runner-id>/<run-id>` remains the diagnostic ref
    namespace.
*   `nektos/act` is one possible backend implementation, not the core workflow
    semantics.

Future implementations SHOULD prefer native `.gitomi/workflows/` definitions
for new Gitomi-specific automation and SHOULD keep GitHub Actions support as a
documented compatibility adapter.
