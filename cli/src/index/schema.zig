const sqlite_db = @import("sqlite_db.zig");

const SqliteDb = sqlite_db.SqliteDb;

pub fn createCursorsSchema(db: *SqliteDb) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS meta (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS ref_cursors (
        \\  ref TEXT PRIMARY KEY,
        \\  oid TEXT NOT NULL,
        \\  event_count INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS snapshot_meta (
        \\  snapshot_id TEXT PRIMARY KEY,
        \\  ref TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  inbox_heads TEXT NOT NULL,
        \\  tree_size INTEGER NOT NULL DEFAULT 0
        \\);
    );
}

pub fn createIndexSchema(db: *SqliteDb) !void {
    try db.exec(
        \\CREATE TABLE meta (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\);
        \\CREATE TABLE ref_heads (
        \\  ref TEXT PRIMARY KEY,
        \\  oid TEXT NOT NULL
        \\);
        \\CREATE TABLE events (
        \\  ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  ref TEXT NOT NULL,
        \\  "commit" TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  tree TEXT NOT NULL,
        \\  subject TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  empty_tree INTEGER NOT NULL,
        \\  valid_json INTEGER NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  actor_device TEXT NOT NULL,
        \\  seq INTEGER,
        \\  occurred_at TEXT NOT NULL,
        \\  domain_status TEXT NOT NULL,
        \\  rejection_reason TEXT NOT NULL,
        \\  UNIQUE(ref, "commit"),
        \\  UNIQUE(event_hash)
        \\);
        \\CREATE INDEX events_ref_ordinal_idx ON events(ref, ordinal);
        \\CREATE INDEX events_type_ordinal_idx ON events(event_type, ordinal);
        \\CREATE TABLE issues (
        \\  id TEXT PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  title_occurred_at TEXT NOT NULL,
        \\  title_actor_principal TEXT NOT NULL,
        \\  title_event_hash TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  body_occurred_at TEXT NOT NULL,
        \\  body_actor_principal TEXT NOT NULL,
        \\  body_event_hash TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  state_occurred_at TEXT NOT NULL,
        \\  state_actor_principal TEXT NOT NULL,
        \\  state_event_hash TEXT NOT NULL,
        \\  opened_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL
        \\);
        \\CREATE INDEX issues_state_opened_idx ON issues(state, opened_at);
        \\CREATE TABLE issue_labels (
        \\  issue_id TEXT NOT NULL,
        \\  label TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(issue_id, label, add_hash)
        \\);
        \\CREATE TABLE issue_assignees (
        \\  issue_id TEXT NOT NULL,
        \\  assignee TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(issue_id, assignee, add_hash)
        \\);
        \\CREATE TABLE issue_metadata (
        \\  issue_id TEXT PRIMARY KEY,
        \\  source_author TEXT NOT NULL,
        \\  milestone TEXT NOT NULL,
        \\  priority TEXT NOT NULL,
        \\  priority_occurred_at TEXT NOT NULL,
        \\  priority_actor_principal TEXT NOT NULL,
        \\  priority_event_hash TEXT NOT NULL,
        \\  status TEXT NOT NULL,
        \\  status_occurred_at TEXT NOT NULL,
        \\  status_actor_principal TEXT NOT NULL,
        \\  status_event_hash TEXT NOT NULL
        \\);
        \\CREATE TABLE issue_projects (
        \\  issue_id TEXT NOT NULL,
        \\  project TEXT NOT NULL,
        \\  column_name TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(issue_id, project, column_name, add_hash)
        \\);
        \\CREATE INDEX issue_projects_project_idx ON issue_projects(project, column_name, issue_id);
        \\CREATE TABLE projects (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  slug TEXT NOT NULL,
        \\  name_occurred_at TEXT NOT NULL,
        \\  name_actor_principal TEXT NOT NULL,
        \\  name_event_hash TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  description_occurred_at TEXT NOT NULL,
        \\  description_actor_principal TEXT NOT NULL,
        \\  description_event_hash TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  state_occurred_at TEXT NOT NULL,
        \\  state_actor_principal TEXT NOT NULL,
        \\  state_event_hash TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL
        \\);
        \\CREATE INDEX projects_name_idx ON projects(name, id);
        \\CREATE INDEX projects_slug_idx ON projects(slug, id);
        \\CREATE TABLE project_columns (
        \\  project_id TEXT NOT NULL,
        \\  column_name TEXT NOT NULL,
        \\  column_ref TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(project_id, column_name, add_hash)
        \\);
        \\CREATE INDEX project_columns_project_idx ON project_columns(project_id, column_name);
        \\CREATE INDEX project_columns_ref_idx ON project_columns(project_id, column_ref);
        \\CREATE TABLE project_memberships (
        \\  project_id TEXT NOT NULL,
        \\  issue_id TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  PRIMARY KEY(project_id, issue_id, add_hash)
        \\);
        \\CREATE INDEX project_memberships_project_idx ON project_memberships(project_id, issue_id);
        \\CREATE INDEX project_memberships_issue_idx ON project_memberships(issue_id, project_id);
        \\CREATE TABLE project_fields (
        \\  id TEXT PRIMARY KEY,
        \\  project_id TEXT NOT NULL,
        \\  key TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  field_type TEXT NOT NULL,
        \\  position INTEGER NOT NULL,
        \\  required INTEGER NOT NULL,
        \\  default_value_json TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  UNIQUE(project_id, key)
        \\);
        \\CREATE INDEX project_fields_project_idx ON project_fields(project_id, position, id);
        \\CREATE INDEX project_fields_key_idx ON project_fields(project_id, key);
        \\CREATE TABLE project_field_options (
        \\  id TEXT NOT NULL,
        \\  project_id TEXT NOT NULL,
        \\  field_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  color TEXT NOT NULL,
        \\  position INTEGER NOT NULL,
        \\  state TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  PRIMARY KEY(field_id, id)
        \\);
        \\CREATE INDEX project_field_options_field_idx ON project_field_options(field_id, position, id);
        \\CREATE TABLE project_field_values (
        \\  project_id TEXT NOT NULL,
        \\  issue_id TEXT NOT NULL,
        \\  field_id TEXT NOT NULL,
        \\  value_json TEXT NOT NULL,
        \\  occurred_at TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  PRIMARY KEY(project_id, issue_id, field_id)
        \\);
        \\CREATE INDEX project_field_values_project_field_idx ON project_field_values(project_id, field_id, value_json);
        \\CREATE INDEX project_field_values_issue_idx ON project_field_values(issue_id, project_id);
        \\CREATE TABLE project_views (
        \\  id TEXT PRIMARY KEY,
        \\  project_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  layout TEXT NOT NULL,
        \\  position INTEGER NOT NULL,
        \\  config_json TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL
        \\);
        \\CREATE INDEX project_views_project_idx ON project_views(project_id, position, id);
        \\CREATE TABLE milestones (
        \\  id TEXT PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  title_occurred_at TEXT NOT NULL,
        \\  title_actor_principal TEXT NOT NULL,
        \\  title_event_hash TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  description_occurred_at TEXT NOT NULL,
        \\  description_actor_principal TEXT NOT NULL,
        \\  description_event_hash TEXT NOT NULL,
        \\  due_at TEXT NOT NULL,
        \\  due_at_occurred_at TEXT NOT NULL,
        \\  due_at_actor_principal TEXT NOT NULL,
        \\  due_at_event_hash TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  state_occurred_at TEXT NOT NULL,
        \\  state_actor_principal TEXT NOT NULL,
        \\  state_event_hash TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL
        \\);
        \\CREATE INDEX milestones_title_idx ON milestones(title, id);
        \\CREATE TABLE label_definitions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  name_occurred_at TEXT NOT NULL,
        \\  name_actor_principal TEXT NOT NULL,
        \\  name_event_hash TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  description_occurred_at TEXT NOT NULL,
        \\  description_actor_principal TEXT NOT NULL,
        \\  description_event_hash TEXT NOT NULL,
        \\  color TEXT NOT NULL,
        \\  color_occurred_at TEXT NOT NULL,
        \\  color_actor_principal TEXT NOT NULL,
        \\  color_event_hash TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL,
        \\  UNIQUE(name)
        \\);
        \\CREATE INDEX label_definitions_name_idx ON label_definitions(name, id);
        \\CREATE TABLE pulls (
        \\  id TEXT PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  title_occurred_at TEXT NOT NULL,
        \\  title_actor_principal TEXT NOT NULL,
        \\  title_event_hash TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  body_occurred_at TEXT NOT NULL,
        \\  body_actor_principal TEXT NOT NULL,
        \\  body_event_hash TEXT NOT NULL,
        \\  state TEXT NOT NULL,
        \\  state_occurred_at TEXT NOT NULL,
        \\  state_actor_principal TEXT NOT NULL,
        \\  state_event_hash TEXT NOT NULL,
        \\  base_ref TEXT NOT NULL,
        \\  base_occurred_at TEXT NOT NULL,
        \\  base_actor_principal TEXT NOT NULL,
        \\  base_event_hash TEXT NOT NULL,
        \\  head_ref TEXT NOT NULL,
        \\  head_occurred_at TEXT NOT NULL,
        \\  head_actor_principal TEXT NOT NULL,
        \\  head_event_hash TEXT NOT NULL,
        \\  draft INTEGER NOT NULL,
        \\  merge_oid TEXT NOT NULL,
        \\  target_oid TEXT NOT NULL,
        \\  opened_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL
        \\);
        \\CREATE INDEX pulls_state_opened_idx ON pulls(state, opened_at);
        \\CREATE TABLE pull_labels (
        \\  pull_id TEXT NOT NULL,
        \\  label TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(pull_id, label, add_hash)
        \\);
        \\CREATE TABLE pull_assignees (
        \\  pull_id TEXT NOT NULL,
        \\  assignee TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(pull_id, assignee, add_hash)
        \\);
        \\CREATE TABLE pull_reviewers (
        \\  pull_id TEXT NOT NULL,
        \\  reviewer TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(pull_id, reviewer, add_hash)
        \\);
        \\CREATE TABLE pull_metadata (
        \\  pull_id TEXT PRIMARY KEY,
        \\  source_author TEXT NOT NULL,
        \\  commit_count INTEGER NOT NULL,
        \\  changed_files INTEGER NOT NULL,
        \\  additions INTEGER NOT NULL,
        \\  deletions INTEGER NOT NULL
        \\);
        \\CREATE TABLE comments (
        \\  id TEXT PRIMARY KEY,
        \\  parent_kind TEXT NOT NULL,
        \\  parent_id TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  body_occurred_at TEXT NOT NULL,
        \\  body_actor_principal TEXT NOT NULL,
        \\  body_event_hash TEXT NOT NULL,
        \\  redacted INTEGER NOT NULL,
        \\  redacted_at TEXT NOT NULL,
        \\  redacted_actor_principal TEXT NOT NULL,
        \\  redacted_event_hash TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  author_principal TEXT NOT NULL,
        \\  author_device TEXT NOT NULL,
        \\  source_author TEXT NOT NULL,
        \\  reply_parent_id TEXT NOT NULL,
        \\  reply_parent_hash TEXT NOT NULL
        \\);
        \\CREATE INDEX comments_parent_created_idx ON comments(parent_kind, parent_id, created_at);
        \\CREATE TABLE reactions (
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  emoji TEXT NOT NULL,
        \\  actor_principal TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  PRIMARY KEY(object_kind, object_id, emoji, actor_principal, add_hash)
        \\);
        \\CREATE INDEX reactions_object_idx ON reactions(object_kind, object_id, emoji);
        \\CREATE INDEX reactions_actor_idx ON reactions(actor_principal, object_kind, object_id);
        \\CREATE TABLE commit_references (
        \\  commit_oid TEXT NOT NULL,
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  prefix TEXT NOT NULL,
        \\  PRIMARY KEY(commit_oid, object_kind, object_id)
        \\);
        \\CREATE INDEX commit_references_object_idx ON commit_references(object_kind, object_id, commit_oid);
        \\CREATE TABLE legacy_aliases (
        \\  provider TEXT NOT NULL,
        \\  object_kind TEXT NOT NULL,
        \\  object_id TEXT NOT NULL,
        \\  number INTEGER NOT NULL,
        \\  PRIMARY KEY(provider, object_kind, number),
        \\  UNIQUE(provider, object_kind, object_id)
        \\);
        \\CREATE INDEX legacy_aliases_object_idx ON legacy_aliases(provider, object_kind, object_id);
        \\CREATE TABLE acl_roles (
        \\  principal TEXT PRIMARY KEY,
        \\  role TEXT NOT NULL,
        \\  grant_event_hash TEXT NOT NULL
        \\);
        \\CREATE TABLE acl_role_events (
        \\  principal TEXT NOT NULL,
        \\  role TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  PRIMARY KEY(principal, event_hash)
        \\);
        \\CREATE INDEX acl_role_events_principal_idx ON acl_role_events(principal);
        \\CREATE TABLE acl_delegations (
        \\  principal TEXT NOT NULL,
        \\  device TEXT NOT NULL,
        \\  capability TEXT NOT NULL,
        \\  scope TEXT NOT NULL,
        \\  key_fingerprint TEXT NOT NULL,
        \\  public_key TEXT NOT NULL,
        \\  grant_event_hash TEXT NOT NULL,
        \\  PRIMARY KEY(principal, device, capability, scope, key_fingerprint)
        \\);
        \\CREATE INDEX acl_delegations_principal_idx ON acl_delegations(principal, device, capability);
        \\CREATE TABLE acl_delegation_events (
        \\  principal TEXT NOT NULL,
        \\  device TEXT NOT NULL,
        \\  capability TEXT NOT NULL,
        \\  scope TEXT NOT NULL,
        \\  key_fingerprint TEXT NOT NULL,
        \\  public_key TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  PRIMARY KEY(principal, device, capability, scope, event_hash)
        \\);
        \\CREATE INDEX acl_delegation_events_principal_idx ON acl_delegation_events(principal, device, capability, scope);
        \\CREATE TABLE identity_devices (
        \\  principal TEXT NOT NULL,
        \\  device TEXT NOT NULL,
        \\  key_fingerprint TEXT NOT NULL,
        \\  public_key TEXT NOT NULL,
        \\  added_event_hash TEXT NOT NULL,
        \\  revoked_event_hash TEXT,
        \\  PRIMARY KEY(principal, device, key_fingerprint)
        \\);
        \\CREATE INDEX identity_devices_principal_idx ON identity_devices(principal);
        \\CREATE TABLE identity_device_events (
        \\  principal TEXT NOT NULL,
        \\  device TEXT NOT NULL,
        \\  key_fingerprint TEXT NOT NULL,
        \\  public_key TEXT NOT NULL,
        \\  event_hash TEXT NOT NULL,
        \\  event_type TEXT NOT NULL,
        \\  PRIMARY KEY(principal, device, event_hash)
        \\);
        \\CREATE INDEX identity_device_events_device_idx ON identity_device_events(principal, device);
    );
}
