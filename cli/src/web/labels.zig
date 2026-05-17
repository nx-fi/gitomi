const std = @import("std");
const event_mod = @import("../event.zig");
const event_writer_mod = @import("../event_writer.zig");
const index = @import("../index.zig");
const issue_mod = @import("../issue.zig");
const issues_page = @import("issues.zig");
const pull_mod = @import("../pr.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");
const zwf = @import("../zwf.zig");

const Allocator = std.mem.Allocator;
const EventWriter = event_writer_mod.EventWriter;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const appendUrlEncoded = shared.appendUrlEncoded;
const formValueOwned = issues_page.formValueOwned;
const groupedUnsigned = shared.groupedUnsigned;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sqlite = index.sqlite;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;

const label_rows_sql =
    \\WITH label_names AS (
    \\  SELECT name AS label FROM label_definitions
    \\  UNION
    \\  SELECT label FROM issue_labels
    \\  UNION
    \\  SELECT label FROM pull_labels
    \\),
    \\usage_totals AS (
    \\  SELECT label, SUM(issue_count) AS issue_count, SUM(pull_count) AS pull_count
    \\  FROM (
    \\    SELECT il.label, COUNT(DISTINCT il.issue_id) AS issue_count, 0 AS pull_count
    \\    FROM issue_labels il
    \\    JOIN issues i ON i.id = il.issue_id
    \\    WHERE i.state = 'open'
    \\    GROUP BY il.label
    \\    UNION ALL
    \\    SELECT pl.label, 0 AS issue_count, COUNT(DISTINCT pl.pull_id) AS pull_count
    \\    FROM pull_labels pl
    \\    JOIN pulls p ON p.id = pl.pull_id
    \\    WHERE p.state = 'open'
    \\    GROUP BY pl.label
    \\  )
    \\  GROUP BY label
    \\)
    \\SELECT label_names.label,
    \\       COALESCE(label_definitions.id, ''),
    \\       COALESCE(label_definitions.description, ''),
    \\       COALESCE(label_definitions.color, ''),
    \\       COALESCE(usage_totals.issue_count, 0),
    \\       COALESCE(usage_totals.pull_count, 0)
    \\FROM label_names
    \\LEFT JOIN label_definitions ON label_definitions.name = label_names.label
    \\LEFT JOIN usage_totals ON usage_totals.label = label_names.label
    \\ORDER BY CASE WHEN label_definitions.id IS NULL THEN 1 ELSE 0 END,
    \\         label_definitions.position,
    \\         lower(label_names.label),
    \\         label_names.label
;

pub fn renderLabelsPage(allocator: Allocator, repo: Repo, csrf_token: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Labels", "labels", "/settings/labels")) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const label_count = try countLabels(&db);

    try appendShellStart(&buf, allocator, repo, "Labels", "labels");
    try shared.appendSettingsLayoutStart(&buf, allocator, "labels");
    try appendLabelsHeader(&buf, allocator, csrf_token);
    try appendLabelsToolbar(&buf, allocator);
    try appendLabelDialog(&buf, allocator, csrf_token);
    try appendLabelsListStart(&buf, allocator, label_count);

    var stmt = try db.prepare(label_rows_sql);
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const label_id = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(label_id);
        const description = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(description);
        const color = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(color);
        const issue_count = @as(usize, @intCast(stmt.columnInt64(4)));
        const pull_count = @as(usize, @intCast(stmt.columnInt64(5)));
        try appendLabelRow(&buf, allocator, label, label_id, description, color, issue_count, pull_count, shown, csrf_token);
        shown += 1;
    }

    if (shown == 0) {
        try buf.appendSlice(allocator, "<div class=\"labels-empty-state\"><strong>No labels found.</strong><p>Labels appear here after issues or pull requests use them.</p></div>");
    }

    try buf.appendSlice(allocator,
        \\    </div>
        \\  <div class="labels-empty-state" data-label-empty hidden><strong>No matching labels.</strong><p>Change the search text to widen the list.</p></div>
        \\  </section>
        \\</section>
    );
    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn handleLabelsPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    try index.ensureIndex(allocator, repo);

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");

    const label_owned = (try formValueOwned(allocator, form_body, "label")) orelse try allocator.dupe(u8, "");
    defer allocator.free(label_owned);
    const label = std.mem.trim(u8, label_owned, " \t\r\n");

    if (std.mem.eql(u8, action, "create")) {
        const new_label_owned = (try formValueOwned(allocator, form_body, "new_label")) orelse try allocator.dupe(u8, "");
        defer allocator.free(new_label_owned);
        const new_label = std.mem.trim(u8, new_label_owned, " \t\r\n");
        if (new_label.len == 0) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Label name is required\n");
            return;
        }

        const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
        defer allocator.free(description_owned);
        const description = std.mem.trim(u8, description_owned, " \t\r\n");

        const color_owned = (try formValueOwned(allocator, form_body, "color")) orelse try allocator.dupe(u8, "");
        defer allocator.free(color_owned);
        const color = normalizeLabelColorOwned(allocator, color_owned, new_label) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Color must be a hex value like #0075ca\n");
            return;
        };
        defer allocator.free(color);

        var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
        defer db.deinit();
        if (try labelNameExists(&db, new_label)) {
            try sendPlainResponse(allocator, stream, 409, "Conflict", "Label already exists\n");
            return;
        }
        const position = try nextLabelPosition(&db);

        writeLabelCreatedEvent(allocator, new_label, description, color, position) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not create label\n");
            return;
        };
        try sendRedirect(allocator, stream, "/settings/labels");
        return;
    }

    if (std.mem.eql(u8, action, "reorder")) {
        const order_owned = (try formValueOwned(allocator, form_body, "order")) orelse try allocator.dupe(u8, "");
        defer allocator.free(order_owned);
        reorderLabels(allocator, repo, order_owned) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not reorder labels\n");
            return;
        };
        try sendRedirect(allocator, stream, "/settings/labels");
        return;
    }

    if (label.len == 0) {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Label is required\n");
        return;
    }

    if (std.mem.eql(u8, action, "update") or std.mem.eql(u8, action, "rename")) {
        const new_label_owned = (try formValueOwned(allocator, form_body, "new_label")) orelse try allocator.dupe(u8, "");
        defer allocator.free(new_label_owned);
        const new_label = std.mem.trim(u8, new_label_owned, " \t\r\n");
        if (new_label.len == 0) {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "New label name is required\n");
            return;
        }

        const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
        defer allocator.free(description_owned);
        const description = std.mem.trim(u8, description_owned, " \t\r\n");

        const color_owned = (try formValueOwned(allocator, form_body, "color")) orelse try allocator.dupe(u8, "");
        defer allocator.free(color_owned);
        const color = normalizeLabelColorOwned(allocator, color_owned, new_label) catch {
            try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Color must be a hex value like #0075ca\n");
            return;
        };
        defer allocator.free(color);

        var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
        defer db.deinit();
        var definition = try loadLabelDefinitionByName(allocator, &db, label);
        defer if (definition) |*value| value.deinit(allocator);

        if (!std.mem.eql(u8, label, new_label) and try labelNameExists(&db, new_label)) {
            try sendPlainResponse(allocator, stream, 409, "Conflict", "Label already exists\n");
            return;
        }

        if (definition) |existing| {
            var update = event_mod.LabelUpdate{};
            if (!std.mem.eql(u8, label, new_label)) update.name = new_label;
            if (!std.mem.eql(u8, existing.description, description)) update.description = description;
            if (!std.mem.eql(u8, existing.color, color)) update.color = color;
            if (update.hasChanges()) {
                writeLabelUpdatedEvent(allocator, existing.id, update) catch {
                    try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update label\n");
                    return;
                };
            }
        } else {
            const position = try nextLabelPosition(&db);
            writeLabelCreatedEvent(allocator, new_label, description, color, position) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not update label\n");
                return;
            };
        }

        if (!std.mem.eql(u8, label, new_label)) {
            mutateLabelEverywhere(allocator, repo, label, new_label) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not rename label\n");
                return;
            };
        }
    } else if (std.mem.eql(u8, action, "delete")) {
        var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
        defer db.deinit();
        var definition = try loadLabelDefinitionByName(allocator, &db, label);
        defer if (definition) |*value| value.deinit(allocator);
        if (definition) |existing| {
            writeLabelDeletedEvent(allocator, existing.id) catch {
                try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not delete label\n");
                return;
            };
        }
        mutateLabelEverywhere(allocator, repo, label, null) catch {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Could not delete label\n");
            return;
        };
    } else {
        try sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown label action\n");
        return;
    }

    try sendRedirect(allocator, stream, "/settings/labels");
}

const LabelDefinition = struct {
    id: []u8,
    description: []u8,
    color: []u8,
    position: i64,

    fn deinit(self: *LabelDefinition, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        allocator.free(self.color);
    }
};

fn loadLabelDefinitionByName(allocator: Allocator, db: *SqliteDb, label: []const u8) !?LabelDefinition {
    var stmt = try db.prepare("SELECT id, description, color, position FROM label_definitions WHERE name = ?");
    defer stmt.deinit();
    try stmt.bindText(1, label);
    if (!(try stmt.step())) return null;
    return .{
        .id = try stmt.columnTextDup(allocator, 0),
        .description = try stmt.columnTextDup(allocator, 1),
        .color = try stmt.columnTextDup(allocator, 2),
        .position = stmt.columnInt64(3),
    };
}

fn labelNameExists(db: *SqliteDb, label: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM (
        \\  SELECT name AS label FROM label_definitions
        \\  UNION
        \\  SELECT label FROM issue_labels
        \\  UNION
        \\  SELECT label FROM pull_labels
        \\)
        \\WHERE label = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, label);
    return try stmt.step();
}

fn nextLabelPosition(db: *SqliteDb) !i64 {
    var stmt = try db.prepare("SELECT COALESCE(MAX(position), -1) + 1 FROM label_definitions");
    defer stmt.deinit();
    if (!(try stmt.step())) return 0;
    return stmt.columnInt64(0);
}

fn writeLabelCreatedEvent(allocator: Allocator, name: []const u8, description: []const u8, color: []const u8, position: i64) !void {
    var writer = try EventWriter.init(allocator, "gt label create");
    defer writer.deinit();

    const label_id = try newUuidV7(allocator);
    defer allocator.free(label_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildLabelCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        label_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        name,
        description,
        color,
        position,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "label.created @{s} {s}", .{ label_id[0..@min(label_id.len, 7)], name });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt label", subject, event_body);
    defer allocator.free(commit_oid);
}

fn writeLabelUpdatedEvent(allocator: Allocator, label_id: []const u8, update: event_mod.LabelUpdate) !void {
    if (!update.hasChanges()) return;

    var writer = try EventWriter.init(allocator, "gt label edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildLabelUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        label_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        update,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "label.updated @{s}", .{label_id[0..@min(label_id.len, 7)]});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt label", subject, event_body);
    defer allocator.free(commit_oid);
}

fn reorderLabels(allocator: Allocator, repo: Repo, order_body: []const u8) !void {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    var position: i64 = 0;
    var lines = std.mem.splitScalar(u8, order_body, '\n');
    while (lines.next()) |raw_label| {
        const label = std.mem.trim(u8, raw_label, " \t\r\n");
        if (label.len == 0) continue;
        if (!(try rememberLabelForReorder(allocator, &seen, label))) continue;
        try reorderSingleLabel(allocator, &db, label, position);
        position += 1;
    }
}

fn rememberLabelForReorder(allocator: Allocator, seen: *std.StringHashMap(void), label: []const u8) !bool {
    if (seen.contains(label)) return false;
    const key = try allocator.dupe(u8, label);
    errdefer allocator.free(key);
    const entry = try seen.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
        return false;
    }
    entry.value_ptr.* = {};
    return true;
}

fn reorderSingleLabel(allocator: Allocator, db: *SqliteDb, label: []const u8, position: i64) !void {
    var definition = try loadLabelDefinitionByName(allocator, db, label);
    defer if (definition) |*value| value.deinit(allocator);

    if (definition) |existing| {
        if (existing.position == position) return;
        try writeLabelUpdatedEvent(allocator, existing.id, .{ .position = position });
        return;
    }

    const color = defaultLabelColor(label);
    try writeLabelCreatedEvent(allocator, label, "", color, position);
}

fn writeLabelDeletedEvent(allocator: Allocator, label_id: []const u8) !void {
    var writer = try EventWriter.init(allocator, "gt label delete");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildLabelDeletedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        label_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "label.deleted @{s}", .{label_id[0..@min(label_id.len, 7)]});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt label", subject, event_body);
    defer allocator.free(commit_oid);
}

fn mutateLabelEverywhere(allocator: Allocator, repo: Repo, label: []const u8, new_label: ?[]const u8) !void {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var issue_ids = try loadIdsForLabel(allocator, &db, "SELECT DISTINCT issue_id FROM issue_labels WHERE label = ? ORDER BY issue_id", label);
    defer deinitIdList(allocator, &issue_ids);
    var pull_ids = try loadIdsForLabel(allocator, &db, "SELECT DISTINCT pull_id FROM pull_labels WHERE label = ? ORDER BY pull_id", label);
    defer deinitIdList(allocator, &pull_ids);

    for (issue_ids.items) |issue_id| {
        try mutateIssueLabel(allocator, issue_id, label, new_label);
    }
    for (pull_ids.items) |pull_id| {
        try mutatePullLabel(allocator, pull_id, label, new_label);
    }
}

fn loadIdsForLabel(allocator: Allocator, db: *SqliteDb, comptime sql_text: []const u8, label: []const u8) !std.ArrayList([]u8) {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer deinitIdList(allocator, &ids);

    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, label);
    while (try stmt.step()) {
        try ids.append(allocator, try stmt.columnTextDup(allocator, 0));
    }
    return ids;
}

fn deinitIdList(allocator: Allocator, ids: *std.ArrayList([]u8)) void {
    for (ids.items) |id| allocator.free(id);
    ids.deinit(allocator);
}

fn mutateIssueLabel(allocator: Allocator, issue_id: []const u8, label: []const u8, new_label: ?[]const u8) !void {
    const removed = [_][]const u8{label};
    if (new_label) |value| {
        const added = [_][]const u8{value};
        try issue_mod.createIssueUpdatedEvent(allocator, issue_id, .{
            .labels_added = added[0..],
            .labels_removed = removed[0..],
        });
        return;
    }
    try issue_mod.createIssueUpdatedEvent(allocator, issue_id, .{
        .labels_removed = removed[0..],
    });
}

fn mutatePullLabel(allocator: Allocator, pull_id: []const u8, label: []const u8, new_label: ?[]const u8) !void {
    const removed = [_][]const u8{label};
    if (new_label) |value| {
        const added = [_][]const u8{value};
        try pull_mod.createPullUpdatedEvent(allocator, pull_id, .{
            .labels_added = added[0..],
            .labels_removed = removed[0..],
        });
        return;
    }
    try pull_mod.createPullUpdatedEvent(allocator, pull_id, .{
        .labels_removed = removed[0..],
    });
}

fn normalizeLabelColorOwned(allocator: Allocator, raw_color: []const u8, label: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_color, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, defaultLabelColor(label));
    if (!validHexColor(trimmed)) return error.InvalidLabelColor;
    const color = try allocator.dupe(u8, trimmed);
    for (color) |*c| c.* = std.ascii.toLower(c.*);
    return color;
}

fn validHexColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn countLabels(db: *SqliteDb) !usize {
    var stmt = try db.prepare(
        \\SELECT COUNT(*)
        \\FROM (
        \\  SELECT name AS label FROM label_definitions
        \\  UNION
        \\  SELECT label FROM issue_labels
        \\  UNION
        \\  SELECT label FROM pull_labels
        \\)
    );
    defer stmt.deinit();
    if (!(try stmt.step())) return 0;
    return @as(usize, @intCast(stmt.columnInt64(0)));
}

fn appendLabelsHeader(buf: *std.ArrayList(u8), allocator: Allocator, csrf_token: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="labels-page" data-labels-page data-label-csrf-field="{csrf_field}" data-label-csrf="{csrf}">
        \\  <header class="labels-page-head">
        \\    <h1>Labels</h1>
        \\    <button class="button primary labels-new-button" type="button" data-label-new-toggle>New label</button>
        \\  </header>
    , .{ .csrf_field = zwf.csrf.field_name, .csrf = csrf_token });
}

fn appendLabelDialog(buf: *std.ArrayList(u8), allocator: Allocator, csrf_token: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\  <div class="labels-dialog-backdrop" data-label-dialog hidden>
        \\    <div class="labels-dialog" role="dialog" aria-modal="true" aria-labelledby="label-dialog-title">
        \\      <form method="post" action="/settings/labels" data-label-dialog-form>
        \\        <header class="labels-dialog-head">
        \\          <h2 id="label-dialog-title" data-label-dialog-title>New label</h2>
        \\          <button class="labels-dialog-close" type="button" aria-label="Close" data-label-dialog-close>x</button>
        \\        </header>
        \\        <div class="labels-dialog-body">
        \\          <div class="labels-dialog-preview"><span class="issue-label label-custom" style="--label-color: #0075ca" data-label-dialog-preview>label</span></div>
        \\          <input type="hidden" name="{csrf_field}" value="{csrf}">
        \\          <input type="hidden" name="action" value="create" data-label-dialog-action>
        \\          <input type="hidden" name="label" value="" data-label-dialog-original>
        \\          <label class="labels-dialog-field">Name<input class="labels-dialog-input" type="text" name="new_label" required data-label-dialog-name></label>
        \\          <label class="labels-dialog-field">Description<textarea class="labels-dialog-textarea" name="description" rows="4" data-label-dialog-description></textarea></label>
        \\          <label class="labels-dialog-field">Color<span class="labels-color-control"><button class="button secondary labels-color-random" type="button" aria-label="Choose another color" title="Choose another color" data-label-color-random><span class="button-icon icon-sync" aria-hidden="true"></span></button><input class="labels-dialog-input" type="text" name="color" value="#0075ca" pattern="#[0-9a-fA-F]{{6}}" data-label-dialog-color></span></label>
        \\        </div>
        \\        <footer class="labels-dialog-actions">
        \\          <button class="button secondary" type="button" data-label-dialog-cancel>Cancel</button>
        \\          <button class="button primary" type="submit" data-label-dialog-submit>Create label</button>
        \\        </footer>
        \\      </form>
        \\    </div>
        \\  </div>
    , .{ .csrf_field = zwf.csrf.field_name, .csrf = csrf_token });
}

fn appendLabelsToolbar(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\  <div class="labels-toolbar">
        \\    <label class="labels-search"><span class="button-icon icon-search" aria-hidden="true"></span><input type="search" placeholder="Search all labels" aria-label="Search all labels" data-label-search></label>
        \\    <details class="issues-filter-menu labels-sort-menu" data-popover-menu>
        \\      <summary>Sort: <span data-label-sort-label>Custom order</span></summary>
        \\      <div class="issues-filter-popover labels-sort-popover" role="menu">
        \\        <button class="issues-filter-option selected" type="button" role="menuitem" data-label-sort="manual"><span>Custom order</span></button>
        \\        <button class="issues-filter-option" type="button" role="menuitem" data-label-sort="name"><span>Name</span></button>
        \\        <button class="issues-filter-option" type="button" role="menuitem" data-label-sort="usage"><span>Most used</span></button>
        \\      </div>
        \\    </details>
        \\  </div>
    );
}

fn appendLabelsListStart(buf: *std.ArrayList(u8), allocator: Allocator, label_count: usize) !void {
    try appendTemplate(buf, allocator,
        \\  <section class="panel labels-panel">
        \\    <header class="labels-list-head">
        \\      <strong><span data-label-visible-count>{label_count}</span> <span data-label-count-word>{label_word}</span></strong>
        \\    </header>
        \\    <div class="labels-list" data-label-list>
    , .{
        .label_count = groupedUnsigned(@intCast(label_count)),
        .label_word = if (label_count == 1) "label" else "labels",
    });
}

fn appendLabelRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    label_id: []const u8,
    description: []const u8,
    color: []const u8,
    issue_count: usize,
    pull_count: usize,
    order: usize,
    csrf_token: []const u8,
) !void {
    const total_count = issue_count + pull_count;
    const summary = try labelUsageSummaryOwned(allocator, issue_count, pull_count);
    defer allocator.free(summary);
    const effective_description = if (description.len == 0) summary else description;
    const effective_color = if (validHexColor(color)) color else defaultLabelColor(label);
    try buf.appendSlice(allocator, "<article class=\"labels-list-row\"");
    if (label_id.len != 0) {
        try buf.appendSlice(allocator, " id=\"label-");
        try shared.appendHtml(buf, allocator, label_id);
        try buf.append(allocator, '"');
    }
    try appendTemplate(buf, allocator,
        \\ data-label-row data-label-name="{label}" data-label-id="{label_id}" data-label-description="{description}" data-label-color="{color}" data-label-total="{total_count}" data-label-order="{order}" data-label-search-text="{label} {description} {summary}">
        \\  <button class="labels-drag-handle" type="button" draggable="true" aria-label="Reorder {label}" title="Reorder label" data-label-drag-handle></button>
        \\  <div class="labels-row-main">
    , .{
        .label = label,
        .label_id = label_id,
        .description = description,
        .color = effective_color,
        .total_count = total_count,
        .order = order,
        .summary = summary,
    });
    try appendLabelChip(buf, allocator, label, effective_color);
    try appendTemplate(buf, allocator,
        \\    <p>{description}</p>
        \\  </div>
        \\  <div class="labels-row-links">
    , .{ .description = effective_description });
    try appendIssueLink(buf, allocator, label, issue_count);
    try appendPullLink(buf, allocator, label, pull_count);
    try buf.appendSlice(allocator, "  </div>");
    try appendLabelActionMenu(buf, allocator, label, csrf_token);
    try buf.appendSlice(allocator, "</article>");
}

fn labelUsageSummaryOwned(allocator: Allocator, issue_count: usize, pull_count: usize) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Used by {d} open {s} and {d} open {s}",
        .{
            issue_count,
            if (issue_count == 1) "issue" else "issues",
            pull_count,
            if (pull_count == 1) "pull request" else "pull requests",
        },
    );
}

fn appendIssueLink(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, issue_count: usize) !void {
    if (issue_count == 0) {
        try buf.appendSlice(allocator, "<span>0 open issues</span>");
        return;
    }

    try buf.appendSlice(allocator, "<a href=\"/issues?state=open&amp;label=");
    try appendUrlEncoded(buf, allocator, label);
    try appendTemplate(buf, allocator,
        \\">{issue_count} open {issue_label}</a>
    , .{
        .issue_count = groupedUnsigned(@intCast(issue_count)),
        .issue_label = if (issue_count == 1) "issue" else "issues",
    });
}

fn appendPullLink(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, pull_count: usize) !void {
    if (pull_count == 0) {
        try buf.appendSlice(allocator, "<span>0 open pull requests</span>");
        return;
    }

    try buf.appendSlice(allocator, "<a href=\"/pulls?state=open&amp;label=");
    try appendUrlEncoded(buf, allocator, label);
    try appendTemplate(buf, allocator,
        \\">{pull_count} open {pull_label}</a>
    , .{
        .pull_count = groupedUnsigned(@intCast(pull_count)),
        .pull_label = if (pull_count == 1) "pull request" else "pull requests",
    });
}

fn appendLabelActionMenu(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, csrf_token: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<details class="issue-action-menu labels-row-menu" data-popover-menu>
        \\  <summary class="issue-kebab-button" aria-label="Label actions" title="Label actions"></summary>
        \\  <div class="issue-action-popover labels-row-popover" role="menu">
        \\    <button type="button" role="menuitem" data-label-edit-toggle>Edit label</button>
        \\    <form method="post" action="/settings/labels"><input type="hidden" name="{csrf_field}" value="{csrf}"><input type="hidden" name="action" value="delete"><input type="hidden" name="label" value="{label}"><button type="submit" role="menuitem">Delete label</button></form>
        \\  </div>
        \\</details>
    , .{ .csrf_field = zwf.csrf.field_name, .csrf = csrf_token, .label = label });
}

fn appendLabelChip(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, color: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label label-custom" style="--label-color: {color}">{label}</span>
    , .{
        .color = color,
        .label = label,
    });
}

const default_label_colors = [_][]const u8{
    "#0075ca",
    "#d73a4a",
    "#a2eeef",
    "#7057ff",
    "#008672",
    "#e4e669",
    "#d876e3",
    "#b60205",
    "#0e8a16",
    "#fbca04",
    "#5319e7",
    "#cfd3d7",
};

fn defaultLabelColor(label: []const u8) []const u8 {
    const index_value: usize = @intCast(std.hash.Wyhash.hash(0, label) % default_label_colors.len);
    return default_label_colors[index_value];
}

fn labelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

fn labelColorClass(label: []const u8) []const u8 {
    return switch (std.hash.Wyhash.hash(0, label) % 12) {
        0 => "label-color-0",
        1 => "label-color-1",
        2 => "label-color-2",
        3 => "label-color-3",
        4 => "label-color-4",
        5 => "label-color-5",
        6 => "label-color-6",
        7 => "label-color-7",
        8 => "label-color-8",
        9 => "label-color-9",
        10 => "label-color-10",
        else => "label-color-11",
    };
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

test "label dialog form includes csrf token" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendLabelDialog(&buf, std.testing.allocator, "token-123");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"_csrf\" value=\"token-123\"") != null);
}

test "label delete form includes csrf token" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendLabelActionMenu(&buf, std.testing.allocator, "bug", "token-123");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"_csrf\" value=\"token-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"label\" value=\"bug\"") != null);
}

test "labels page usage counts only open issues and pulls" {
    const allocator = std.testing.allocator;
    var db = try SqliteDb.openWithOptions(allocator, ":memory:", sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, true, .{ .enable_wal = false });
    defer db.deinit();

    try db.exec(
        \\CREATE TABLE label_definitions(id TEXT, name TEXT, description TEXT, color TEXT, position INTEGER);
        \\CREATE TABLE issues(id TEXT PRIMARY KEY, state TEXT NOT NULL);
        \\CREATE TABLE issue_labels(issue_id TEXT NOT NULL, label TEXT NOT NULL);
        \\CREATE TABLE pulls(id TEXT PRIMARY KEY, state TEXT NOT NULL);
        \\CREATE TABLE pull_labels(pull_id TEXT NOT NULL, label TEXT NOT NULL);
        \\INSERT INTO label_definitions(id, name, description, color, position) VALUES ('label-1', 'bug', '', '#ff0000', 0);
        \\INSERT INTO label_definitions(id, name, description, color, position) VALUES ('label-2', 'history', '', '#00ff00', 1);
        \\INSERT INTO issues(id, state) VALUES ('issue-open', 'open');
        \\INSERT INTO issues(id, state) VALUES ('issue-closed', 'closed');
        \\INSERT INTO issue_labels(issue_id, label) VALUES ('issue-open', 'bug');
        \\INSERT INTO issue_labels(issue_id, label) VALUES ('issue-closed', 'bug');
        \\INSERT INTO issue_labels(issue_id, label) VALUES ('issue-closed', 'history');
        \\INSERT INTO pulls(id, state) VALUES ('pull-open', 'open');
        \\INSERT INTO pulls(id, state) VALUES ('pull-merged', 'merged');
        \\INSERT INTO pulls(id, state) VALUES ('pull-closed', 'closed');
        \\INSERT INTO pull_labels(pull_id, label) VALUES ('pull-open', 'bug');
        \\INSERT INTO pull_labels(pull_id, label) VALUES ('pull-merged', 'bug');
        \\INSERT INTO pull_labels(pull_id, label) VALUES ('pull-closed', 'bug');
        \\INSERT INTO pull_labels(pull_id, label) VALUES ('pull-merged', 'history');
    );

    var stmt = try db.prepare(label_rows_sql);
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
    const bug_label = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(bug_label);
    try std.testing.expectEqualStrings("bug", bug_label);
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(4));
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(5));

    try std.testing.expect(try stmt.step());
    const history_label = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(history_label);
    try std.testing.expectEqualStrings("history", history_label);
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt64(4));
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt64(5));
}

test "label pull link targets open pull label filter" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendPullLink(&buf, std.testing.allocator, "needs review", 2);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "/pulls?state=open&amp;label=needs%20review") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "2 open pull requests") != null);
}
