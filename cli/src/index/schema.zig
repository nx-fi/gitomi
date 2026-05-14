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
        \\  milestone TEXT NOT NULL
        \\);
        \\CREATE TABLE issue_projects (
        \\  issue_id TEXT NOT NULL,
        \\  project TEXT NOT NULL,
        \\  column_name TEXT NOT NULL,
        \\  add_hash TEXT NOT NULL,
        \\  PRIMARY KEY(issue_id, project, column_name, add_hash)
        \\);
        \\CREATE INDEX issue_projects_project_idx ON issue_projects(project, column_name, issue_id);
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
