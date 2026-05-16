# Gitomi Projects Web UI Specification v1.1

This document specifies the Gitomi projects web experience and the project data
model it requires. It extends the product, ref, and RBAC specifications. It does
not replace the existing issue, pull request, milestone, or project event model.

The central design constraint is that projects are views over issues. Gitomi
MUST NOT introduce a second task object for project planning. A project table,
board, roadmap, or template is a different projection of the same issue set,
issue metadata, project membership, and optional project-scoped fields.

## 1. Goals

The projects web UI MUST support:

*   creating project workspaces from a blank state or from templates
*   adding existing issues to a project and creating new issues inside a project
*   viewing the same project items as a table, board, or roadmap
*   grouping issues by stable metadata such as priority without changing issue
    identity or project membership
*   moving issues across pipeline stages in a board without moving them between
    priority groups
*   planning roadmap dates without requiring a full dependency graph or Gantt
    scheduler
*   preserving all project actions as signed, replayable Gitomi events

The projects web UI SHOULD feel like a work surface, not a marketing page. The
first screen for an existing project SHOULD show useful issue data immediately.

## 2. Non-Goals

The v1 projects web UI MUST NOT require:

*   a separate server-side database beyond the Gitomi projection index
*   a new "task" object distinct from issues
*   automatic dependency scheduling
*   critical-path calculation
*   required sub-issue support
*   template-specific domain objects
*   implicit issue closure when an issue changes pipeline stage

Sub-issues MAY be displayed in the future as derived issue-to-issue
relationships, but they are not required for this specification.

## 3. Terminology

Spec05 uses the following terms precisely:

| Term | Scope | Meaning |
| --- | --- | --- |
| `state` | Issue lifecycle | Whether an issue is `open` or `closed`. This is not the project board axis. |
| `pipeline` | Issue metadata | Where the issue is in the work pipeline, such as `Draft`, `Todo`, `WIP`, `Review`, `Done`, `Failed`. |
| `priority` | Issue metadata | Planning priority, such as `P0`, `P1`, `P2`, `P3`. |
| `type` | Issue metadata | Work kind, such as `bug`, `feature`, or `task`. |
| project membership | Issue collection | Whether an issue appears in a project. |
| project field | Project-scoped metadata | Optional per-project metadata such as `size`, `estimate`, `start_at`, or `target_at`. |

The word `status` is ambiguous and MUST NOT be used for new Spec05 data model
keys. Existing v1 project columns and imported provider fields MAY continue to
be displayed as "status" in compatibility UI, but new views MUST distinguish
issue `state` from issue `pipeline`.

## 4. Concepts

### 4.1. Issue

An issue is the canonical work item. It owns durable work content and default
metadata:

*   title
*   body
*   lifecycle `state` (`open` or `closed`)
*   `pipeline`
*   `priority`
*   `type`
*   labels
*   assignees
*   milestone
*   project memberships
*   comments and reactions
*   links to pull requests and commits

Project views MAY display any of these fields, but they MUST NOT copy them into
project-specific task objects.

### 4.2. Default Issue Metadata

The following issue metadata fields are built in and available in every
repository:

| Key | Shape | Default values | Notes |
| --- | --- | --- | --- |
| `state` | scalar enum | `open`, `closed` | Lifecycle state. Closing an issue is separate from moving it to `Done`. |
| `pipeline` | scalar enum | `Draft`, `Todo`, `WIP`, `Review`, `Done`, `Failed` | Default board axis. |
| `priority` | scalar enum | `P0`, `P1`, `P2`, `P3` | Default planning priority. `P0` is highest. |
| `type` | scalar enum | `bug`, `feature`, `task` | Default issue kind. |
| `milestone` | nullable scalar ref/name | implementation-defined | Milestone assignment. |
| `labels` | OR-Set of strings | none | Issue labels. |
| `assignees` | OR-Set of principals | none | Issue owners. |
| `projects` | OR-Set of project memberships | none | Project membership, independent of pipeline and priority. |

Implementations MAY allow repository administrators to customize display names,
colors, ordering, and allowed values for `pipeline`, `priority`, and `type`, but
clients MUST be able to render and edit the default values without requiring a
project-specific field definition.

`pipeline` and `priority` are orthogonal. Changing `pipeline` from `Todo` to
`In Review` MUST NOT alter `priority`. Changing `priority` from `P1` to `P0`
MUST NOT alter `pipeline`.

### 4.3. Project

A project is a named workspace over issues. It owns:

*   project metadata, such as name, description, state, and slug
*   a membership set of issues
*   saved views over the member issues
*   optional project-scoped field definitions
*   template metadata used at creation time

A project is not itself a folder of tasks. The same issue MAY appear in more
than one project.

### 4.4. Project Membership

Project membership answers one question: "Is this issue part of this project?"

Membership MUST be independent from issue metadata such as `state`, `pipeline`,
`priority`, `type`, labels, assignees, milestone, estimate, or roadmap dates.
Removing an issue from a project hides it from that project without deleting the
issue and without changing its pipeline or priority.

### 4.5. Project Field

A project field is a typed value attached to an issue within one project. The
field definition belongs to the project; the field value belongs to the issue's
membership in that project.

Project fields are for project-local planning dimensions that are not canonical
issue metadata. Built-in issue metadata keys (`state`, `pipeline`, `priority`,
`type`, `milestone`, `labels`, `assignees`, `projects`) MUST NOT be redefined as
project fields by default. A project MAY define a project-local override only
with an explicit non-conflicting key, such as `release_priority` or
`review_stage`.

Recommended project field keys include:

| Key | Type | Meaning |
| --- | --- | --- |
| `size` | single-select or number | Rough implementation size |
| `estimate` | number | Numeric estimate used for summaries |
| `start_at` | date | Planned start date |
| `target_at` | date | Planned target or end date |
| `iteration` | single-select or text | Iteration, sprint, or planning cycle |
| `track` | single-select or text | Project-specific workstream |

Project fields MAY use custom keys when a project needs a different dimension.

### 4.6. Project View

A project view is a saved projection over project member issues. It owns layout
configuration only. It does not own issues, issue metadata, project membership,
or project field values.

View layouts are:

*   `table`
*   `board`
*   `roadmap`

A project MAY have multiple views over the same data. For example, a feature
release project can have a table grouped by `issue.priority`, a board grouped by
`issue.pipeline`, and a roadmap using project fields `start_at` and `target_at`.

### 4.7. Template

A template is creation-time seed data. It MAY create default views, filters,
project fields, project field options, and import settings. After creation, the
resulting project is a normal project.

Templates MUST NOT create special project types. Templates MUST NOT create
project-scoped copies of canonical issue metadata.

## 5. Data Model

The logical projection SHOULD expose the following records. Implementations MAY
store them in different physical tables as long as the visible behavior is
equivalent and the projection is rebuildable from accepted events.

### 5.1. Issue Metadata Records

Issue metadata MAY be stored in `issues`, `issue_metadata`, or denormalized read
tables. The logical issue record MUST expose:

*   `id`
*   `title`
*   `body`
*   `state`
*   `pipeline`
*   `priority`
*   `type`
*   `milestone`
*   `opened_at`
*   `author_principal`
*   per-scalar causal register metadata, at least `occurred_at`,
    `actor_principal`, and `event_hash`

The scalar issue metadata fields `title`, `body`, `state`, `pipeline`,
`priority`, `type`, and `milestone` MUST be modeled as causal scalar registers.

Issue labels, assignees, project memberships, and reactions MUST be modeled as
Observed-Remove Sets.

### 5.2. Project Records

`projects`:

*   `id`
*   `name`
*   `slug`
*   `description`
*   `state`
*   `created_at`
*   `author_principal`

Existing `project.created` and `project.updated` events remain authoritative for
these fields.

### 5.3. Membership Records

`project_memberships`:

*   `project_id`
*   `issue_id`
*   `add_hash`
*   `created_at`
*   `actor_principal`
*   `state`

Membership MUST be modeled as an Observed-Remove Set keyed by
`(project_id, issue_id)`.

### 5.4. Project Field Definition Records

`project_fields`:

*   `id`
*   `project_id`
*   `key`
*   `name`
*   `type`
*   `position`
*   `required`
*   `default_value`
*   `state`

Valid field types are:

*   `text`
*   `number`
*   `date`
*   `boolean`
*   `single_select`
*   `multi_select`
*   `user`
*   `issue_ref`

`project_field_options`:

*   `id`
*   `field_id`
*   `name`
*   `color`
*   `position`
*   `state`

Select option identities SHOULD be stable IDs. Payloads SHOULD also include the
display name so older clients can render meaningful values.

### 5.5. Project Field Value Records

`project_field_values`:

*   `project_id`
*   `issue_id`
*   `field_id`
*   `value_json`
*   `occurred_at`
*   `actor_principal`
*   `event_hash`

Field values MUST be modeled as causal scalar registers scoped by
`(project_id, issue_id, field_id)`. The latest winning value is visible, but all
accepted value-setting events remain in the issue timeline.

Project field value changes MUST NOT alter built-in issue metadata unless an
explicit event for that issue metadata field is also written.

### 5.6. View Records

`project_views`:

*   `id`
*   `project_id`
*   `name`
*   `layout`
*   `position`
*   `config_json`
*   `state`

The view config MUST be treated as presentation metadata. A view config MAY
contain:

*   visible field order
*   filters
*   sort order
*   group field
*   board column field
*   roadmap start and end fields
*   closed-item visibility
*   density setting

Field references in view config MUST identify their source. Recommended forms
are:

*   `issue.state`
*   `issue.pipeline`
*   `issue.priority`
*   `issue.type`
*   `issue.milestone`
*   `issue.labels`
*   `issue.assignees`
*   `project.<field-key>`

For compatibility, unqualified `pipeline`, `priority`, `type`, `milestone`,
`labels`, and `assignees` SHOULD resolve to the corresponding `issue.*` field.
Unqualified custom keys SHOULD resolve to project fields only when there is no
built-in issue metadata key with the same name.

## 6. Event Model Extensions

The existing v1 events are sufficient for basic project creation and legacy
kanban placement. A full projects web UI SHOULD add the following event types.
Unknown event types continue to be preserved and ignored by clients that do not
understand them.

### 6.1. Issue Metadata Events

Built-in scalar issue metadata SHOULD be edited with narrow issue events:

*   `issue.pipeline_set`
*   `issue.priority_set`
*   `issue.type_set`
*   existing `issue.state_set`
*   existing `issue.milestone_set`

Minimum payloads:

| Event | Required payload |
| --- | --- |
| `issue.pipeline_set` | `pipeline` |
| `issue.priority_set` | `priority` |
| `issue.type_set` | `type` |
| `issue.state_set` | `state` |
| `issue.milestone_set` | `milestone` |

`issue.updated` MAY carry the same fields for compatibility and batch updates,
but single-field UI edits SHOULD write the narrowest event possible. Reducers
MUST treat each scalar metadata field independently.

### 6.2. Project Field Events

*   `project.field_created`
*   `project.field_updated`
*   `project.field_removed`
*   `project.field_option_added`
*   `project.field_option_updated`
*   `project.field_option_removed`

Minimum payloads:

| Event | Required payload |
| --- | --- |
| `project.field_created` | `field_id`, `key`, `name`, `type` |
| `project.field_updated` | `field_id`, at least one of `name`, `position`, `required`, `default_value`, `state` |
| `project.field_removed` | `field_id` |
| `project.field_option_added` | `field_id`, `option_id`, `name` |
| `project.field_option_updated` | `field_id`, `option_id`, at least one of `name`, `color`, `position`, `state` |
| `project.field_option_removed` | `field_id`, `option_id` |

Field and option collections MUST be reduced as Observed-Remove Sets. Field
metadata, option metadata, and positions MUST be causal scalar registers.

### 6.3. Project View Events

*   `project.view_created`
*   `project.view_updated`
*   `project.view_removed`

Minimum payloads:

| Event | Required payload |
| --- | --- |
| `project.view_created` | `view_id`, `name`, `layout` |
| `project.view_updated` | `view_id`, at least one of `name`, `layout`, `position`, `config` |
| `project.view_removed` | `view_id` |

View records MUST be reduced as an Observed-Remove Set keyed by `view_id`. The
`config` member MUST be a JSON object. Unknown config keys MUST be preserved by
clients that rewrite the view.

### 6.4. Issue Project Membership Events

Existing events:

*   `issue.project_added`
*   `issue.project_removed`

For v1 compatibility, these events require `project` and `column`.

For the richer model, payloads SHOULD also accept:

*   `project_id` or `project_ref`
*   `initial_issue_metadata`
*   `initial_project_fields`
*   `remove_hashes`

`initial_issue_metadata` is an object keyed by built-in issue metadata key. It
MAY seed values such as `pipeline`, `priority`, or `type` when creating or
adding an issue from a view group.

`initial_project_fields` is an object keyed by project field key or field ID. It
seeds project field values at the same event hash as membership creation.

Adding an issue to a project MUST create membership only, plus explicit initial
metadata or project field values when requested. It MUST NOT clone the issue.

### 6.5. Issue Project Field Events

*   `issue.project_field_set`
*   `issue.project_field_cleared`

Minimum payloads:

| Event | Required payload |
| --- | --- |
| `issue.project_field_set` | `project_id` or `project_ref`, `field_id` or `field_key`, `value` |
| `issue.project_field_cleared` | `project_id` or `project_ref`, `field_id` or `field_key` |

These events target the issue, not the project. This keeps project-local
planning history attached to the issue timeline.

Reducers MUST domain-reject field value events when the target issue is not a
visible member of the target project in the event's effective replay history.

### 6.6. Compatibility With Existing Kanban Columns

The current v1 projection stores issue project placement as `(project, column)`.
Spec05 clients MUST interpret that placement as:

*   project membership for `project`
*   a legacy project-local column value for that project membership

Legacy columns are not automatically canonical issue `pipeline` values because
one issue MAY appear in multiple legacy projects with different columns.

A Spec05 client MAY migrate legacy columns to `issue.pipeline` only when the
mapping is unambiguous:

*   the issue has no accepted `pipeline` value, and
*   the issue has exactly one visible legacy project column, or all visible
    legacy project columns normalize to the same pipeline value.

When the mapping is ambiguous, the UI MUST keep the legacy column visible inside
that project and MUST NOT silently overwrite `issue.pipeline`.

New project board writes SHOULD create or resolve a concrete project object,
create membership if needed, and then update `issue.pipeline` for pipeline board
moves.

## 7. View Semantics

All views in a project operate on the same project membership set, issue
metadata, and project field values.

### 7.1. Table View

The table view is the canonical dense editing surface. It SHOULD support:

*   issue title, lifecycle state, pipeline, priority, type, assignees, labels,
    milestone, and linked pull requests
*   project fields as editable columns
*   grouping by one field, such as `issue.priority` or `issue.pipeline`
*   sorting by one or more fields
*   filtering by keyword and field predicates
*   inline creation of an issue in the current group

When a table is grouped by `issue.priority`, adding an issue inside the `P1`
group SHOULD create project membership and set the issue's `priority` field to
`P1`. It MUST NOT set `pipeline` unless the view has an explicit default.

### 7.2. Board View

The board view groups project issues by one enum/select field. The default board
field MUST be `issue.pipeline`.

Each board column represents one value of the grouping field. Dragging an issue
card to another column MUST write the narrowest event for that grouping field.
For the default board this is `issue.pipeline_set`. It MUST NOT remove and
re-add project membership. It MUST NOT change issue `state`, `priority`, or
`type` unless the user explicitly edits those fields.

Board cards SHOULD show:

*   issue state
*   pipeline stage
*   title
*   short issue ref or imported provider number
*   type
*   assignees
*   labels
*   priority or size when present
*   comment count
*   linked pull request state when present

### 7.3. Roadmap View

The roadmap view maps project issues onto time. It SHOULD use:

*   project field `start_at` as the start date
*   project field `target_at` as the target or end date
*   `issue.pipeline` for visual state
*   `issue.priority` or another configured field for grouping

The roadmap view is not a full Gantt scheduler. It MUST NOT require dependency
edges, automatic date propagation, or critical-path analysis. If issue
dependencies are introduced in a later specification, roadmap MAY display them
as overlays.

Issues without roadmap dates SHOULD remain visible in an unscheduled section.

## 8. Default Templates

Templates seed views, filters, and project-specific fields. They also MAY set
view-local defaults for built-in issue metadata, but they MUST NOT create
project-scoped copies of `pipeline`, `priority`, `type`, `milestone`, labels, or
assignees.

The following templates are RECOMMENDED.

### 8.1. Table

Views:

*   Table grouped by `issue.pipeline`

Defaults:

*   `pipeline`: `Todo`

### 8.2. Board

Views:

*   Board grouped by `issue.pipeline`
*   Table grouped by `issue.pipeline`

Defaults:

*   `pipeline`: `Todo`

### 8.3. Roadmap

Project fields:

*   `start_at`
*   `target_at`

Views:

*   Roadmap using `project.start_at` and `project.target_at`
*   Table grouped by `issue.pipeline`

Defaults:

*   `pipeline`: `Todo`

### 8.4. Kanban

Views:

*   Board grouped by `issue.pipeline`
*   Table grouped by `issue.priority`
*   My items table filtered by current principal

Defaults:

*   `pipeline`: `Todo`
*   `priority`: `P2`

### 8.5. Feature Release

Project fields:

*   `size`: S, M, L
*   `start_at`
*   `target_at`

Views:

*   Prioritized table grouped by `issue.priority`
*   Pipeline board grouped by `issue.pipeline`
*   Roadmap using `project.start_at` and `project.target_at`
*   Bugs view filtered by `issue.type = bug` or the `bug` label

Defaults:

*   `pipeline`: `Todo`
*   `priority`: `P2`
*   `type`: `feature`

### 8.6. Bug Tracker

Views:

*   Prioritized bugs table grouped by `issue.priority`
*   Triage board grouped by `issue.pipeline`
*   My items table filtered by current principal

Defaults:

*   `pipeline`: `Todo`
*   `priority`: `P2`
*   `type`: `bug`

### 8.7. Team Planning

Project fields:

*   `iteration`
*   `estimate`
*   `start_at`
*   `target_at`

Views:

*   Backlog table grouped by `issue.pipeline`
*   Board grouped by `issue.pipeline`
*   Current iteration table filtered by `project.iteration`
*   Roadmap using `project.start_at` and `project.target_at`
*   My items table filtered by current principal

Defaults:

*   `pipeline`: `Todo`
*   `priority`: `P2`
*   `type`: `task`

## 9. Web UI Flows

### 9.1. Project Index

`/projects` SHOULD list concrete projects, sorted by recent activity and then
name. Each project summary SHOULD show:

*   name
*   description
*   open or closed project state
*   issue count
*   active views
*   recent activity

Legacy virtual projects MAY be shown, but they SHOULD be visually identified as
legacy/imported until a concrete project is created.

### 9.2. Create Project

The create project flow SHOULD collect:

*   project name
*   optional description
*   template
*   optional initial issues from a query or selection
*   optional default issue metadata for imported issues
*   optional default project field values for imported issues

Creating a project from a template MUST emit project metadata and view events.
When the template includes project-specific fields, creation MUST also emit
field and option events. Adding initial issues SHOULD emit membership events
with `initial_issue_metadata` and `initial_project_fields` instead of creating
duplicate issues.

The UI SHOULD make it clear that table, board, and roadmap are starting views
over the same data.

### 9.3. Project Workspace

`/projects/<project-ref>` SHOULD show:

*   project header with name, project state, and view controls
*   saved view tabs
*   filter and sort controls
*   the active view
*   item creation affordance
*   issue metadata editing controls appropriate to the active view
*   project field editing controls appropriate to the active view

The active view SHOULD be addressable by URL so links preserve context.

### 9.4. Add Existing Issues

Users SHOULD be able to add existing issues by:

*   issue ref
*   keyword search
*   label, assignee, milestone, type, priority, pipeline, or state query
*   imported provider number when available

Adding existing issues MUST create project membership only. It MUST NOT clone
the issue. If the add action happens inside a grouped view, the UI MAY offer to
also set the current group default, but this MUST be explicit unless the view
configuration defines that default.

### 9.5. Create Issue In Project

Creating a new issue from a project view MUST create a normal `issue.opened`
event and then add the issue to the project. The UI SHOULD batch these writes
when the event writer supports a single logical user action with stable
idempotency.

The new issue SHOULD inherit the current group defaults. For example:

*   creating in board column `In Review` sets `pipeline = In Review`
*   creating in table group `P1` sets `priority = P1`
*   creating in a bug-tracker default view sets `type = bug`
*   creating in a roadmap date range sets `project.start_at` and
    `project.target_at`

### 9.6. Edit Metadata And Fields

Single-field edits SHOULD write the narrowest event possible. Multi-field edits
MAY be batched when the event model supports it.

The UI MUST distinguish issue lifecycle state from issue pipeline. Closing an
issue is a separate action from moving it to the `Done` pipeline stage.

The issue detail sidebar SHOULD expose editable controls for assignees, labels,
type, projects, milestone, priority, and pipeline. Project views SHOULD reuse
the same underlying issue metadata rather than maintaining separate values.

## 10. Query and Filtering

Project views SHOULD reuse the canonical issue query language defined in
`01_PRODUCT.md` where possible. The query engine SHOULD support predicates for
issue metadata and project fields:

*   `project:<project-ref>`
*   `pipeline:<value>`
*   `priority:<value>`
*   `type:<value>`
*   `milestone:<value>`
*   `field:<key>=<value>`
*   `project-field:<key>=<value>`
*   `start:<date>`
*   `target:<date>`
*   `assignee:<principal>`
*   `label:<label>`
*   `state:open|closed`

Filtering MUST be view-local unless the user saves it into the view config.

## 11. Permissions

Project web actions require the same underlying permissions as their events:

*   creating or updating project metadata requires project write permission
*   adding an issue to a project requires issue write permission for that issue
*   setting issue metadata requires issue write permission for that issue
*   setting a project field value requires issue write permission for that issue
*   creating a new issue requires issue create permission
*   editing saved project fields or views requires project write permission

The UI SHOULD hide or disable controls that the current principal cannot use.
Server-side action handlers MUST still enforce permissions through event
validation.

## 12. Conflict Handling

Gitomi is local-first, so concurrent edits are normal.

Issue metadata values are independent scalar registers. If two users
concurrently set an issue's pipeline to different values, the deterministic
reducer winner is visible. The issue timeline MUST retain both events. The
priority register is unaffected by this conflict.

Project field values are scalar registers scoped to a project membership.
Membership and field definitions are Observed-Remove Sets. A concurrent remove
MUST only remove add tags it causally observes or explicitly names.

When a saved view references a removed project field, the UI SHOULD show the
view with a recoverable warning and offer to edit the view. It MUST NOT drop
unknown or missing-field config silently.

When a view references an unknown issue metadata key, the UI SHOULD render the
view with a warning and preserve the config. It MUST NOT reinterpret the unknown
field as a project field unless the config explicitly uses `project.<field-key>`.

## 13. Index Requirements

The index SHOULD support efficient queries for:

*   projects by state and recent activity
*   project members by project
*   issue metadata by project, key, and value
*   project field values by project, field, and value
*   board columns with issue counts
*   table grouping counts
*   roadmap date ranges
*   current principal's assigned project issues

The index MAY derive denormalized read tables from accepted events. Derived
tables MUST be rebuildable from the event log.

## 14. Accessibility and Responsive Behavior

The web UI SHOULD provide keyboard and non-pointer alternatives for all project
mutations. Drag and drop MUST be progressive enhancement; moving a card between
pipeline values MUST also be possible through menus or forms.

On narrow screens:

*   table views MAY become horizontally scrollable
*   board columns MAY remain horizontally scrollable
*   roadmap views SHOULD provide a compact list grouped by date range
*   controls MUST remain reachable without overlapping content

## 15. Implementation Phases

### 15.1. Phase 1: Normalize Existing Projects UI

*   Continue rendering current `issue_projects(project, column_name)` data.
*   Label legacy columns as compatibility data, not as issue lifecycle state.
*   Add table and board views over the same issue set.
*   Keep roadmap as a read-only or limited editing view until date fields exist.

### 15.2. Phase 2: Add Built-In Issue Metadata

*   Add events and projection columns or tables for `pipeline`, `priority`, and
    `type`.
*   Add issue detail and issue list controls for type, priority, and pipeline.
*   Update project boards so default board movement writes `issue.pipeline_set`.
*   Preserve legacy project columns and migrate them only when unambiguous.

### 15.3. Phase 3: Add Project Fields And Saved Views

*   Add project field and view events.
*   Add projection tables for project fields, options, values, and views.
*   Add inline project field editing in table, board, and roadmap views.
*   Support explicit field references such as `issue.priority` and
    `project.start_at`.

### 15.4. Phase 4: Add Roadmap Planning

*   Add date fields and roadmap view config.
*   Allow unscheduled, scheduled, and date-range editing.
*   Show roadmap bars without dependency scheduling.

### 15.5. Phase 5: Polish Templates and Import

*   Seed recommended templates.
*   Add initial issue selection by query.
*   Add project activity summaries.
*   Add field and view management UI.

## 16. Acceptance Criteria

A compliant implementation satisfies the following:

*   A project can contain issues without duplicating them.
*   A project can show the same issues in table and board views.
*   A board move on the default board changes only `issue.pipeline`.
*   A priority table group remains stable when pipeline changes.
*   Issue `state` and issue `pipeline` are separate controls.
*   Issue `priority`, `pipeline`, `type`, assignees, labels, projects, and
    milestone are default issue metadata, not project-local task fields.
*   A roadmap can show issues with start and target dates.
*   Templates seed views and project fields, not special project types.
*   Legacy kanban columns remain readable.
*   Every mutation is backed by signed Gitomi events.
