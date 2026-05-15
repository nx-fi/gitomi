# Gitomi Projects Web UI Specification v1.0

This document specifies the Gitomi projects web experience and the project data
model it requires. It extends the product, ref, and RBAC specifications. It does
not replace the existing issue, pull request, milestone, or project event model.

The central design constraint is that projects are views over issues. Gitomi
MUST NOT introduce a second task object for project planning. A project table,
board, roadmap, or template is a different projection of the same issue set and
project-scoped issue fields.

## 1. Goals

The projects web UI MUST support:

*   creating project workspaces from a blank state or from templates
*   adding existing issues to a project and creating new issues inside a project
*   viewing the same project items as a table, board, or roadmap
*   grouping issues by stable fields such as priority without changing issue
    identity or project membership
*   moving issues across workflow states in a board without moving them between
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
*   implicit issue closure when a project status changes

Sub-issues MAY be displayed in the future as derived issue-to-issue
relationships, but they are not required for this specification.

## 3. Concepts

### 3.1. Issue

An issue is the canonical work item. It owns durable work content:

*   title
*   body
*   open or closed lifecycle state
*   labels
*   assignees
*   milestone
*   comments and reactions
*   links to pull requests and commits

Project views MAY display any of these fields, but they MUST NOT copy them into
project-specific objects.

### 3.2. Project

A project is a named workspace over issues. It owns:

*   project metadata, such as name, description, state, and slug
*   a membership set of issues
*   project-scoped field definitions
*   saved views over the member issues
*   template metadata used at creation time

A project is not itself a folder of tasks. The same issue MAY appear in more
than one project.

### 3.3. Project Membership

Project membership answers one question: "Is this issue part of this project?"

Membership MUST be independent from fields such as status, priority, estimate,
or roadmap dates. Removing an issue from a project hides it from that project
without deleting the issue.

### 3.4. Project Field

A project field is a typed value attached to an issue within one project. The
field definition belongs to the project; the field value belongs to the issue's
membership in that project.

Built-in field keys SHOULD be used when their meaning fits:

| Key | Type | Meaning |
| --- | --- | --- |
| `status` | single-select | Workflow state, such as Backlog, Ready, In Progress, In Review, Done |
| `priority` | single-select | Relative planning priority, such as P0, P1, P2 |
| `size` | single-select or number | Rough implementation size |
| `estimate` | number | Numeric estimate used for summaries |
| `start_at` | date | Planned start date |
| `target_at` | date | Planned target or end date |
| `iteration` | single-select or text | Iteration, sprint, or planning cycle |

Project fields MAY use custom keys when a project needs a different dimension.

### 3.5. Project View

A project view is a saved projection over project member issues. It owns layout
configuration only. It does not own issues and it does not own field values.

View layouts are:

*   `table`
*   `board`
*   `roadmap`

A project MAY have multiple views over the same data. For example, a feature
release project can have a table grouped by `priority`, a board grouped by
`status`, and a roadmap using `start_at` and `target_at`.

### 3.6. Template

A template is creation-time seed data. It MAY create default fields, options,
views, filters, and import settings. After creation, the resulting project is a
normal project.

Templates MUST NOT create special project types.

## 4. Data Model

The logical projection SHOULD expose the following records. Implementations MAY
store them in different physical tables as long as the visible behavior is
equivalent.

### 4.1. Project Records

`projects`:

*   `id`
*   `name`
*   `slug`
*   `description`
*   `state`
*   `created_at`
*   `author_principal`

Existing `project.created` and `project.updated` events remain authoritative
for these fields.

### 4.2. Membership Records

`project_memberships`:

*   `project_id`
*   `issue_id`
*   `add_hash`
*   `created_at`
*   `actor_principal`
*   `state`

Membership MUST be modeled as an Observed-Remove Set keyed by
`(project_id, issue_id)`.

### 4.3. Field Definition Records

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

### 4.4. Field Value Records

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

Changing a `status` field from `Ready` to `In Progress` MUST NOT alter the
issue's `priority` field. Changing `priority` from `P1` to `P0` MUST NOT alter
the issue's `status` field.

### 4.5. View Records

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

## 5. Event Model Extensions

The existing v1 events are sufficient for basic project creation and legacy
kanban placement. A full projects web UI SHOULD add the following event types.
Unknown event types continue to be preserved and ignored by clients that do not
understand them.

### 5.1. Project Field Events

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

### 5.2. Project View Events

*   `project.view_created`
*   `project.view_updated`
*   `project.view_removed`

Minimum payloads:

| Event | Required payload |
| --- | --- |
| `project.view_created` | `view_id`, `name`, `layout` |
| `project.view_updated` | `view_id`, at least one of `name`, `layout`, `position`, `config` |
| `project.view_removed` | `view_id` |

View records MUST be reduced as an Observed-Remove Set keyed by `view_id`.
The `config` member MUST be a JSON object. Unknown config keys MUST be
preserved by clients that rewrite the view.

### 5.3. Issue Project Membership Events

Existing events:

*   `issue.project_added`
*   `issue.project_removed`

For v1 compatibility, these events require `project` and `column`.

For the richer model, payloads SHOULD also accept:

*   `project_id` or `project_ref`
*   `initial_fields`
*   `remove_hashes`

`initial_fields` is an object keyed by project field key or field ID. It seeds
field values at the same event hash as membership creation.

### 5.4. Issue Project Field Events

*   `issue.project_field_set`
*   `issue.project_field_cleared`

Minimum payloads:

| Event | Required payload |
| --- | --- |
| `issue.project_field_set` | `project_id` or `project_ref`, `field_id` or `field_key`, `value` |
| `issue.project_field_cleared` | `project_id` or `project_ref`, `field_id` or `field_key` |

These events target the issue, not the project. This keeps item movement and
planning history attached to the issue timeline.

Reducers MUST domain-reject field value events when the target issue is not a
visible member of the target project in the event's effective replay history.

### 5.5. Compatibility With Existing Kanban Columns

The current v1 projection stores issue project placement as `(project, column)`.
Spec05 clients MUST interpret that placement as:

*   project membership for `project`
*   a `status` field value of `column`, when the project has a `status` field
*   otherwise, a synthetic `column` field value of `column`

If a placement references a project name that has no accepted `project.created`
event, the UI MAY render a virtual legacy project. New writes SHOULD create or
resolve a concrete project object before writing richer field or view events.

## 6. View Semantics

All views in a project operate on the same issue membership set and field
values.

### 6.1. Table View

The table view is the canonical dense editing surface. It SHOULD support:

*   issue title, state, assignees, labels, milestone, and linked pull requests
*   project fields as editable columns
*   grouping by one field, such as `priority` or `status`
*   sorting by one or more fields
*   filtering by keyword and field predicates
*   inline creation of an issue in the current group

When a table is grouped by `priority`, adding an issue inside the `P1` group
SHOULD create project membership and set the issue's `priority` field to `P1`.
It MUST NOT set the issue's `status` unless the view has an explicit default.

### 6.2. Board View

The board view groups project issues by one select field. The default board
field SHOULD be `status`.

Each board column represents one option of the grouping field. Dragging an issue
card to another column MUST write an `issue.project_field_set` event for that
field. It MUST NOT remove and re-add project membership.

Board cards SHOULD show:

*   issue state
*   title
*   short issue ref or imported provider number
*   assignees
*   labels
*   priority or size when present
*   comment count
*   linked pull request state when present

### 6.3. Roadmap View

The roadmap view maps project issues onto time. It SHOULD use:

*   `start_at` as the start date
*   `target_at` as the target or end date
*   `status` for visual state
*   `priority` or another configured field for grouping

The roadmap view is not a full Gantt scheduler. It MUST NOT require dependency
edges, automatic date propagation, or critical-path analysis. If issue
dependencies are introduced in a later specification, roadmap MAY display them
as overlays.

Issues without roadmap dates SHOULD remain visible in an unscheduled section.

## 7. Default Templates

Templates seed fields and views only. The following templates are RECOMMENDED.

### 7.1. Table

Fields:

*   `status`: Todo, In Progress, Done

Views:

*   Table grouped by `status`

### 7.2. Board

Fields:

*   `status`: Todo, In Progress, Done

Views:

*   Board grouped by `status`
*   Table grouped by `status`

### 7.3. Roadmap

Fields:

*   `status`: Todo, In Progress, Done
*   `start_at`
*   `target_at`

Views:

*   Roadmap using `start_at` and `target_at`
*   Table grouped by `status`

### 7.4. Kanban

Fields:

*   `status`: Backlog, Ready, In Progress, In Review, Done
*   `priority`: P0, P1, P2

Views:

*   Board grouped by `status`
*   Table grouped by `priority`
*   My items table filtered by current principal

### 7.5. Feature Release

Fields:

*   `priority`: P0, P1, P2
*   `status`: Todo, In Progress, In Review, Done
*   `size`: S, M, L
*   `start_at`
*   `target_at`

Views:

*   Prioritized table grouped by `priority`
*   Status board grouped by `status`
*   Roadmap using `start_at` and `target_at`
*   Bugs view filtered by the `bug` label

### 7.6. Bug Tracker

Fields:

*   `priority`: P0, P1, P2
*   `status`: To Triage, Backlog, Ready, In Progress, In Review, Done

Views:

*   Prioritized bugs table grouped by `priority`
*   Triage board grouped by `status`
*   My items table filtered by current principal

### 7.7. Team Planning

Fields:

*   `status`: Todo, In Progress, Done
*   `iteration`
*   `estimate`
*   `start_at`
*   `target_at`

Views:

*   Backlog table grouped by `status`
*   Board grouped by `status`
*   Current iteration table filtered by `iteration`
*   Roadmap using `start_at` and `target_at`
*   My items table filtered by current principal

## 8. Web UI Flows

### 8.1. Project Index

`/projects` SHOULD list concrete projects, sorted by recent activity and then
name. Each project summary SHOULD show:

*   name
*   description
*   open or closed state
*   issue count
*   active views
*   recent activity

Legacy virtual projects MAY be shown, but they SHOULD be visually identified as
legacy/imported until a concrete project is created.

### 8.2. Create Project

The create project flow SHOULD collect:

*   project name
*   optional description
*   template
*   optional initial issues from a query or selection
*   optional default field values for imported issues

Creating a project from a template MUST emit project metadata, field, option,
and view events. Adding initial issues SHOULD emit membership events with
`initial_fields` instead of creating duplicate issues.

The UI SHOULD make it clear that table, board, and roadmap are starting views
over the same data.

### 8.3. Project Workspace

`/projects/<project-ref>` SHOULD show:

*   project header with name, state, and view controls
*   saved view tabs
*   filter and sort controls
*   the active view
*   item creation affordance
*   field editing controls appropriate to the active view

The active view SHOULD be addressable by URL so links preserve context.

### 8.4. Add Existing Issues

Users SHOULD be able to add existing issues by:

*   issue ref
*   keyword search
*   label, assignee, milestone, or state query
*   imported provider number when available

Adding existing issues MUST create project membership only. It MUST NOT clone
the issue.

### 8.5. Create Issue In Project

Creating a new issue from a project view MUST create a normal `issue.opened`
event and then add the issue to the project. The UI SHOULD batch these writes
when the event writer supports a single logical user action with stable
idempotency.

The new issue SHOULD inherit the current group defaults. For example:

*   creating in board column `In Progress` sets `status = In Progress`
*   creating in table group `P1` sets `priority = P1`
*   creating in a roadmap date range sets `start_at` and `target_at`

### 8.6. Edit Fields

Single-field edits SHOULD write the narrowest event possible. Multi-field edits
MAY be batched when the event model supports it.

The UI MUST distinguish issue lifecycle state from project status. Closing an
issue is a separate action from moving it to a `Done` project status.

## 9. Query and Filtering

Project views SHOULD reuse the issue query language where possible. The query
engine SHOULD support predicates for project fields:

*   `project:<project-ref>`
*   `status:<option>`
*   `priority:<option>`
*   `field:<key>=<value>`
*   `start:<date>`
*   `target:<date>`
*   `assignee:<principal>`
*   `label:<label>`
*   `state:open|closed`

Filtering MUST be view-local unless the user saves it into the view config.

## 10. Permissions

Project web actions require the same underlying permissions as their events:

*   creating or updating project metadata requires project write permission
*   adding an issue to a project requires issue write permission for that issue
*   setting a project field value requires issue write permission for that issue
*   creating a new issue requires issue create permission
*   editing saved fields or views requires project write permission

The UI SHOULD hide or disable controls that the current principal cannot use.
Server-side action handlers MUST still enforce permissions through event
validation.

## 11. Conflict Handling

Gitomi is local-first, so concurrent edits are normal.

Project field values are scalar registers. If two users concurrently set an
issue's project status to different values, the deterministic reducer winner is
visible. The issue timeline MUST retain both events.

Membership and field definitions are Observed-Remove Sets. A concurrent remove
MUST only remove add tags it causally observes or explicitly names.

When a saved view references a removed field, the UI SHOULD show the view with a
recoverable warning and offer to edit the view. It MUST NOT drop unknown or
missing-field config silently.

## 12. Index Requirements

The index SHOULD support efficient queries for:

*   projects by state and recent activity
*   project members by project
*   field values by project, field, and value
*   board columns with issue counts
*   table grouping counts
*   roadmap date ranges
*   current principal's assigned project issues

The index MAY derive denormalized read tables from accepted events. Derived
tables MUST be rebuildable from the event log.

## 13. Accessibility and Responsive Behavior

The web UI SHOULD provide keyboard and non-pointer alternatives for all project
mutations. Drag and drop MUST be progressive enhancement; moving a card between
statuses MUST also be possible through menus or forms.

On narrow screens:

*   table views MAY become horizontally scrollable
*   board columns MAY remain horizontally scrollable
*   roadmap views SHOULD provide a compact list grouped by date range
*   controls MUST remain reachable without overlapping content

## 14. Implementation Phases

### 14.1. Phase 1: Normalize Existing Projects UI

*   Continue rendering current `issue_projects(project, column_name)` data.
*   Treat columns as status values in the UI.
*   Add table and board views over the same issue set.
*   Keep roadmap as a read-only or limited editing view until date fields exist.

### 14.2. Phase 2: Add Fields and Views

*   Add project field and view events.
*   Add projection tables for fields, options, values, and views.
*   Map legacy kanban columns to `status`.
*   Add inline field editing in table and board views.

### 14.3. Phase 3: Add Roadmap Planning

*   Add date fields and roadmap view config.
*   Allow unscheduled, scheduled, and date-range editing.
*   Show roadmap bars without dependency scheduling.

### 14.4. Phase 4: Polish Templates and Import

*   Seed recommended templates.
*   Add initial issue selection by query.
*   Add project activity summaries.
*   Add field and view management UI.

## 15. Acceptance Criteria

A compliant implementation satisfies the following:

*   A project can contain issues without duplicating them.
*   A project can show the same issues in table and board views.
*   A board move changes only the configured grouping field.
*   A priority table group remains stable when status changes.
*   A roadmap can show issues with start and target dates.
*   Project status and issue open/closed state are separate controls.
*   Templates seed fields and views, not special project types.
*   Legacy kanban columns remain readable.
*   Every mutation is backed by signed Gitomi events.
