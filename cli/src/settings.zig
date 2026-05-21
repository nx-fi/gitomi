const std = @import("std");

const index = @import("index.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const sqlite = index.sqlite;

const settings_schema_version = "1";
const default_ollama_endpoint = "http://localhost:11434";
const default_project_view_values = [_][]const u8{ "overview", "table", "board", "roadmap", "issues", "activity" };

pub const AiModel = struct {
    id: []u8,
    provider_kind: []u8,
    provider: []u8,
    display_name: []u8,
    endpoint_url: []u8,
    chat_model: []u8,
    embedding_model: []u8,
    api_key_env: []u8,
    enabled: bool,
    status: []u8,
    notes: []u8,

    pub fn deinit(self: *AiModel, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.provider_kind);
        allocator.free(self.provider);
        allocator.free(self.display_name);
        allocator.free(self.endpoint_url);
        allocator.free(self.chat_model);
        allocator.free(self.embedding_model);
        allocator.free(self.api_key_env);
        allocator.free(self.status);
        allocator.free(self.notes);
        self.* = undefined;
    }
};

pub const OllamaUpdate = struct {
    endpoint_url: []const u8,
    chat_model: []const u8,
    embedding_model: []const u8,
    enabled: bool,
};

pub fn loadAiModels(allocator: Allocator, repo: Repo) ![]AiModel {
    var db = try openSettingsDb(allocator, repo);
    defer db.deinit();
    try ensureSettingsSchema(&db);

    var stmt = try db.prepare(
        \\SELECT id, provider_kind, provider, display_name, endpoint_url,
        \\       chat_model, embedding_model, api_key_env, enabled, status, notes
        \\FROM ai_models
        \\ORDER BY CASE provider_kind
        \\  WHEN 'local' THEN 0
        \\  WHEN 'remote' THEN 1
        \\  WHEN 'platform' THEN 2
        \\  ELSE 3
        \\END, display_name
    );
    defer stmt.deinit();

    var models: std.ArrayList(AiModel) = .empty;
    errdefer {
        for (models.items) |*model| model.deinit(allocator);
        models.deinit(allocator);
    }

    while (try stmt.step()) {
        try models.append(allocator, .{
            .id = try stmt.columnTextDup(allocator, 0),
            .provider_kind = try stmt.columnTextDup(allocator, 1),
            .provider = try stmt.columnTextDup(allocator, 2),
            .display_name = try stmt.columnTextDup(allocator, 3),
            .endpoint_url = try stmt.columnTextDup(allocator, 4),
            .chat_model = try stmt.columnTextDup(allocator, 5),
            .embedding_model = try stmt.columnTextDup(allocator, 6),
            .api_key_env = try stmt.columnTextDup(allocator, 7),
            .enabled = stmt.columnInt(8) != 0,
            .status = try stmt.columnTextDup(allocator, 9),
            .notes = try stmt.columnTextDup(allocator, 10),
        });
    }

    return try models.toOwnedSlice(allocator);
}

pub fn freeAiModels(allocator: Allocator, models: []AiModel) void {
    for (models) |*model| model.deinit(allocator);
    allocator.free(models);
}

pub fn updateOllamaModel(allocator: Allocator, repo: Repo, update: OllamaUpdate) !void {
    var db = try openSettingsDb(allocator, repo);
    defer db.deinit();
    try ensureSettingsSchema(&db);

    var stmt = try db.prepare(
        \\INSERT INTO ai_models(
        \\  id, provider_kind, provider, display_name, endpoint_url,
        \\  chat_model, embedding_model, api_key_env, enabled, status, notes
        \\) VALUES (
        \\  'local:ollama', 'local', 'ollama', 'Ollama', ?,
        \\  ?, ?, '', ?, 'configurable', 'Runs local chat and embedding models through the Ollama HTTP API.'
        \\)
        \\ON CONFLICT(id) DO UPDATE SET
        \\  endpoint_url = excluded.endpoint_url,
        \\  chat_model = excluded.chat_model,
        \\  embedding_model = excluded.embedding_model,
        \\  enabled = excluded.enabled
    );
    defer stmt.deinit();
    try stmt.bindText(1, update.endpoint_url);
    try stmt.bindText(2, update.chat_model);
    try stmt.bindText(3, update.embedding_model);
    try stmt.bindInt(4, if (update.enabled) 1 else 0);
    try stmt.stepDone();
}

pub fn loadProjectDefaultView(allocator: Allocator, repo: Repo, project_id: []const u8) !?[]u8 {
    if (project_id.len == 0) return null;
    var db = try openSettingsDb(allocator, repo);
    defer db.deinit();
    try ensureSettingsSchema(&db);

    var stmt = try db.prepare(
        \\SELECT view
        \\FROM project_view_preferences
        \\WHERE project_id = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (!(try stmt.step())) return null;

    const view = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(view);
    if (!isProjectDefaultViewValue(view)) {
        allocator.free(view);
        return null;
    }
    return view;
}

pub fn saveProjectDefaultView(allocator: Allocator, repo: Repo, project_id: []const u8, view: []const u8) !void {
    if (project_id.len == 0 or !isProjectDefaultViewValue(view)) return error.InvalidProjectDefaultView;
    var db = try openSettingsDb(allocator, repo);
    defer db.deinit();
    try ensureSettingsSchema(&db);

    const now = try util.rfc3339Now(allocator);
    defer allocator.free(now);
    var stmt = try db.prepare(
        \\INSERT INTO project_view_preferences(project_id, view, updated_at)
        \\VALUES (?, ?, ?)
        \\ON CONFLICT(project_id) DO UPDATE SET
        \\  view = excluded.view,
        \\  updated_at = excluded.updated_at
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, view);
    try stmt.bindText(3, now);
    try stmt.stepDone();
}

pub fn isProjectDefaultViewValue(value: []const u8) bool {
    for (default_project_view_values) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn openSettingsDb(allocator: Allocator, repo: Repo) !SqliteDb {
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), repo.gitomi_dir);
    return try SqliteDb.open(allocator, repo.settings_path, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, false);
}

fn ensureSettingsSchema(db: *SqliteDb) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS meta (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\);
    );

    if (!(try schemaVersionMatches(db))) {
        try dropSettingsSchema(db);
        try createSettingsSchema(db);
    }

    try seedAiModelDefaults(db);
    try ensureProjectViewPreferencesSchema(db);
}

fn schemaVersionMatches(db: *SqliteDb) !bool {
    var stmt = try db.prepare("SELECT value FROM meta WHERE key = 'schema_version'");
    defer stmt.deinit();
    if (!(try stmt.step())) return false;
    const value = try stmt.columnTextDup(db.allocator, 0);
    defer db.allocator.free(value);
    return std.mem.eql(u8, value, settings_schema_version);
}

fn dropSettingsSchema(db: *SqliteDb) !void {
    try db.exec(
        \\DROP TABLE IF EXISTS project_view_preferences;
        \\DROP TABLE IF EXISTS ai_models;
        \\DROP TABLE IF EXISTS meta;
    );
}

fn createSettingsSchema(db: *SqliteDb) !void {
    try db.exec(
        \\CREATE TABLE meta (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\);
        \\CREATE TABLE ai_models (
        \\  id TEXT PRIMARY KEY,
        \\  provider_kind TEXT NOT NULL,
        \\  provider TEXT NOT NULL,
        \\  display_name TEXT NOT NULL,
        \\  endpoint_url TEXT NOT NULL,
        \\  chat_model TEXT NOT NULL,
        \\  embedding_model TEXT NOT NULL,
        \\  api_key_env TEXT NOT NULL,
        \\  enabled INTEGER NOT NULL,
        \\  status TEXT NOT NULL,
        \\  notes TEXT NOT NULL
        \\);
        \\CREATE INDEX ai_models_kind_idx ON ai_models(provider_kind, provider);
        \\CREATE TABLE project_view_preferences (
        \\  project_id TEXT PRIMARY KEY,
        \\  view TEXT NOT NULL,
        \\  updated_at TEXT NOT NULL
        \\);
        \\INSERT INTO meta(key, value) VALUES ('schema_version', '1');
    );
}

fn ensureProjectViewPreferencesSchema(db: *SqliteDb) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS project_view_preferences (
        \\  project_id TEXT PRIMARY KEY,
        \\  view TEXT NOT NULL,
        \\  updated_at TEXT NOT NULL
        \\);
    );
}

fn seedAiModelDefaults(db: *SqliteDb) !void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO ai_models(
        \\  id, provider_kind, provider, display_name, endpoint_url,
        \\  chat_model, embedding_model, api_key_env, enabled, status, notes
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.deinit();

    try insertDefaultModel(&stmt, .{
        .id = "local:ollama",
        .provider_kind = "local",
        .provider = "ollama",
        .display_name = "Ollama",
        .endpoint_url = default_ollama_endpoint,
        .chat_model = "",
        .embedding_model = "",
        .api_key_env = "",
        .enabled = false,
        .status = "configurable",
        .notes = "Runs local chat and embedding models through the Ollama HTTP API.",
    });
    try insertDefaultModel(&stmt, .{
        .id = "remote:byo-api-key",
        .provider_kind = "remote",
        .provider = "openai-compatible",
        .display_name = "Remote API key",
        .endpoint_url = "",
        .chat_model = "",
        .embedding_model = "",
        .api_key_env = "OPENAI_API_KEY",
        .enabled = false,
        .status = "planned",
        .notes = "Reserved for user-supplied API keys and OpenAI-compatible providers.",
    });
    try insertDefaultModel(&stmt, .{
        .id = "platform:gitomi",
        .provider_kind = "platform",
        .provider = "gitomi",
        .display_name = "Gitomi Platform",
        .endpoint_url = "",
        .chat_model = "",
        .embedding_model = "",
        .api_key_env = "",
        .enabled = false,
        .status = "planned",
        .notes = "Reserved for account-backed platform models and billing.",
    });
}

const DefaultModel = struct {
    id: []const u8,
    provider_kind: []const u8,
    provider: []const u8,
    display_name: []const u8,
    endpoint_url: []const u8,
    chat_model: []const u8,
    embedding_model: []const u8,
    api_key_env: []const u8,
    enabled: bool,
    status: []const u8,
    notes: []const u8,
};

fn insertDefaultModel(stmt: *index.SqliteStmt, model: DefaultModel) !void {
    try stmt.reset();
    try stmt.bindText(1, model.id);
    try stmt.bindText(2, model.provider_kind);
    try stmt.bindText(3, model.provider);
    try stmt.bindText(4, model.display_name);
    try stmt.bindText(5, model.endpoint_url);
    try stmt.bindText(6, model.chat_model);
    try stmt.bindText(7, model.embedding_model);
    try stmt.bindText(8, model.api_key_env);
    try stmt.bindInt(9, if (model.enabled) 1 else 0);
    try stmt.bindText(10, model.status);
    try stmt.bindText(11, model.notes);
    try stmt.stepDone();
}

test "settings database seeds and updates Ollama model settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(@import("compat").io(), ".", allocator);
    defer allocator.free(root);

    var repo = Repo{
        .allocator = allocator,
        .root = try allocator.dupe(u8, root),
        .git_dir = try allocator.dupe(u8, root),
        .gitomi_dir = try std.fs.path.join(allocator, &.{ root, "gitomi" }),
        .config_path = try std.fs.path.join(allocator, &.{ root, "gitomi", "config.toml" }),
        .index_path = try std.fs.path.join(allocator, &.{ root, "gitomi", "index.sqlite" }),
        .cursors_path = try std.fs.path.join(allocator, &.{ root, "gitomi", "cursors.sqlite" }),
        .settings_path = try std.fs.path.join(allocator, &.{ root, "gitomi", "settings.sqlite" }),
    };
    defer repo.deinit();

    const models = try loadAiModels(allocator, repo);
    defer freeAiModels(allocator, models);
    try std.testing.expectEqual(@as(usize, 3), models.len);
    const seeded = findModelForTest(models, "local:ollama").?;
    try std.testing.expect(!seeded.enabled);
    try std.testing.expectEqualStrings(default_ollama_endpoint, seeded.endpoint_url);

    try updateOllamaModel(allocator, repo, .{
        .endpoint_url = "http://127.0.0.1:11434",
        .chat_model = "llama3.1",
        .embedding_model = "nomic-embed-text",
        .enabled = true,
    });

    const updated_models = try loadAiModels(allocator, repo);
    defer freeAiModels(allocator, updated_models);
    const updated = findModelForTest(updated_models, "local:ollama").?;
    try std.testing.expect(updated.enabled);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434", updated.endpoint_url);
    try std.testing.expectEqualStrings("llama3.1", updated.chat_model);
    try std.testing.expectEqualStrings("nomic-embed-text", updated.embedding_model);
}

fn findModelForTest(models: []const AiModel, id: []const u8) ?*const AiModel {
    for (models) |*model| {
        if (std.mem.eql(u8, model.id, id)) return model;
    }
    return null;
}
