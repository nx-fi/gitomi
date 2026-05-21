const std = @import("std");
const event_validation = @import("../event/validation.zig");
const index = @import("../index.zig");
const notification_mod = @import("../notification.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const createNotificationSubscriptionEvent = notification_mod.createNotificationSubscriptionEvent;
const createNotificationReadAllEvent = notification_mod.createNotificationReadAllEvent;
const createNotificationReadEvent = notification_mod.createNotificationReadEvent;

const default_limit = 50;
const max_limit = 200;

const InboxRow = struct {
    event_hash: []u8,
    object_kind: []u8,
    object_id: []u8,
    event_type: []u8,
    actor_principal: []u8,
    occurred_at: []u8,
    reason: []u8,
    read_at: []u8,
    title: []u8,

    fn deinit(self: *InboxRow, allocator: Allocator) void {
        allocator.free(self.event_hash);
        allocator.free(self.object_kind);
        allocator.free(self.object_id);
        allocator.free(self.event_type);
        allocator.free(self.actor_principal);
        allocator.free(self.occurred_at);
        allocator.free(self.reason);
        allocator.free(self.read_at);
        allocator.free(self.title);
    }
};

pub fn currentActorCanManageNotifications(current_actor: ?[]const u8, current_role: ?[]const u8) bool {
    if (current_actor == null) return false;
    const role = current_role orelse return false;
    return event_validation.roleAtLeast(role, "reporter");
}

pub fn isNotificationSubscribed(db: *SqliteDb, principal: []const u8, object_kind: []const u8, object_id: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT active
        \\FROM notification_subscriptions
        \\WHERE principal = ?
        \\  AND object_kind = ?
        \\  AND object_id = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);
    if (!(try stmt.step())) return false;
    return stmt.columnInt(0) != 0;
}

pub fn handleNotificationPost(
    comptime object_kind: []const u8,
    comptime resolveObjectId: anytype,
    comptime redirect_prefix: []const u8,
    allocator: Allocator,
    repo: Repo,
    stream: @import("compat").net.Stream,
    raw_ref: []const u8,
    form_body: []const u8,
) !void {
    try index.ensureIndex(allocator, repo);
    const object_id = resolveObjectId(allocator, repo, raw_ref) catch {
        try shared.sendPlainResponse(allocator, stream, 404, "Not Found", notFoundMessage(object_kind));
        return;
    };
    defer allocator.free(object_id);

    const action_owned = (try shared.formValueOwned(allocator, form_body, "action")) orelse {
        try shared.sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Missing notification action\n");
        return;
    };
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    const subscribe = if (std.mem.eql(u8, action, "subscribe"))
        true
    else if (std.mem.eql(u8, action, "unsubscribe"))
        false
    else {
        try shared.sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", "Unknown notification action\n");
        return;
    };

    const current_actor = try shared.currentPrincipalOwned(allocator, repo);
    defer if (current_actor) |actor_value| allocator.free(actor_value);
    const actor = current_actor orelse {
        try shared.sendPlainResponse(allocator, stream, 409, "Conflict", "Gitomi is not initialized\n");
        return;
    };
    const current_role = try index.effectiveWriteRoleForPrincipal(allocator, repo, actor);
    defer if (current_role) |role| allocator.free(role);
    if (!currentActorCanManageNotifications(actor, current_role)) {
        try shared.sendPlainResponse(allocator, stream, 403, "Forbidden", "Forbidden\n");
        return;
    }

    createNotificationSubscriptionEvent(allocator, actor, object_kind, object_id, subscribe) catch |err| {
        try shared.sendPlainResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not update notification subscription\n"));
        return;
    };

    const location = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ redirect_prefix, raw_ref });
    defer allocator.free(location);
    try shared.sendRedirect(allocator, stream, location);
}

pub fn handleInboxReadPost(
    allocator: Allocator,
    repo: Repo,
    stream: @import("compat").net.Stream,
    form_body: []const u8,
    redirect_target: []const u8,
) !void {
    const principal = (try shared.currentPrincipalOwned(allocator, repo)) orelse {
        try shared.sendPlainResponse(allocator, stream, 409, "Conflict", "Gitomi is not initialized\n");
        return;
    };
    defer allocator.free(principal);

    const action_owned = (try shared.formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");

    if (std.mem.eql(u8, action, "read-all")) {
        createNotificationReadAllEvent(allocator, principal) catch |err| {
            try sendNotificationWriteFailure(allocator, stream, err);
            return;
        };
    } else {
        const event_hash = (try shared.formValueOwned(allocator, form_body, "event_hash")) orelse {
            try shared.sendPlainResponse(allocator, stream, 400, "Bad Request", "Missing event_hash\n");
            return;
        };
        defer allocator.free(event_hash);
        createNotificationReadEvent(allocator, principal, event_hash) catch |err| {
            try sendNotificationWriteFailure(allocator, stream, err);
            return;
        };
    }

    try shared.sendRedirect(allocator, stream, redirect_target);
}

fn sendNotificationWriteFailure(allocator: Allocator, stream: @import("compat").net.Stream, err: anyerror) !void {
    try shared.sendPlainResponse(
        allocator,
        stream,
        shared.writeFailureStatus(err),
        shared.writeFailureReason(err),
        shared.writeFailureMessage(err, "Could not update notification read state\n"),
    );
}

fn notFoundMessage(comptime object_kind: []const u8) []const u8 {
    if (std.mem.eql(u8, object_kind, "pull")) return "Pull request not found\n";
    return "Issue not found\n";
}

pub fn renderInboxPage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Inbox", "inbox", target)) |body| return body;
    try index.ensureIndex(allocator, repo);

    const principal = (try shared.currentPrincipalOwned(allocator, repo)) orelse try allocator.dupe(u8, "");
    defer allocator.free(principal);
    const show_all = try queryFlag(allocator, target, "all");
    const limit = try inboxLimitFromTarget(allocator, target);

    var db = try SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const unread_count = try countUnread(&db, principal);
    const rows = try loadRows(allocator, &db, principal, !show_all, limit);
    defer freeRows(allocator, rows);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try shared.appendShellStart(&buf, allocator, repo, "Inbox", "inbox");
    try buf.appendSlice(allocator, "<section class=\"inbox-page\">");
    try appendHeader(&buf, allocator, unread_count, show_all, csrf_token);
    try buf.appendSlice(allocator, "<div class=\"inbox-list\">");
    if (rows.len == 0) {
        try shared.appendEmptyState(&buf, allocator, if (show_all) "No notifications yet" else "No unread notifications", "Issue and pull request events from your subscriptions will appear here.");
    } else {
        for (rows) |row| try appendRow(&buf, allocator, row, csrf_token);
    }
    try buf.appendSlice(allocator, "</div></section>");
    try shared.appendShellEnd(&buf, allocator);
    return try buf.toOwnedSlice(allocator);
}

fn appendHeader(buf: *std.ArrayList(u8), allocator: Allocator, unread_count: usize, show_all: bool, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<div class="inbox-head">
        \\  <div>
        \\    <p class="eyebrow">Notifications</p>
        \\    <h1>Inbox</h1>
        \\  </div>
        \\  <div class="inbox-head-actions">
    );
    if (show_all) {
        try buf.appendSlice(allocator, "<a class=\"button secondary\" href=\"/inbox\">Unread</a>");
    } else {
        try buf.appendSlice(allocator, "<a class=\"button secondary\" href=\"/inbox?all=1\">All</a>");
    }
    if (unread_count != 0) {
        try shared.appendTemplate(buf, allocator,
            \\<form method="post" action="/inbox/read">
            \\  <input type="hidden" name="_csrf" value="{csrf_token}">
            \\  <input type="hidden" name="action" value="read-all">
            \\  <button class="button primary" type="submit">Mark all read</button>
            \\</form>
        , .{ .csrf_token = csrf_token });
    }
    try buf.appendSlice(allocator, "</div></div>");
}

fn appendRow(buf: *std.ArrayList(u8), allocator: Allocator, row: InboxRow, csrf_token: []const u8) !void {
    const href = if (std.mem.eql(u8, row.object_kind, "pull"))
        shared.pullHref(row.object_id)
    else
        shared.issueHref(row.object_id);
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, row.object_id);
    try shared.appendTemplate(buf, allocator,
        \\<article class="inbox-row {read_class}">
        \\  <a class="inbox-row-main" href="{href}">
        \\    <span class="inbox-row-kind">{object_kind} #{object_ref}</span>
        \\    <strong>{title}</strong>
        \\    <span class="inbox-row-meta">{event_type} by {actor}</span>
        \\  </a>
        \\  <div class="inbox-row-side">
    , .{
        .read_class = if (row.read_at.len == 0) "unread" else "read",
        .href = href,
        .object_kind = row.object_kind,
        .object_ref = object_ref,
        .title = if (row.title.len == 0) row.event_type else row.title,
        .event_type = row.event_type,
        .actor = row.actor_principal,
    });
    try shared.appendRelativeTime(buf, allocator, row.occurred_at);
    if (row.read_at.len == 0) {
        try shared.appendTemplate(buf, allocator,
            \\    <form method="post" action="/inbox/read">
            \\      <input type="hidden" name="_csrf" value="{csrf_token}">
            \\      <input type="hidden" name="event_hash" value="{event_hash}">
            \\      <button class="button secondary compact" type="submit">Mark read</button>
            \\    </form>
        , .{ .csrf_token = csrf_token, .event_hash = row.event_hash });
    }
    try buf.appendSlice(allocator, "</div></article>");
}

fn loadRows(allocator: Allocator, db: *SqliteDb, principal: []const u8, unread_only: bool, limit: usize) ![]InboxRow {
    const sql =
        \\SELECT n.event_hash, n.object_kind, n.object_id, n.event_type, n.actor_principal,
        \\       n.occurred_at, n.reason, n.read_at, COALESCE(i.title, p.title, '')
        \\FROM notification_inbox n
        \\LEFT JOIN issues i ON n.object_kind = 'issue' AND i.id = n.object_id
        \\LEFT JOIN pulls p ON n.object_kind = 'pull' AND p.id = n.object_id
        \\WHERE n.principal = ?
        \\
    ;
    const suffix = if (unread_only)
        "  AND n.read_at = ''\nORDER BY n.occurred_at DESC, n.event_hash DESC\nLIMIT ?"
    else
        "ORDER BY n.occurred_at DESC, n.event_hash DESC\nLIMIT ?";
    const full_sql = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sql, suffix });
    defer allocator.free(full_sql);
    var stmt = try db.prepare(full_sql);
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindInt64(2, @intCast(limit));

    var rows: std.ArrayList(InboxRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    while (try stmt.step()) {
        try rows.append(allocator, .{
            .event_hash = try stmt.columnTextDup(allocator, 0),
            .object_kind = try stmt.columnTextDup(allocator, 1),
            .object_id = try stmt.columnTextDup(allocator, 2),
            .event_type = try stmt.columnTextDup(allocator, 3),
            .actor_principal = try stmt.columnTextDup(allocator, 4),
            .occurred_at = try stmt.columnTextDup(allocator, 5),
            .reason = try stmt.columnTextDup(allocator, 6),
            .read_at = try stmt.columnTextDup(allocator, 7),
            .title = try stmt.columnTextDup(allocator, 8),
        });
    }
    return try rows.toOwnedSlice(allocator);
}

fn freeRows(allocator: Allocator, rows: []InboxRow) void {
    for (rows) |*row| row.deinit(allocator);
    allocator.free(rows);
}

fn countUnread(db: *SqliteDb, principal: []const u8) !usize {
    var stmt = try db.prepare(
        \\SELECT COUNT(*)
        \\FROM notification_inbox
        \\WHERE principal = ?
        \\  AND read_at = ''
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    if (!(try stmt.step())) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

fn inboxLimitFromTarget(allocator: Allocator, target: []const u8) !usize {
    const raw = try shared.queryValueOwned(allocator, target, "limit") orelse return default_limit;
    defer allocator.free(raw);
    const parsed = std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return default_limit;
    if (parsed == 0) return default_limit;
    return @min(parsed, max_limit);
}

fn queryFlag(allocator: Allocator, target: []const u8, key: []const u8) !bool {
    const value = try shared.queryValueOwned(allocator, target, key) orelse return false;
    defer allocator.free(value);
    return value.len == 0 or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}
