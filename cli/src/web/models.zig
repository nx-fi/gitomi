const std = @import("std");

const repo_mod = @import("../repo.zig");
const settings = @import("../settings.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendHtml = shared.appendHtml;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const formValueOwned = shared.formValueOwned;
const sendResponse = shared.sendResponse;

const FlashKind = enum { success, failure };

const Flash = struct {
    kind: FlashKind,
    message: []const u8,
};

pub fn renderModelsPage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8) ![]u8 {
    var flash: ?Flash = null;
    if (try shared.queryValueOwned(allocator, target, "saved")) |saved| {
        defer allocator.free(saved);
        if (std.mem.eql(u8, saved, "1")) {
            flash = .{ .kind = .success, .message = "AI model settings saved." };
        }
    }
    return renderModelsPageWithFlash(allocator, repo, csrf_token, flash);
}

pub fn handleModelsPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8, csrf_token: []const u8) !void {
    const csrf_owned = (try formValueOwned(allocator, form_body, "csrf_token")) orelse {
        try sendModelsError(allocator, repo, stream, 403, "Forbidden", "Invalid model settings form token.", csrf_token);
        return;
    };
    defer allocator.free(csrf_owned);
    if (!std.mem.eql(u8, csrf_owned, csrf_token)) {
        try sendModelsError(allocator, repo, stream, 403, "Forbidden", "Invalid model settings form token.", csrf_token);
        return;
    }

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    if (!std.mem.eql(u8, action, "update-ollama")) {
        try sendModelsError(allocator, repo, stream, 422, "Unprocessable Entity", "Unknown model settings action.", csrf_token);
        return;
    }

    const endpoint_owned = (try formValueOwned(allocator, form_body, "endpoint_url")) orelse try allocator.dupe(u8, "");
    defer allocator.free(endpoint_owned);
    const chat_model_owned = (try formValueOwned(allocator, form_body, "chat_model")) orelse try allocator.dupe(u8, "");
    defer allocator.free(chat_model_owned);
    const embedding_model_owned = (try formValueOwned(allocator, form_body, "embedding_model")) orelse try allocator.dupe(u8, "");
    defer allocator.free(embedding_model_owned);
    const enabled_owned = try formValueOwned(allocator, form_body, "enabled");
    defer if (enabled_owned) |value| allocator.free(value);

    const endpoint_trimmed = std.mem.trim(u8, endpoint_owned, " \t\r\n");
    const endpoint = if (endpoint_trimmed.len == 0) "http://localhost:11434" else endpoint_trimmed;
    const chat_model = std.mem.trim(u8, chat_model_owned, " \t\r\n");
    const embedding_model = std.mem.trim(u8, embedding_model_owned, " \t\r\n");
    const enabled = enabled_owned != null;

    if (endpoint.len > 512 or chat_model.len > 256 or embedding_model.len > 256) {
        try sendModelsError(allocator, repo, stream, 422, "Unprocessable Entity", "Model settings are too long.", csrf_token);
        return;
    }
    if (!std.mem.startsWith(u8, endpoint, "http://") and !std.mem.startsWith(u8, endpoint, "https://")) {
        try sendModelsError(allocator, repo, stream, 422, "Unprocessable Entity", "Ollama endpoint must start with http:// or https://.", csrf_token);
        return;
    }
    if (enabled and chat_model.len == 0 and embedding_model.len == 0) {
        try sendModelsError(allocator, repo, stream, 422, "Unprocessable Entity", "Set at least one Ollama model before enabling it.", csrf_token);
        return;
    }

    try settings.updateOllamaModel(allocator, repo, .{
        .endpoint_url = endpoint,
        .chat_model = chat_model,
        .embedding_model = embedding_model,
        .enabled = enabled,
    });
    try shared.sendRedirect(allocator, stream, "/settings/models?saved=1");
}

fn sendModelsError(allocator: Allocator, repo: Repo, stream: std.net.Stream, status: u16, reason: []const u8, message: []const u8, csrf_token: []const u8) !void {
    const body = try renderModelsPageWithFlash(allocator, repo, csrf_token, .{ .kind = .failure, .message = message });
    defer allocator.free(body);
    try sendResponse(allocator, stream, status, reason, "text/html", body, null);
}

fn renderModelsPageWithFlash(allocator: Allocator, repo: Repo, csrf_token: []const u8, flash: ?Flash) ![]u8 {
    const models = try settings.loadAiModels(allocator, repo);
    defer settings.freeAiModels(allocator, models);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "AI Models", "models");
    try shared.appendSettingsLayoutStart(&buf, allocator, "models");
    try buf.appendSlice(allocator, "<section class=\"panel settings-panel models-panel\">");
    try appendSectionHead(&buf, allocator, "Settings", "AI Models", null);
    if (flash) |item| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash {kind}">{message}</div>
        , .{
            .kind = switch (item.kind) {
                .success => "success",
                .failure => "error",
            },
            .message = item.message,
        });
    }

    const ollama = findModel(models, "local:ollama");
    try appendOllamaCard(&buf, allocator, ollama, csrf_token);
    try appendModelProviderGrid(&buf, allocator, models);
    try appendRetrievalFoundation(&buf, allocator);

    try buf.appendSlice(allocator, "</section>");
    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendOllamaCard(buf: *std.ArrayList(u8), allocator: Allocator, model_opt: ?*const settings.AiModel, csrf_token: []const u8) !void {
    const endpoint_url = if (model_opt) |model| model.endpoint_url else "http://localhost:11434";
    const chat_model = if (model_opt) |model| model.chat_model else "";
    const embedding_model = if (model_opt) |model| model.embedding_model else "";
    const enabled = if (model_opt) |model| model.enabled else false;

    try buf.appendSlice(allocator,
        \\<section class="ai-model-local">
        \\  <div class="ai-model-local-head">
        \\    <div><h2>Local Models</h2><p>Ollama is the first supported local provider.</p></div>
    );
    try appendStatusPill(buf, allocator, if (enabled) "Enabled" else "Not enabled", if (enabled) "enabled" else "muted");
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <form class="issue-form ai-model-form" method="post" action="/settings/models">
        \\    <input type="hidden" name="csrf_token" value="
    );
    try appendHtml(buf, allocator, csrf_token);
    try buf.appendSlice(allocator,
        \\">
        \\    <input type="hidden" name="action" value="update-ollama">
        \\    <div class="ai-model-form-grid">
        \\      <label>Endpoint<input name="endpoint_url" value="
    );
    try appendHtml(buf, allocator, endpoint_url);
    try buf.appendSlice(allocator,
        \\" placeholder="http://localhost:11434"></label>
        \\      <label>Chat model<input name="chat_model" value="
    );
    try appendHtml(buf, allocator, chat_model);
    try buf.appendSlice(allocator,
        \\" placeholder="llama3.1"></label>
        \\      <label>Embedding model<input name="embedding_model" value="
    );
    try appendHtml(buf, allocator, embedding_model);
    try buf.appendSlice(allocator,
        \\" placeholder="nomic-embed-text"></label>
        \\      <label class="ai-model-check"><input type="checkbox" name="enabled" value="1"
    );
    if (enabled) try buf.appendSlice(allocator, " checked");
    try buf.appendSlice(allocator,
        \\><span>Enable local models</span></label>
        \\    </div>
        \\    <div class="form-actions"><button class="button primary" type="submit">Save local model</button></div>
        \\  </form>
        \\</section>
    );
}

fn appendModelProviderGrid(buf: *std.ArrayList(u8), allocator: Allocator, models: []const settings.AiModel) !void {
    try buf.appendSlice(allocator, "<div class=\"ai-model-provider-grid\">");
    for (models) |*model| {
        if (std.mem.eql(u8, model.id, "local:ollama")) continue;
        try appendProviderModelCard(buf, allocator, model);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProviderModelCard(buf: *std.ArrayList(u8), allocator: Allocator, model: *const settings.AiModel) !void {
    try buf.appendSlice(allocator, "<section class=\"ai-model-provider-card\"><div class=\"ai-model-provider-head\"><div><h2>");
    try appendHtml(buf, allocator, model.display_name);
    try buf.appendSlice(allocator, "</h2><p>");
    try appendHtml(buf, allocator, providerLabel(model.provider_kind));
    try buf.appendSlice(allocator, "</p></div>");
    try appendStatusPill(buf, allocator, if (std.mem.eql(u8, model.status, "planned")) "Planned" else "Ready", if (std.mem.eql(u8, model.status, "planned")) "planned" else "enabled");
    try buf.appendSlice(allocator, "</div><p class=\"ai-model-notes\">");
    try appendHtml(buf, allocator, model.notes);
    try buf.appendSlice(allocator, "</p>");
    if (model.api_key_env.len != 0) {
        try buf.appendSlice(allocator, "<div class=\"ai-model-meta\"><span>Secret</span><code>");
        try appendHtml(buf, allocator, model.api_key_env);
        try buf.appendSlice(allocator, "</code></div>");
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendRetrievalFoundation(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<section class="ai-retrieval-card">
        \\  <div class="ai-model-provider-head">
        \\    <div><h2>Metadata Retrieval</h2><p>Issues, pull requests, comments, labels, and metadata.</p></div>
    );
    try appendStatusPill(buf, allocator, "BM25 active", "enabled");
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <div class="ai-retrieval-rows">
        \\    <div><strong>SQLite FTS5</strong><span>Indexed for lexical retrieval and BM25 ranking.</span></div>
        \\    <div><strong>Vector embeddings</strong><span>Reserved for a local embedding model and SQLite vector extension.</span></div>
        \\    <div><strong>Hybrid fusion</strong><span>Reserved for combining BM25 and dense results before AI features consume context.</span></div>
        \\  </div>
        \\</section>
    );
}

fn appendStatusPill(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, kind: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="ai-model-status {kind}">{label}</span>
    , .{ .kind = kind, .label = label });
}

fn providerLabel(provider_kind: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_kind, "remote")) return "Remote models";
    if (std.mem.eql(u8, provider_kind, "platform")) return "Platform supplied models";
    return "Local models";
}

fn findModel(models: []const settings.AiModel, id: []const u8) ?*const settings.AiModel {
    for (models) |*model| {
        if (std.mem.eql(u8, model.id, id)) return model;
    }
    return null;
}
