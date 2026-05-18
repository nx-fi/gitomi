const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const errors = @import("errors.zig");
const event_builders = @import("event/builders.zig");
const event_writer_mod = @import("event_writer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const SqliteDb = index.SqliteDb;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonString = json_writer.appendJsonString;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;

pub const InboxOptions = struct {
    principal: []const u8,
    unread_only: bool = true,
    json: bool = false,
    limit: usize = 20,
};

const NotificationRow = struct {
    event_hash: []u8,
    object_kind: []u8,
    object_id: []u8,
    event_type: []u8,
    actor_principal: []u8,
    occurred_at: []u8,
    reason: []u8,
    read_at: []u8,
    title: []u8,

    fn deinit(self: *NotificationRow, allocator: Allocator) void {
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

pub fn cmdNotification(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "inbox")) {
        try cmdInbox(allocator, if (args.len == 0) args else args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "subscribe") or std.mem.eql(u8, args[0], "unsubscribe")) {
        try cmdSubscriptionMutation(allocator, args, std.mem.eql(u8, args[0], "subscribe"));
        return;
    }

    if (std.mem.eql(u8, args[0], "subscriptions")) {
        try cmdSubscriptions(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "read")) {
        try cmdRead(allocator, args[1..]);
        return;
    }

    try io.eprint("gt notification: expected inbox, subscribe, unsubscribe, subscriptions, or read\n", .{});
    return CliError.UserError;
}

pub fn cmdInbox(allocator: Allocator, args: []const []const u8) !void {
    var command_repo = cmd_common.CommandRepo.init(allocator);
    defer command_repo.deinit();

    const repo = try command_repo.indexedRepo();
    const default_principal = try currentPrincipalOwned(allocator, repo);
    defer allocator.free(default_principal);

    var principal: []const u8 = default_principal;
    var unread_only = true;
    var json = false;
    var limit: usize = 20;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            unread_only = false;
        } else if (std.mem.eql(u8, arg, "--unread")) {
            unread_only = true;
        } else if (std.mem.eql(u8, arg, "--principal")) {
            principal = try util.requireValue(args, &i, "--principal");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            limit = try cmd_common.parsePositiveIntegerOption("gt notification inbox", "--limit", try util.requireValue(args, &i, "--limit"));
        } else {
            try io.eprint("gt notification inbox: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    try printInbox(allocator, repo, .{
        .principal = principal,
        .unread_only = unread_only,
        .json = json,
        .limit = limit,
    });
}

fn cmdSubscriptionMutation(allocator: Allocator, args: []const []const u8, subscribe: bool) !void {
    const context = if (subscribe) "gt notification subscribe" else "gt notification unsubscribe";
    if (args.len < 3) {
        try io.eprint("{s}: expected issue|pr OBJECT [--principal PRINCIPAL]\n", .{context});
        return CliError.UserError;
    }

    const target_kind = canonicalTargetKind(args[1]) orelse {
        try io.eprint("{s}: target kind must be issue or pr\n", .{context});
        return CliError.UserError;
    };

    var principal: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--principal")) {
            principal = try util.requireValue(args, &i, "--principal");
        } else {
            try io.eprint("{s}: unknown option '{s}'\n", .{ context, args[i] });
            return CliError.UserError;
        }
    }

    var command_repo = cmd_common.CommandRepo.init(allocator);
    defer command_repo.deinit();
    const target_id = if (std.mem.eql(u8, target_kind, "issue"))
        try command_repo.resolveIssueId(args[2])
    else
        try command_repo.resolvePullId(args[2]);
    defer allocator.free(target_id);

    try createNotificationSubscriptionEvent(allocator, principal, target_kind, target_id, subscribe);
}

fn cmdSubscriptions(allocator: Allocator, args: []const []const u8) !void {
    var command_repo = cmd_common.CommandRepo.init(allocator);
    defer command_repo.deinit();
    const repo = try command_repo.indexedRepo();
    const default_principal = try currentPrincipalOwned(allocator, repo);
    defer allocator.free(default_principal);

    var principal: []const u8 = default_principal;
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--principal")) {
            principal = try util.requireValue(args, &i, "--principal");
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json = true;
        } else {
            try io.eprint("gt notification subscriptions: unknown option '{s}'\n", .{args[i]});
            return CliError.UserError;
        }
    }

    try printSubscriptions(allocator, repo, principal, json);
}

fn cmdRead(allocator: Allocator, args: []const []const u8) !void {
    var command_repo = cmd_common.CommandRepo.init(allocator);
    defer command_repo.deinit();
    const repo = try command_repo.indexedRepo();
    const default_principal = try currentPrincipalOwned(allocator, repo);
    defer allocator.free(default_principal);

    var principal: []const u8 = default_principal;
    var read_all = false;
    var event_ref: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--principal")) {
            principal = try util.requireValue(args, &i, "--principal");
        } else if (std.mem.eql(u8, arg, "--all")) {
            read_all = true;
        } else if (event_ref == null) {
            event_ref = arg;
        } else {
            try io.eprint("gt notification read: unexpected argument '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (read_all) {
        if (event_ref != null) {
            try io.eprint("gt notification read: EVENT cannot be combined with --all\n", .{});
            return CliError.UserError;
        }
        try createNotificationReadAllEvent(allocator, principal);
        return;
    }

    const raw_ref = event_ref orelse {
        try io.eprint("gt notification read: expected EVENT or --all\n", .{});
        return CliError.UserError;
    };
    const event_hash = try resolveNotificationEventHash(allocator, repo, principal, raw_ref);
    defer allocator.free(event_hash);
    try createNotificationReadEvent(allocator, principal, event_hash);
}

pub fn createNotificationSubscriptionEvent(
    allocator: Allocator,
    principal: ?[]const u8,
    target_kind: []const u8,
    target_id: []const u8,
    subscribe: bool,
) !void {
    var writer = try EventWriter.init(allocator, if (subscribe) "gt notification subscribe" else "gt notification unsubscribe");
    defer writer.deinit();

    const target_principal = principal orelse writer.cfg.principal;
    const notification_id = try newUuidV7(allocator);
    defer allocator.free(notification_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_type: []const u8 = if (subscribe) "notification.subscribed" else "notification.unsubscribed";

    const event_body = try event_builders.buildNotificationSubscriptionJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        notification_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        event_type,
        target_principal,
        target_kind,
        target_id,
        "manual",
    );
    defer allocator.free(event_body);

    var target_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const target_ref = util.shortObjectRef(&target_ref_buf, target_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} {s} #{s} {s}", .{ event_type, target_kind, target_ref, target_principal });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt notification", subject, event_body);
    defer allocator.free(commit_oid);

    try io.out("{s} {s} #{s}\n", .{ event_type, target_kind, target_ref });
    try io.out("  principal: {s}\n", .{target_principal});
    try io.out("  commit:    {s}\n", .{commit_oid});
    try io.out("  ref:       {s}\n", .{writer.inbox_ref});
}

pub fn createNotificationReadEvent(allocator: Allocator, principal: []const u8, event_hash: []const u8) !void {
    try createNotificationReadInternal(allocator, principal, event_hash, false);
}

pub fn createNotificationReadAllEvent(allocator: Allocator, principal: []const u8) !void {
    try createNotificationReadInternal(allocator, principal, "", true);
}

fn createNotificationReadInternal(allocator: Allocator, principal: []const u8, event_hash: []const u8, all: bool) !void {
    var writer = try EventWriter.init(allocator, "gt notification read");
    defer writer.deinit();

    const notification_id = try newUuidV7(allocator);
    defer allocator.free(notification_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = if (all)
        try event_builders.buildNotificationReadAllJson(
            allocator,
            writer.cfg,
            writer.nextSeq(),
            notification_id,
            event_uuid,
            idem,
            occurred_at,
            writer.eventParents(),
            principal,
        )
    else
        try event_builders.buildNotificationReadJson(
            allocator,
            writer.cfg,
            writer.nextSeq(),
            notification_id,
            event_uuid,
            idem,
            occurred_at,
            writer.eventParents(),
            principal,
            event_hash,
        );
    defer allocator.free(event_body);

    const subject = if (all)
        try std.fmt.allocPrint(allocator, "notification.read_all {s}", .{principal})
    else
        try std.fmt.allocPrint(allocator, "notification.read {s}", .{event_hash[0..@min(event_hash.len, 12)]});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt notification", subject, event_body);
    defer allocator.free(commit_oid);

    try io.out("{s}\n", .{if (all) "notification.read_all" else "notification.read"});
    try io.out("  principal: {s}\n", .{principal});
    try io.out("  commit:    {s}\n", .{commit_oid});
    try io.out("  ref:       {s}\n", .{writer.inbox_ref});
}

pub fn printInbox(allocator: Allocator, repo: repo_mod.Repo, options: InboxOptions) !void {
    var db = try SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const rows = try loadInboxRows(allocator, &db, options.principal, options.unread_only, options.limit);
    defer freeRows(allocator, rows);

    if (options.json) {
        try printInboxJson(allocator, options, rows);
        return;
    }

    if (rows.len == 0) {
        try io.out("{s} notifications: none\n", .{if (options.unread_only) "unread" else "recent"});
        return;
    }
    for (rows) |row| {
        var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const object_ref = util.shortObjectRef(&object_ref_buf, row.object_id);
        try io.out("{s} {s} #{s} {s} by {s} {s}\n", .{
            row.event_hash[0..@min(row.event_hash.len, 12)],
            row.object_kind,
            object_ref,
            row.event_type,
            row.actor_principal,
            if (row.read_at.len == 0) "unread" else "read",
        });
        if (row.title.len != 0) try io.out("  {s}\n", .{row.title});
    }
}

fn loadInboxRows(allocator: Allocator, db: *SqliteDb, principal: []const u8, unread_only: bool, limit: usize) ![]NotificationRow {
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

    var rows: std.ArrayList(NotificationRow) = .empty;
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

fn freeRows(allocator: Allocator, rows: []NotificationRow) void {
    for (rows) |*row| row.deinit(allocator);
    allocator.free(rows);
}

fn printInboxJson(allocator: Allocator, options: InboxOptions, rows: []const NotificationRow) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "kind", "notification_inbox", true);
    try appendJsonFieldString(&buf, allocator, "principal", options.principal, true);
    try appendJsonFieldBool(&buf, allocator, "unread_only", options.unread_only, true);
    try appendJsonString(&buf, allocator, "notifications");
    try buf.appendSlice(allocator, ":[");
    for (rows, 0..) |row, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendNotificationRowJson(&buf, allocator, row);
    }
    try buf.appendSlice(allocator, "]}");
    try io.out("{s}\n", .{buf.items});
}

fn appendNotificationRowJson(buf: *std.ArrayList(u8), allocator: Allocator, row: NotificationRow) !void {
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "event_hash", row.event_hash, true);
    try appendJsonFieldString(buf, allocator, "object_kind", row.object_kind, true);
    try appendJsonFieldString(buf, allocator, "object_id", row.object_id, true);
    try appendJsonFieldString(buf, allocator, "event_type", row.event_type, true);
    try appendJsonFieldString(buf, allocator, "actor_principal", row.actor_principal, true);
    try appendJsonFieldString(buf, allocator, "occurred_at", row.occurred_at, true);
    try appendJsonFieldString(buf, allocator, "reason", row.reason, true);
    try appendJsonFieldBool(buf, allocator, "unread", row.read_at.len == 0, true);
    try appendJsonFieldString(buf, allocator, "read_at", row.read_at, true);
    try appendJsonFieldString(buf, allocator, "title", row.title, false);
    try buf.append(allocator, '}');
}

fn printSubscriptions(allocator: Allocator, repo: repo_mod.Repo, principal: []const u8, json: bool) !void {
    var db = try SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT s.object_kind, s.object_id, s.reason, s.updated_at, COALESCE(i.title, p.title, '')
        \\FROM notification_subscriptions s
        \\LEFT JOIN issues i ON s.object_kind = 'issue' AND i.id = s.object_id
        \\LEFT JOIN pulls p ON s.object_kind = 'pull' AND p.id = s.object_id
        \\WHERE s.principal = ?
        \\  AND s.active != 0
        \\ORDER BY s.updated_at DESC, s.object_id
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);

    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.append(allocator, '{');
        try appendJsonFieldString(&buf, allocator, "kind", "notification_subscriptions", true);
        try appendJsonFieldString(&buf, allocator, "principal", principal, true);
        try appendJsonString(&buf, allocator, "subscriptions");
        try buf.appendSlice(allocator, ":[");
        var first = true;
        while (try stmt.step()) {
            const object_kind = try stmt.columnTextDup(allocator, 0);
            defer allocator.free(object_kind);
            const object_id = try stmt.columnTextDup(allocator, 1);
            defer allocator.free(object_id);
            const reason = try stmt.columnTextDup(allocator, 2);
            defer allocator.free(reason);
            const updated_at = try stmt.columnTextDup(allocator, 3);
            defer allocator.free(updated_at);
            const title = try stmt.columnTextDup(allocator, 4);
            defer allocator.free(title);
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.append(allocator, '{');
            try appendJsonFieldString(&buf, allocator, "object_kind", object_kind, true);
            try appendJsonFieldString(&buf, allocator, "object_id", object_id, true);
            try appendJsonFieldString(&buf, allocator, "reason", reason, true);
            try appendJsonFieldString(&buf, allocator, "updated_at", updated_at, true);
            try appendJsonFieldString(&buf, allocator, "title", title, false);
            try buf.append(allocator, '}');
        }
        try buf.appendSlice(allocator, "]}");
        try io.out("{s}\n", .{buf.items});
        return;
    }

    var shown: usize = 0;
    while (try stmt.step()) {
        const object_kind = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(object_kind);
        const object_id = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(object_id);
        const reason = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(reason);
        const title = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(title);
        var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const object_ref = util.shortObjectRef(&object_ref_buf, object_id);
        try io.out("{s} #{s} {s}", .{ object_kind, object_ref, reason });
        if (title.len != 0) try io.out(" {s}", .{title});
        try io.out("\n", .{});
        shown += 1;
    }
    if (shown == 0) try io.out("subscriptions: none\n", .{});
}

fn resolveNotificationEventHash(allocator: Allocator, repo: repo_mod.Repo, principal: []const u8, raw_ref: []const u8) ![]u8 {
    if (!isHexPrefix(raw_ref)) {
        try io.eprint("gt notification read: EVENT must be a notification event hash prefix\n", .{});
        return CliError.UserError;
    }

    var db = try SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const pattern = try std.fmt.allocPrint(allocator, "{s}%", .{raw_ref});
    defer allocator.free(pattern);
    var stmt = try db.prepare(
        \\SELECT event_hash
        \\FROM notification_inbox
        \\WHERE principal = ?
        \\  AND event_hash LIKE ?
        \\ORDER BY event_hash
        \\LIMIT 2
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindText(2, pattern);
    if (!(try stmt.step())) {
        try io.eprint("gt notification read: no notification matches {s}\n", .{raw_ref});
        return CliError.NotFound;
    }
    const first = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(first);
    if (try stmt.step()) {
        try io.eprint("gt notification read: notification reference {s} is ambiguous\n", .{raw_ref});
        return CliError.UserError;
    }
    return first;
}

fn currentPrincipalOwned(allocator: Allocator, repo: repo_mod.Repo) ![]u8 {
    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try io.eprint("gt notification: Gitomi is not initialized; run `gt init`\n", .{});
            return CliError.UserError;
        },
        else => return err,
    };
    defer cfg.deinit();
    return try allocator.dupe(u8, cfg.principal);
}

fn canonicalTargetKind(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "issue")) return "issue";
    if (std.mem.eql(u8, value, "pr") or std.mem.eql(u8, value, "pull")) return "pull";
    return null;
}

fn isHexPrefix(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}
