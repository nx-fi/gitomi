# Agent Pipelines

## 1. Purpose

Gitomi SHOULD orchestrate existing local coding agents instead of hosting raw
models directly. Local users already have agent harnesses such as Codex, Claude
Code, OpenCode, Aider, and other CLI-driven systems. Gitomi's role is to provide
a local-first agent pipeline runner that connects those harnesses to Gitomi
workflows, issues, pull requests, local indexes, worktrees, logs, and signed
outputs.

An agent pipeline is a state-machine graph of skill-defined agents. Each step
invokes an agent through an adapter, passes structured context, receives a
structured result, records traces, and dispatches to the next step by result.

This specification replaces a raw "local LLM" design. Direct Ollama or
OpenAI-compatible model calls MAY exist as one adapter implementation, but they
are not the central abstraction.

## 2. Design Goals

Agent pipelines MUST:

* Integrate with Gitomi's workflow/action run model.
* Invoke existing local agent harnesses through adapters.
* Define agent roles through skills, not bespoke prompt-only agent records.
* Support deterministic skill scripts and non-deterministic skill markdown.
* Pass structured messages between pipeline steps.
* Capture execution traces, final reports, and machine-readable results.
* Support loops, jumps, retries, max-visit limits, and go/no-go gates.
* Run in isolated worktrees by default.
* Support optional OCI container execution.
* Preserve local-first semantics: final collaboration effects MUST be signed
  Gitomi events, while pipeline logs and traces remain diagnostic state.

Agent pipelines SHOULD:

* Support adapters with different capabilities, such as session resume, turn
  limits, cost tracking, trace parsing, and skill injection.
* Surface pipeline runs in the web UI as a structured timeline rather than a
  generic chat transcript.
* Allow workflows to request an agent pipeline the same way they request shell,
  container, or GitHub-compatible jobs.
* Keep adapter-specific configuration local unless the repository explicitly
  versions a safe, reviewable pipeline definition.

## 3. Relationship to Workflows

Gitomi workflows already define an `agent` backend class. Agent pipelines are
the canonical implementation of that backend.

A native workflow job MAY reference an agent pipeline package:

```yaml
jobs:
  implement:
    backend: agent
    pipeline: code-change
    permissions:
      repo.read: true
      repo.write: true
      issue.write: false
```

The workflow layer owns:

* Trigger selection.
* Run requests and completions.
* Actor, permission, and approval policy.
* Attempt identity.
* Diagnostic refs and artifact retention.

The agent pipeline layer owns:

* Step graph execution.
* Agent adapter selection.
* Skill loading and context injection.
* Step result parsing.
* Trace collection.
* Step-to-step message passing.
* Worktree/container execution policy.

Reducers MUST NOT trust pipeline outputs directly. Any final effect that changes
Gitomi state, such as comments, labels, project updates, review records, or pull
request changes, MUST still be represented by ordinary signed Gitomi events and
validated by existing reducers.

## 4. Definition Locations

Agent pipeline packages SHOULD live in the data plane:

```text
.gitomi/pipelines/<pipeline-id>/pipeline.json
.gitomi/pipelines/<pipeline-id>/skills/
.gitomi/pipelines/<pipeline-id>/schemas/
.gitomi/pipelines/<pipeline-id>/policy.json
```

For small pipelines, implementations MAY also support:

```text
.gitomi/pipelines/<pipeline-id>.json
```

Pipeline definitions are reviewed source files. Local adapter credentials,
session caches, and execution traces MUST NOT be stored in these packages.

Local runner state SHOULD live under:

```text
.git/gitomi/agent-pipelines/
.git/gitomi/runner/
```

## 5. Pipeline JSON

An agent pipeline definition MUST be a JSON object.

Minimum shape:

```json
{
  "schema_version": 1,
  "id": "code-change",
  "name": "Code change",
  "steps": [
    {
      "id": "plan",
      "agent": "product.plan",
      "readonly": true,
      "on_result": {
        "PASS": { "jump": "implement" },
        "FAIL": { "jump": "abort" }
      }
    },
    {
      "id": "implement",
      "agent": "engineering.implementation",
      "max": 2,
      "commit_after": true,
      "on_result": {
        "PASS": { "jump": "review" },
        "FIX": { "jump": "implement" },
        "FAIL": { "jump": "abort" }
      }
    },
    {
      "id": "review",
      "agent": "engineering.review",
      "readonly": true,
      "on_result": {
        "PASS": { "jump": "complete" },
        "FIX": {
          "id": "review-fix",
          "agent": "engineering.fix",
          "max": 2,
          "commit_after": true,
          "on_result": {
            "PASS": { "jump": "review" },
            "FIX": { "jump": "implement" }
          }
        }
      }
    }
  ]
}
```

### 5.1 Step Fields

Each step MUST include:

| Field | Description |
| --- | --- |
| `id` | Step id, unique within the pipeline. |
| `agent` | Skill-defined agent id. |

Each step MAY include:

| Field | Description |
| --- | --- |
| `adapter` | Adapter id override, such as `codex`, `claude`, `opencode`, or `raw-openai-compatible`. |
| `max` | Maximum visits for this step. `0` or absent means implementation default. |
| `on_max` | Jump target when `max` is exceeded. |
| `readonly` | Step MUST leave no workspace changes. |
| `commit_after` | Runner SHOULD commit successful workspace changes after the step. |
| `enabled_by` | Runtime flag or workflow input required for this step. |
| `config` | Step-specific JSON passed to the skill and adapter. |
| `inputs` | Structured input selectors from workflow, page, issue, PR, parent output, or files. |
| `outputs` | Declared output keys expected from the step. |
| `on_result` | Result dispatch table. |
| `environment` | Execution environment policy. |
| `timeout_seconds` | Step timeout. |
| `cost_limit` | Optional cost budget if the adapter reports cost. |

### 5.2 Result Dispatch

Pipeline control flow is result-driven. A step result is a gate value such as:

```text
PASS
FAIL
FIX
SKIP
BLOCKED
UNKNOWN
```

`on_result` handlers MAY be:

```json
{ "jump": "next" }
```

or inline agent handlers:

```json
{
  "id": "validation-fix",
  "agent": "engineering.fix",
  "max": 2,
  "commit_after": true
}
```

Standard jump targets:

| Target | Meaning |
| --- | --- |
| `self` | Re-run current step. |
| `prev` | Return to the previous caller step. |
| `next` | Continue to the next top-level step. |
| `abort` | Stop the pipeline. |
| `<step-id>` | Jump to a named step. |
| `complete` | Finish successfully. |

The runner MUST bound loops with visit counts and SHOULD include a circuit
breaker for repeated non-terminal results.

## 6. Skills as Agent Definitions

The canonical agent definition is a skill package.

A skill package MAY contain:

```text
SKILL.md
scripts/
schemas/
assets/
references/
```

`SKILL.md` is the non-deterministic instruction surface. Scripts are the
deterministic execution surface. Schemas define structured inputs and outputs.

Gitomi SHOULD support skills from:

* Repository-local pipeline packages.
* User-local skill directories.
* Installed Codex-compatible skills.
* Built-in Gitomi skills.

### 6.1 Skill Metadata

Gitomi agent skills SHOULD declare front matter:

```yaml
---
id: engineering.review
description: Review code changes and decide whether to pass or request fixes.
mode: agent
valid_results: [PASS, FIX, FAIL, SKIP]
capabilities:
  - repo.read
  - test.read
readonly: true
inputs:
  schema: schemas/input.schema.json
outputs:
  schema: schemas/output.schema.json
deterministic_scripts:
  prepare: scripts/prepare.sh
  validate: scripts/validate-output.sh
---
```

The metadata defines the contract. The markdown body defines agent behavior.
Scripts MAY prepare context, validate output, transform messages, or run
deterministic checks.

### 6.2 Different From Interactive Skill Usage

Normal interactive skill usage is model-mediated and informal. Pipeline skill
usage MUST be structured:

* Inputs are materialized as JSON and files in the step run directory.
* Context variables are explicit.
* Outputs are validated against declared schemas when present.
* Gate results are parsed from structured output, not inferred from prose.
* Downstream steps consume declared outputs, not arbitrary transcript text.

## 7. Structured Message Passing

Every step receives an input envelope:

```json
{
  "pipeline_id": "code-change",
  "run_id": "0190...",
  "attempt": 1,
  "step_id": "review",
  "agent_id": "engineering.review",
  "workflow": {
    "event": "issue.updated",
    "object_kind": "issue",
    "object_id": "018f..."
  },
  "workspace": {
    "path": "workspace",
    "base_ref": "main",
    "head_ref": "agent/code-change-0190"
  },
  "context": {
    "issue": {},
    "pull": {},
    "page": {},
    "retrieval": []
  },
  "parent": {
    "step_id": "implement",
    "result": "PASS",
    "outputs": {},
    "report_path": "reports/implement.md"
  },
  "config": {}
}
```

Every step MUST produce a result envelope:

```json
{
  "agent_id": "engineering.review",
  "step_id": "review",
  "status": "success",
  "gate_result": "FIX",
  "summary": "Tests pass, but the public API lacks documentation.",
  "outputs": {
    "fix_instructions": "Document the new endpoint and add one regression test."
  },
  "artifacts": [
    { "kind": "report", "path": "reports/review.md" }
  ],
  "citations": [
    { "kind": "file", "path": "src/server.zig", "line": 128 }
  ],
  "errors": []
}
```

Adapters MAY produce native transcripts, but the runner MUST normalize them into
this envelope before dispatching the next step.

## 8. Agent Adapters

An adapter connects Gitomi to one concrete agent harness.

Examples:

* `codex`
* `claude-code`
* `opencode`
* `aider`
* `raw-openai-compatible`
* `raw-ollama`
* custom command adapters

Adapter configuration is local runner configuration unless the repository
explicitly versions safe adapter requirements.

### 8.1 Adapter Capability Descriptor

Each adapter MUST expose a capability descriptor:

```json
{
  "id": "codex",
  "command": "codex",
  "capabilities": {
    "sessions": true,
    "named_sessions": false,
    "turn_limit": true,
    "cost_reporting": false,
    "streaming_trace": true,
    "json_trace": true,
    "skill_injection": "plugin-dir",
    "workspace_sandbox": true,
    "approval_control": true,
    "model_control": true
  }
}
```

Capabilities SHOULD include:

| Capability | Meaning |
| --- | --- |
| `sessions` | Adapter can resume a prior conversation. |
| `named_sessions` | Runner can choose the session id. |
| `turn_limit` | Runner can bound turns or iterations. |
| `cost_reporting` | Adapter exposes token or currency cost. |
| `streaming_trace` | Adapter emits incremental events. |
| `json_trace` | Adapter emits machine-readable events. |
| `skill_injection` | Adapter can receive skills via plugin dir, prompt, files, or none. |
| `workspace_sandbox` | Adapter can enforce workspace boundaries itself. |
| `approval_control` | Adapter exposes permission/approval mode. |
| `model_control` | Adapter allows model selection. |

### 8.2 Required Adapter Operations

Adapters MUST implement:

* `init`: validate command availability and local authentication.
* `prepare`: materialize skill and input context.
* `invoke`: start a step.
* `resume`: continue a previous session when supported.
* `cancel`: terminate a running step.
* `parse_trace`: normalize native trace output.
* `parse_result`: produce the result envelope.
* `collect_usage`: report cost and token metrics when available.

Adapters SHOULD avoid passing secrets in process arguments. If an adapter needs
credentials, it SHOULD use the agent harness's existing local login state or
environment-scoped secrets.

## 9. Trace Model

The runner MUST keep adapter-native traces and normalized traces.

Recommended local layout:

```text
.git/gitomi/agent-pipelines/runs/<run-id>/
  pipeline.json
  input.json
  state.json
  steps/<step-id>/<attempt-id>/
    input.json
    result.json
    report.md
    trace.native.jsonl
    trace.normalized.jsonl
    stdout.log
    stderr.log
    usage.json
    artifacts/
```

Normalized trace events SHOULD include:

```json
{
  "time": "2026-05-20T12:00:00Z",
  "run_id": "0190...",
  "step_id": "review",
  "adapter": "codex",
  "type": "assistant_message",
  "content": "I found one missing test.",
  "metadata": {}
}
```

Common event types:

* `step_started`
* `adapter_invoked`
* `assistant_message`
* `tool_call`
* `tool_result`
* `file_changed`
* `command_started`
* `command_finished`
* `usage`
* `result_detected`
* `step_finished`
* `step_failed`

Trace data is diagnostic. It MAY be pruned by retention policy. Final durable
effects MUST be copied into signed Gitomi events or artifacts referenced by
signed completion events.

## 10. Execution Environments

Agent steps SHOULD run in isolated Git worktrees by default.

Supported environment modes:

| Mode | Description |
| --- | --- |
| `host` | Run adapter on the host in an isolated worktree. |
| `container` | Run adapter inside an OCI container with bind mounts. |
| `hybrid` | Run adapter host-side while deterministic tools run in containers. |

### 10.1 Host Mode

Host mode is simpler and works with existing authenticated agent CLIs. It is
also riskier. Host mode MUST enforce:

* Worktree boundary checks.
* Command allow/deny policy from workflow permissions.
* Readonly rollback for readonly steps.
* Clear warning for workflows that request write tools.

### 10.2 Container Mode

Container mode SHOULD be optional. It MUST NOT be required for ordinary local
usage, because existing agent CLIs often depend on host login state, editors,
credential helpers, sockets, and caches.

When container mode is used, Gitomi SHOULD communicate through bind-mounted run
directories rather than rsync loops. The container receives:

```text
/workspace      mounted agent worktree
/gitomi-run     mounted step run directory
/gitomi-skills  mounted read-only skill bundle
```

The runner writes `input.json` and skill files before launch. The container
writes `result.json`, traces, reports, and artifacts under `/gitomi-run`.

For interactive or resumable adapters, Gitomi MAY add a narrow control channel:

* stdio for one-shot adapters;
* a Unix domain socket mounted under the run directory; or
* a small localhost HTTP server bound only inside the container namespace.

File envelopes remain the canonical protocol. A socket or HTTP channel is an
optimization for streaming, cancellation, and live progress, not the source of
truth.

### 10.3 Container Security

Container mode SHOULD support:

* read-only skill mount;
* writable workspace mount scoped to one worktree;
* writable run directory;
* optional network disablement;
* explicit environment allowlist;
* no host Docker socket by default;
* no privileged container by default.

## 11. Context Injection

Context is produced by Gitomi, deterministic skill scripts, or upstream step
outputs. It MUST be explicit and bounded.

Sources MAY include:

* Workflow trigger payload.
* Current issue or pull request.
* Project view state.
* SQLite projection queries.
* Worktree diff.
* Merge conflict metadata.
* Previous step result envelope.
* Previous step report.
* User-supplied task text.
* Page context from the web UI.

Context injection mechanisms:

* JSON input envelope.
* Files referenced from the envelope.
* Template variables in skill markdown.
* Adapter-specific skill injection, such as plugin directories or prompt
  sections.

The runner MUST enforce maximum context bytes. If context is truncated, the
input envelope SHOULD include truncation metadata.

## 12. Web UI

Gitomi SHOULD expose agent pipelines as workflow runs, not as a chat window.

The web UI SHOULD show:

* Pipeline graph and current state.
* Step timeline.
* Adapter used per step.
* Skill used per step.
* Gate result per step.
* Cost and token metrics when available.
* Trace viewer with normalized events.
* Reports and artifacts.
* Pending approvals or go/no-go decisions.
* Proposed signed Gitomi effects before confirmation.

Page-aware shortcuts MAY start pipelines from the current page, such as:

* "Summarize these issues" -> readonly analysis pipeline.
* "Plan conflict resolution" -> readonly planning pipeline.
* "Resolve this pull request" -> write-capable pipeline requiring approval.
* "Review this change" -> readonly review pipeline.

These are pipeline launchers, not free-form model chats.

## 13. Settings and Credentials

Gitomi SHOULD NOT require users to configure raw model providers when a local
agent harness already manages authentication.

Local settings SHOULD configure:

* Installed adapters.
* Adapter command paths.
* Default adapter per capability.
* Optional model override per adapter when supported.
* Cost limits.
* Container image defaults.
* Environment variable allowlists.
* Skill search paths.

If a headless adapter requires a secret that is not handled by the harness,
Gitomi MAY store adapter credentials encrypted in local settings storage. Such
secrets are adapter credentials, not the pipeline abstraction. They MUST NOT be
rendered to the browser or written to Git.

## 14. Permissions and Approvals

Pipeline requested capabilities MUST map to workflow tool classes, such as:

* `repo.read`
* `repo.write`
* `issue.read`
* `issue.write`
* `pull.read`
* `pull.write`
* `workflow.read`
* `workflow.write`
* `network`

The effective grant is the intersection of:

* Workflow permissions.
* Pipeline requested permissions.
* Step requested permissions.
* Adapter capabilities.
* Actor/RBAC authority.
* Source trust policy.
* Explicit approval events.

Write-capable steps SHOULD require approval unless the workflow source is
trusted and policy explicitly allows unattended execution.

Readonly steps MUST be verified. If a readonly step leaves workspace changes,
the runner MUST either discard them and mark the step failed, or preserve them
only as diagnostic artifacts outside the worktree.

## 15. Integration With Gitomi Actions

Agent pipelines SHOULD be executable by:

```text
gt actions run
gt actions run-requested
gt actions daemon
```

The existing `backend: agent` job type SHOULD dispatch to the agent pipeline
runner. Run request and completion events SHOULD include:

* pipeline id and source commit;
* adapter ids used;
* effective permission grant;
* run id and attempt id;
* terminal conclusion;
* result summary;
* diagnostic ref or artifact references.

Pipeline internals MAY be stored only in diagnostic refs and local runner state.
Reducers MUST derive repository state from normal Gitomi events, not from
pipeline internals.

## 16. Failure Handling

The runner SHOULD classify failures as:

* `adapter_unavailable`
* `auth_missing`
* `permission_denied`
* `timeout`
* `cost_limit_exceeded`
* `context_too_large`
* `invalid_skill`
* `invalid_result`
* `readonly_violation`
* `workspace_conflict`
* `container_failed`

Pipelines MAY route some failures to recovery agents. Recovery loops MUST be
bounded by step visits and circuit breakers.

If a step returns `UNKNOWN`, the runner MAY use adapter resume capability to ask
for a structured result, but MUST record that recovery attempt in the trace.

## 17. Testing Requirements

Implementations SHOULD test:

* Pipeline JSON validation.
* Jump target resolution.
* Max visit and circuit breaker behavior.
* Inline handler execution.
* Skill metadata parsing.
* Input envelope rendering.
* Result envelope validation.
* Parent output propagation.
* Adapter capability negotiation.
* Trace normalization.
* Readonly workspace rollback or violation detection.
* Workflow `backend: agent` dispatch.
* Container file-envelope execution with bind-mounted run directory.
* Approval enforcement for write-capable steps.

## 18. Suggested Delivery Order

1. Define pipeline JSON schema and validation.
2. Define skill metadata contract for pipeline agents.
3. Implement local run directory layout and result envelopes.
4. Add one host adapter for an existing local agent CLI.
5. Wire `backend: agent` workflow jobs to the pipeline runner.
6. Add trace normalization and web timeline display.
7. Add readonly enforcement and approval gates.
8. Add optional OCI container execution via bind-mounted run directories.
9. Add additional adapters and skill injection strategies.

