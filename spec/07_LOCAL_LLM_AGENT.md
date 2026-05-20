# Local LLM Agent

## 1. Purpose

Gitomi SHOULD provide a local-first AI agent that is integrated with the web UI,
the local SQLite projections, and the current page context. The feature is not a
generic chat box. It is a task assistant for repository-local work such as
summarizing visible issues, explaining pull requests, preparing conflict
resolution plans, drafting replies, and analyzing project state.

The agent MUST support:

* Local Ollama models.
* User-configured OpenAI-compatible HTTP API endpoints.
* Preconfigured endpoint presets for common hosted model providers.
* User-supplied API keys.
* Encrypted local API key storage in Gitomi's local SQL settings storage.
* Context gathering from the current web page and the local SQLite index.

The agent MUST preserve Gitomi's local-first behavior. Provider configuration,
secrets, cached model metadata, and agent session history are local machine
state and MUST NOT be written to Git event logs.

## 2. Goals

* Make local Ollama the default local provider path.
* Allow users to add hosted providers without recompiling Gitomi.
* Keep API keys out of HTML, URLs, logs, process arguments, and Git history.
* Make the agent aware of the current web route and visible object context.
* Let the agent query Gitomi's local SQLite projection through curated tools.
* Return grounded answers with local Gitomi links or object references when
  answers rely on repository data.
* Require explicit user confirmation before any action that writes Gitomi
  events, edits files, runs commands, or calls non-selected external providers.

## 3. Non-Goals

The first implementation MUST NOT provide arbitrary SQL execution to the model.

The first implementation MUST NOT grant arbitrary filesystem, shell, Git, or
network access to the model.

The first implementation MUST NOT silently apply issue, pull request, project,
merge, or file changes. It MAY draft actions and present them for confirmation.

The first implementation SHOULD NOT implement vector search unless a local,
dependency-light vector path is already available. Existing SQLite FTS5 search
is sufficient for the first context retrieval layer.

## 4. Local Storage

Gitomi already stores local web settings in:

```text
.git/gitomi/settings.sqlite
```

The local LLM feature MUST store provider settings, encrypted secrets, cached
provider metadata, and optional agent history in this settings database.

The settings database is local machine state. It MUST NOT be synchronized
through Gitomi event refs and MUST NOT be treated as repository-authoritative
data.

### 4.1 Schema

Implementations SHOULD model provider configuration separately from model cache
and secrets. The recommended schema is:

```sql
CREATE TABLE ai_providers (
  id TEXT PRIMARY KEY,
  provider_kind TEXT NOT NULL,
  provider TEXT NOT NULL,
  display_name TEXT NOT NULL,
  endpoint_url TEXT NOT NULL,
  chat_model TEXT NOT NULL,
  embedding_model TEXT NOT NULL,
  auth_style TEXT NOT NULL,
  api_key_env TEXT NOT NULL,
  secret_id TEXT,
  enabled INTEGER NOT NULL,
  default_for_chat INTEGER NOT NULL,
  status TEXT NOT NULL,
  notes TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX ai_providers_kind_idx
  ON ai_providers(provider_kind, provider);

CREATE TABLE ai_provider_presets (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  display_name TEXT NOT NULL,
  endpoint_url TEXT NOT NULL,
  auth_style TEXT NOT NULL,
  default_chat_model TEXT NOT NULL,
  default_embedding_model TEXT NOT NULL,
  notes TEXT NOT NULL
);

CREATE TABLE ai_secrets (
  id TEXT PRIMARY KEY,
  provider_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE ai_model_cache (
  provider_id TEXT NOT NULL,
  model_id TEXT NOT NULL,
  model_kind TEXT NOT NULL,
  display_name TEXT NOT NULL,
  raw_json TEXT NOT NULL,
  refreshed_at TEXT NOT NULL,
  PRIMARY KEY(provider_id, model_id, model_kind)
);

CREATE TABLE ai_agent_sessions (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  route TEXT NOT NULL,
  context_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE ai_agent_messages (
  session_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  citations_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(session_id, ordinal)
);
```

Existing `ai_models` settings MAY be migrated into `ai_providers`. Migration
MUST preserve the current Ollama configuration where possible.

Settings schema updates MUST use migrations. Implementations MUST NOT drop all
settings tables solely because a schema version changed once secrets are stored.

## 5. Secret Encryption

API keys stored in `ai_secrets` MUST be encrypted before insertion.

The recommended local encryption design is:

* Generate a random 256-bit local key on first use.
* Store it at `.git/gitomi/secrets.key`.
* Create the key file with owner-only permissions where the OS supports them.
* Encrypt each secret with `XChaCha20-Poly1305` or an equivalent authenticated
  encryption algorithm from Zig's standard cryptography library.
* Store nonce and ciphertext as base64 text in SQLite.
* Use the provider id and secret id as associated authenticated data.

If the key file is missing, Gitomi MUST NOT attempt to decrypt existing stored
secrets. It SHOULD show the affected providers as requiring a new API key.

Users MUST be allowed to use an environment variable instead of stored secrets.
When `api_key_env` is set and no stored secret is selected, the server MAY read
that environment variable at request time.

The browser MUST never receive a stored API key or decrypted API key.

## 6. Provider Support

### 6.1 Provider Kinds

`provider_kind` SHOULD use these values:

* `local`: local machine providers such as Ollama and LM Studio.
* `remote`: user-configured hosted providers with user-supplied API keys.
* `platform`: reserved for future Gitomi-managed accounts or billing.

### 6.2 Ollama

Gitomi MUST support Ollama using its native local HTTP API.

The default endpoint SHOULD be:

```text
http://localhost:11434
```

The first implementation SHOULD support:

* `POST /api/chat` for chat completion.
* `GET /api/tags` for model discovery when the user asks Gitomi to refresh
  model metadata.

Ollama requests MUST NOT require an API key by default.

### 6.3 OpenAI-Compatible Providers

Gitomi MUST support OpenAI-compatible chat APIs using:

```text
POST /v1/chat/completions
Authorization: Bearer <api-key>
Content-Type: application/json
```

Provider records MUST allow custom endpoint URLs. Implementations SHOULD accept
base URLs with or without a trailing slash and normalize request paths safely.

The first implementation SHOULD support non-streaming completions. Streaming MAY
be added later.

### 6.4 Presets

Gitomi SHOULD seed presets for common providers. Presets are convenience values,
not trusted provider definitions. Users MUST be able to edit endpoint URLs and
model names.

Recommended presets:

| Preset | Kind | Endpoint |
| --- | --- | --- |
| Ollama | local | `http://localhost:11434` |
| OpenAI-compatible custom | remote | user supplied |
| OpenAI | remote | `https://api.openai.com/v1` |
| OpenRouter | remote | `https://openrouter.ai/api/v1` |
| Groq | remote | `https://api.groq.com/openai/v1` |
| Mistral | remote | `https://api.mistral.ai/v1` |
| DeepSeek | remote | `https://api.deepseek.com/v1` |
| Together | remote | `https://api.together.xyz/v1` |
| LM Studio | local | `http://localhost:1234/v1` |

Provider presets MAY become stale. The UI MUST present them as editable
defaults rather than guarantees.

## 7. Web UI

### 7.1 Model Settings

The settings page SHOULD expose:

* Local provider card for Ollama.
* Remote provider cards seeded from presets.
* Custom OpenAI-compatible endpoint creation.
* API key entry, update, clear, and environment variable alternatives.
* Chat model and optional embedding model fields.
* Provider enablement.
* A test connection action.
* Optional model refresh.

The UI MUST redact stored API keys. It MAY show whether a provider has a stored
secret or an environment variable name.

### 7.2 Agent Surface

Gitomi SHOULD expose the agent as an integrated popup available from every web
page. The popup SHOULD be implemented as a small custom element, for example:

```html
<gitomi-agent-dock></gitomi-agent-dock>
```

The first implementation SHOULD use normal document styling rather than a closed
Shadow DOM so existing Gitomi theme tokens, font settings, and density apply.

The popup SHOULD provide task-first actions based on page context, such as:

* Summarize visible issues.
* Explain this issue.
* Explain this pull request.
* Draft a reply.
* Find blockers.
* Build a conflict resolution plan.
* Compare selected issues.
* Identify stale project items.

The popup MAY include a text input, but the primary design SHOULD be contextual
commands plus grounded responses.

## 8. Page Context

The agent MUST combine browser-visible context with server-side context.

Browser context MAY include:

* Current URL and route.
* Document title.
* Selected text.
* Visible headings.
* Selected rows or cards.
* Elements explicitly marked with agent context attributes.

Recommended DOM attributes:

```html
data-agent-context
data-agent-kind
data-agent-id
data-agent-label
```

Server context MUST be authoritative for repository data. Given a route and
object reference, the server SHOULD load relevant objects from `index.sqlite`
instead of relying on scraped HTML.

Examples:

* `/issues` loads active filters, visible issue ids if supplied, and summaries.
* `/issues/:ref` loads issue detail, metadata, labels, relationships, comments,
  related commits, and linked pull requests.
* `/pulls/:ref` loads pull request detail, comments, reviewers, labels, commit
  references, and optionally diff summaries.
* `/pulls/:ref/conflicts` loads conflict file metadata and merge state.
* `/projects/...` loads project, active view, filters, and visible items.

Context payloads MUST have size limits. If context is truncated, the agent
response SHOULD say what kind of context was omitted.

## 9. Agent Tools

The model MUST interact with Gitomi through curated tools. Tools are server-side
functions. The model MUST NOT receive direct database handles, raw file system
access, or arbitrary shell access.

Initial read-only tools SHOULD include:

* `current_page_context`
* `search_work_items`
* `get_issue`
* `get_pull`
* `list_comments`
* `list_related_items`
* `get_project_view`
* `get_pr_diff_summary`
* `get_merge_conflicts`

Tool results SHOULD include stable local links where applicable.

The server MUST enforce:

* Maximum tool calls per agent run.
* Maximum rows per query.
* Maximum bytes per tool result.
* Maximum total context bytes.
* Read-only SQLite connections for read tools.

### 9.1 Write Tools

Write tools MUST be disabled in the first read-only implementation unless they
only produce drafts.

Future write-capable tools MUST require explicit user confirmation before
executing. Confirmation MUST show the exact proposed Gitomi action, including
object id, event type, and changed fields.

Write tools MUST reuse existing Gitomi event writers and authorization checks.
They MUST NOT write directly to projection tables.

## 10. Agent API

Recommended web routes:

```text
GET  /agent/context
POST /agent/run
POST /agent/provider/test
POST /agent/provider/models
```

`/agent/run` SHOULD accept JSON like:

```json
{
  "task": "summarize-visible-issues",
  "message": "Summarize the issues on this page",
  "route": "/issues?state=open",
  "page_context": {
    "title": "Issues",
    "selected_text": "",
    "visible_refs": ["018f...", "0190..."]
  },
  "session_id": null
}
```

Responses SHOULD include:

```json
{
  "session_id": "0190...",
  "message": "Three issues are blocked...",
  "citations": [
    {
      "kind": "issue",
      "id": "018f...",
      "href": "/issues/018f...",
      "label": "Issue title"
    }
  ],
  "truncated": false
}
```

Agent endpoints MUST use same-origin protections. Endpoints that mutate settings
or start provider requests SHOULD require CSRF protection consistent with the
existing web UI.

## 11. Prompting Requirements

System prompts MUST tell the model:

* It is operating inside Gitomi.
* Repository data is local and may be incomplete if the index is stale.
* It must cite local objects used for factual claims.
* It must distinguish facts from suggestions.
* It must not claim to have changed repository state unless a confirmed write
  tool reports success.
* It must ask for confirmation before destructive or write actions.

Provider prompts SHOULD be assembled server-side. The browser MUST NOT assemble
prompts containing decrypted API keys or hidden server context.

## 12. Privacy and Network Behavior

Gitomi MUST clearly indicate when a selected provider is remote. Before sending
repository context to a remote provider for the first time, Gitomi SHOULD require
an explicit user enablement action for that provider.

The agent MUST send only selected and retrieved context, not the whole database.

The agent SHOULD default to local Ollama when enabled.

Remote provider errors MUST be shown without leaking API keys.

## 13. Index Freshness

If `index.sqlite` is stale or missing, the agent SHOULD either:

* Offer to rebuild the index using the existing index rebuild flow, or
* Continue with browser-visible context only and clearly mark repository context
  as unavailable.

The agent MUST NOT silently answer repository-state questions as if the index
were fresh when it is not.

## 14. Auditing

Read-only agent runs MAY be stored in `ai_agent_sessions` and
`ai_agent_messages` as local settings state.

Confirmed writes MUST already be represented by normal signed Gitomi events.
The agent-specific local session record is not authoritative and MUST NOT be
required to replay repository state.

## 15. Testing Requirements

Implementations SHOULD include tests for:

* Settings migration from existing Ollama `ai_models` records.
* Secret encryption round trip.
* Secret decryption failure when associated provider data does not match.
* API key redaction in rendered settings HTML.
* OpenAI-compatible request JSON generation.
* Ollama request JSON generation.
* Current-page context extraction for issue and pull routes.
* Read-only tool query limits.
* Agent endpoint rejection of cross-origin or missing-CSRF write requests.

Provider integration tests SHOULD be optional and skipped unless an endpoint is
configured explicitly.

## 16. Suggested Delivery Order

1. Add settings migrations, provider schema, presets, and encrypted secrets.
2. Expand the AI Models settings page.
3. Add Ollama and OpenAI-compatible non-streaming clients.
4. Add read-only agent context tools over `index.sqlite`.
5. Add `/agent/run` with non-streaming responses.
6. Add the global popup custom element.
7. Add citations and task-specific action buttons.
8. Add confirmed draft/write workflows.

