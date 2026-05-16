const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const comment = @import("comment.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const reaction = @import("reaction.zig");
const util = @import("util.zig");
const work_items = @import("work_items.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const pull_mod = @This();
const out = io.out;
const eprint = io.eprint;
const EventWriter = event_writer_mod.EventWriter;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;
const shortObjectRef = util.shortObjectRef;
const short_object_ref_len = util.short_object_ref_len;
const PullDiffCommentOptions = cmd_common.PullDiffCommentOptions;
const appendCollectionOptionValues = cmd_common.appendCollectionOptionValues;
const createCommentForParentCommandWithRepo = comment.createCommentForParentCommandWithRepo;
const formatPullDiffCommentBodyFromOptions = cmd_common.formatPullDiffCommentBodyFromOptions;
const isIssueState = cmd_common.isIssueState;
const parseCollectionMutation = cmd_common.parseCollectionMutation;
const parsePositiveIntegerOption = cmd_common.parsePositiveIntegerOption;
const parsePositiveLineOption = cmd_common.parsePositiveLineOption;
const requireNonEmptyOption = cmd_common.requireNonEmptyOption;

pub fn createPullOpenedEvent(
    allocator: Allocator,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
) !void {
    var writer = try EventWriter.init(allocator, "gt pr create");
    defer writer.deinit();

    const pull_id = try newUuidV7(allocator);
    defer allocator.free(pull_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullOpenedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        title,
        body,
        base_ref,
        head_ref,
        draft,
    );
    defer allocator.free(event_body);

    var pull_ref_buf: [short_object_ref_len]u8 = undefined;
    const pull_ref = shortObjectRef(&pull_ref_buf, pull_id);
    const subject = try std.fmt.allocPrint(allocator, "pull.opened #{s} {s}", .{ pull_ref, title });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pr", subject, event_body);
    defer allocator.free(commit_oid);

    try out("opened pr #{s}\n", .{pull_ref});
    try out("  id:     {s}\n", .{pull_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createPullStringEvent(
    allocator: Allocator,
    pull_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt pr");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullStringPayloadJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    var pull_ref_buf: [short_object_ref_len]u8 = undefined;
    const pull_ref = shortObjectRef(&pull_ref_buf, pull_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, pull_ref, payload_value });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pr", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, pull_ref });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createPullMergedEvent(
    allocator: Allocator,
    pull_id: []const u8,
    merge_oid: ?[]const u8,
    target_oid: ?[]const u8,
) !void {
    try createPullMergedEventWithMetadata(allocator, pull_id, merge_oid, target_oid, .{});
}

pub fn createPullMergedEventWithMetadata(
    allocator: Allocator,
    pull_id: []const u8,
    merge_oid: ?[]const u8,
    target_oid: ?[]const u8,
    metadata: event_mod.PullMergedMetadata,
) !void {
    var writer = try EventWriter.init(allocator, "gt pr");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullMergedJsonWithMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        merge_oid,
        target_oid,
        metadata,
    );
    defer allocator.free(event_body);

    var pull_ref_buf: [short_object_ref_len]u8 = undefined;
    const pull_ref = shortObjectRef(&pull_ref_buf, pull_id);
    const subject = try std.fmt.allocPrint(allocator, "pull.merged #{s}", .{pull_ref});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pr", subject, event_body);
    defer allocator.free(commit_oid);

    try out("pull.merged #{s}\n", .{pull_ref});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createPullUpdatedEvent(
    allocator: Allocator,
    pull_id: []const u8,
    update: event_mod.PullUpdate,
) !void {
    if (!update.hasChanges()) {
        try eprint("gt pr edit: at least one update option is required\n", .{});
        return CliError.InvalidArgument;
    }

    var writer = try EventWriter.init(allocator, "gt pr edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        update,
    );
    defer allocator.free(event_body);

    var pull_ref_buf: [short_object_ref_len]u8 = undefined;
    const pull_ref = shortObjectRef(&pull_ref_buf, pull_id);
    const subject = try std.fmt.allocPrint(allocator, "pull.updated #{s}", .{pull_ref});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pr", subject, event_body);
    defer allocator.free(commit_oid);

    try out("pull.updated #{s}\n", .{pull_ref});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn cmdPr(allocator: Allocator, args: []const []const u8, command_context: []const u8) !void {
    if (args.len == 0) {
        try io.eprint("{s}: expected subcommand 'list', 'view', 'create', or a PR update command\n", .{command_context});
        return CliError.UserError;
    }

    var command_repo = cmd_common.CommandRepo.init(allocator);
    defer command_repo.deinit();

    if (std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var agent_view = false;
        var filters = work_items.PullListOptions{};
        var filtered = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
            } else if (std.mem.eql(u8, arg, "--view")) {
                const value = try util.requireValue(args, &i, "--view");
                if (std.mem.eql(u8, value, "agent") or std.mem.eql(u8, value, "full")) {
                    agent_view = true;
                } else if (std.mem.eql(u8, value, "summary")) {
                    agent_view = false;
                } else {
                    try io.eprint("{s} list: --view must be summary or agent\n", .{command_context});
                    return CliError.UserError;
                }
            } else if (std.mem.eql(u8, arg, "--agent")) {
                agent_view = true;
            } else if (std.mem.eql(u8, arg, "--state")) {
                const value = try util.requireValue(args, &i, "--state");
                filters.state = work_items.pullStateFilterFromValue(value) orelse {
                    try io.eprint("{s} list: --state must be open, merged, closed, or all\n", .{command_context});
                    return CliError.UserError;
                };
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--limit")) {
                filters.limit = try parsePositiveIntegerOption(if (std.mem.eql(u8, command_context, "gt pull")) "gt pull list" else "gt pr list", "--limit", try util.requireValue(args, &i, "--limit"));
                filtered = true;
            } else {
                try io.eprint("{s} list: unknown option '{s}'\n", .{ command_context, arg });
                return CliError.UserError;
            }
        }

        const repo = try command_repo.indexedRepo();
        if (agent_view or (filtered and json)) {
            var db = try work_items.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
            defer db.deinit();
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try work_items.appendPullListAgentJson(&buf, allocator, &db, filters);
            try io.out("{s}\n", .{buf.items});
            return;
        }
        if (filtered) {
            var db = try work_items.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
            defer db.deinit();
            var stmt = try work_items.preparePullListStmt(allocator, &db, filters);
            defer stmt.deinit();
            var shown: usize = 0;
            while (try stmt.step()) {
                if (filters.limit) |limit| {
                    if (shown >= limit) break;
                }
                var row = try work_items.pullListRowFromStmt(allocator, &stmt);
                defer row.deinit(allocator);
                var ref_buf: [util.short_object_ref_len]u8 = undefined;
                try io.out("#{s} {s} {s}->{s} {s}\n", .{
                    util.shortObjectRef(&ref_buf, row.id),
                    row.state,
                    row.head_ref,
                    row.base_ref,
                    row.title,
                });
                shown += 1;
            }
            return;
        }
        try index.listPullsFromIndex(allocator, repo, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "view") or std.mem.eql(u8, args[0], "show")) {
        if (args.len < 2) {
            try io.eprint("{s} {s}: PR is required\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        var json = false;
        var agent_view = false;
        var include_diff = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
            } else if (std.mem.eql(u8, arg, "--view")) {
                const value = try util.requireValue(args, &i, "--view");
                if (std.mem.eql(u8, value, "agent") or std.mem.eql(u8, value, "full")) {
                    agent_view = true;
                } else if (std.mem.eql(u8, value, "summary")) {
                    agent_view = false;
                } else {
                    try io.eprint("{s} {s}: --view must be summary or agent\n", .{ command_context, args[0] });
                    return CliError.UserError;
                }
            } else if (std.mem.eql(u8, arg, "--agent")) {
                agent_view = true;
            } else if (std.mem.eql(u8, arg, "--include-diff")) {
                include_diff = true;
            } else {
                try io.eprint("{s} {s}: unknown option '{s}'\n", .{ command_context, args[0], arg });
                return CliError.UserError;
            }
        }

        const repo = try command_repo.indexedRepo();
        const pull_id = try command_repo.resolvePullId(args[1]);
        defer allocator.free(pull_id);
        if (agent_view or include_diff) {
            var db = try work_items.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
            defer db.deinit();
            const detail = (try work_items.loadPullDetail(allocator, &db, pull_id)) orelse {
                try io.eprint("gt pr: no PR matches {s}\n", .{pull_id});
                return CliError.NotFound;
            };
            defer detail.deinit(allocator);
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try work_items.appendPullAgentJson(&buf, allocator, &db, repo, detail, include_diff);
            try io.out("{s}\n", .{buf.items});
            return;
        }
        try index.showPullFromIndex(allocator, repo, pull_id, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("{s} edit: PR is required\n", .{command_context});
            return CliError.UserError;
        }

        var update = event_mod.PullUpdate{};
        var labels_added: std.ArrayList([]const u8) = .empty;
        defer labels_added.deinit(allocator);
        var labels_removed: std.ArrayList([]const u8) = .empty;
        defer labels_removed.deinit(allocator);
        var assignees_added: std.ArrayList([]const u8) = .empty;
        defer assignees_added.deinit(allocator);
        var assignees_removed: std.ArrayList([]const u8) = .empty;
        defer assignees_removed.deinit(allocator);
        var reviewers_added: std.ArrayList([]const u8) = .empty;
        defer reviewers_added.deinit(allocator);
        var reviewers_removed: std.ArrayList([]const u8) = .empty;
        defer reviewers_removed.deinit(allocator);

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
                update.title = try util.requireValue(args, &i, "--title");
            } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
                update.body = try util.requireValue(args, &i, "--body");
            } else if (std.mem.eql(u8, arg, "--state")) {
                const state = try util.requireValue(args, &i, "--state");
                if (!isIssueState(state)) {
                    try io.eprint("{s} edit: --state must be open or closed\n", .{command_context});
                    return CliError.UserError;
                }
                update.state = state;
            } else if (std.mem.eql(u8, arg, "--base") or std.mem.eql(u8, arg, "-B")) {
                update.base_ref = try util.requireValue(args, &i, "--base");
            } else if (std.mem.eql(u8, arg, "--head")) {
                update.head_ref = try util.requireValue(args, &i, "--head");
            } else if (std.mem.eql(u8, arg, "--label") or std.mem.eql(u8, arg, "--add-label")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &labels_added, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--unlabel") or std.mem.eql(u8, arg, "--remove-label")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &labels_removed, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "--add-assignee")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &assignees_added, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--unassign") or std.mem.eql(u8, arg, "--remove-assignee")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &assignees_removed, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--reviewer") or std.mem.eql(u8, arg, "--add-reviewer")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &reviewers_added, command_context, arg, value);
            } else if (std.mem.eql(u8, arg, "--unreviewer") or std.mem.eql(u8, arg, "--remove-reviewer")) {
                const value = try util.requireValue(args, &i, arg);
                try appendCollectionOptionValues(allocator, &reviewers_removed, command_context, arg, value);
            } else {
                try io.eprint("{s} edit: unknown option '{s}'\n", .{ command_context, arg });
                return CliError.UserError;
            }
        }

        update.labels_added = labels_added.items;
        update.labels_removed = labels_removed.items;
        update.assignees_added = assignees_added.items;
        update.assignees_removed = assignees_removed.items;
        update.reviewers_added = reviewers_added.items;
        update.reviewers_removed = reviewers_removed.items;
        if (!update.hasChanges()) {
            try io.eprint("{s} edit: at least one update option is required\n", .{command_context});
            return CliError.UserError;
        }
        if (update.title) |title| try requireNonEmptyOption(command_context, "--title", title);
        if (update.base_ref) |base_ref| try requireNonEmptyOption(command_context, "--base", base_ref);
        if (update.head_ref) |head_ref| try requireNonEmptyOption(command_context, "--head", head_ref);

        const pull_id = try command_repo.resolvePullId(args[1]);
        defer allocator.free(pull_id);
        try pull_mod.createPullUpdatedEvent(allocator, pull_id, update);
        return;
    }

    if (std.mem.eql(u8, args[0], "title") or
        std.mem.eql(u8, args[0], "body") or
        std.mem.eql(u8, args[0], "base") or
        std.mem.eql(u8, args[0], "head"))
    {
        const payload_key: []const u8 = if (std.mem.eql(u8, args[0], "title"))
            "title"
        else if (std.mem.eql(u8, args[0], "body"))
            "body"
        else if (std.mem.eql(u8, args[0], "base"))
            "base_ref"
        else
            "head_ref";
        const event_type: []const u8 = if (std.mem.eql(u8, args[0], "title"))
            "pull.title_set"
        else if (std.mem.eql(u8, args[0], "body"))
            "pull.body_set"
        else if (std.mem.eql(u8, args[0], "base"))
            "pull.base_set"
        else
            "pull.head_set";
        const option_name: []const u8 = if (std.mem.eql(u8, args[0], "title"))
            "--title"
        else if (std.mem.eql(u8, args[0], "body"))
            "--body"
        else if (std.mem.eql(u8, args[0], "base"))
            "--base"
        else
            "--head";
        if (args.len < 2) {
            try io.eprint("{s} {s}: PR is required\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        var value: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, option_name)) {
                value = try util.requireValue(args, &i, option_name);
            } else {
                try io.eprint("{s} {s}: unknown option '{s}'\n", .{ command_context, args[0], arg });
                return CliError.UserError;
            }
        }
        if (value == null or std.mem.trim(u8, value.?, " \t\r\n").len == 0) {
            try io.eprint("{s} {s}: {s} is required\n", .{ command_context, args[0], option_name });
            return CliError.UserError;
        }
        const pull_id = try command_repo.resolvePullId(args[1]);
        defer allocator.free(pull_id);
        try pull_mod.createPullStringEvent(allocator, pull_id, event_type, payload_key, value.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "close") or std.mem.eql(u8, args[0], "reopen")) {
        if (args.len != 2) {
            try io.eprint("{s} {s}: expected PR\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        const pull_id = try command_repo.resolvePullId(args[1]);
        defer allocator.free(pull_id);
        const state: []const u8 = if (std.mem.eql(u8, args[0], "close")) "closed" else "open";
        try pull_mod.createPullStringEvent(allocator, pull_id, "pull.state_set", "state", state);
        return;
    }

    if (std.mem.eql(u8, args[0], "label") or
        std.mem.eql(u8, args[0], "assignee") or
        std.mem.eql(u8, args[0], "reviewer"))
    {
        if (args.len != 4) {
            try io.eprint("{s} {s}: expected PR add|remove VALUE\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        const collection = args[0];
        const parsed = try parseCollectionMutation(command_context, collection, args[1], args[2]);
        const object_ref = parsed.object_ref;
        const op = parsed.op;
        if (!std.mem.eql(u8, op, "add") and !std.mem.eql(u8, op, "remove")) {
            try io.eprint("{s} {s}: expected add or remove\n", .{ command_context, collection });
            return CliError.UserError;
        }
        if (std.mem.trim(u8, args[3], " \t\r\n").len == 0) {
            try io.eprint("{s} {s}: value must not be empty\n", .{ command_context, collection });
            return CliError.UserError;
        }
        const pull_id = try command_repo.resolvePullId(object_ref);
        defer allocator.free(pull_id);
        const event_type = try std.fmt.allocPrint(allocator, "pull.{s}_{s}", .{ collection, if (std.mem.eql(u8, op, "add")) "added" else "removed" });
        defer allocator.free(event_type);
        try pull_mod.createPullStringEvent(allocator, pull_id, event_type, collection, args[3]);
        return;
    }

    if (std.mem.eql(u8, args[0], "comment")) {
        const comment_context = if (std.mem.eql(u8, command_context, "gt pull")) "gt pull comment" else "gt pr comment";
        if (args.len < 2) {
            try io.eprint("{s}: PR is required\n", .{comment_context});
            return CliError.UserError;
        }
        var body: ?[]const u8 = null;
        var reply_ref: ?[]const u8 = null;
        var diff_options = PullDiffCommentOptions{};
        var line_option_seen = false;
        var start_line_option_seen = false;
        var end_line_option_seen = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else if (std.mem.eql(u8, arg, "--reply")) {
                reply_ref = try util.requireValue(args, &i, "--reply");
            } else if (std.mem.eql(u8, arg, "--file")) {
                diff_options.file = try util.requireValue(args, &i, "--file");
            } else if (std.mem.eql(u8, arg, "--side")) {
                diff_options.side = try util.requireValue(args, &i, "--side");
            } else if (std.mem.eql(u8, arg, "--line")) {
                diff_options.line = try parsePositiveLineOption(comment_context, "--line", try util.requireValue(args, &i, "--line"));
                line_option_seen = true;
            } else if (std.mem.eql(u8, arg, "--start-line")) {
                diff_options.start_line = try parsePositiveLineOption(comment_context, "--start-line", try util.requireValue(args, &i, "--start-line"));
                start_line_option_seen = true;
            } else if (std.mem.eql(u8, arg, "--end-line")) {
                diff_options.end_line = try parsePositiveLineOption(comment_context, "--end-line", try util.requireValue(args, &i, "--end-line"));
                end_line_option_seen = true;
            } else {
                try io.eprint("{s}: unknown option '{s}'\n", .{ comment_context, arg });
                return CliError.UserError;
            }
        }
        diff_options.line_option_seen = line_option_seen;
        diff_options.start_line_option_seen = start_line_option_seen;
        diff_options.end_line_option_seen = end_line_option_seen;
        if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
            try io.eprint("{s}: --body is required\n", .{comment_context});
            return CliError.UserError;
        }
        const comment_body = body.?;
        const pull_id = try command_repo.resolvePullId(args[1]);
        defer allocator.free(pull_id);
        if (reply_ref) |_| {
            if (diff_options.hasAny()) {
                try io.eprint("{s}: --reply cannot be combined with diff line options\n", .{comment_context});
                return CliError.UserError;
            }
            try createCommentForParentCommandWithRepo(&command_repo, allocator, comment_context, "pull", "pull request", pull_id, comment_body, reply_ref);
        } else {
            const diff_comment_body = try formatPullDiffCommentBodyFromOptions(allocator, comment_context, comment_body, diff_options);
            defer if (diff_comment_body) |value| allocator.free(value);
            try comment.createCommentAddedEvent(allocator, "pull", pull_id, diff_comment_body orelse comment_body);
        }
        return;
    }

    if (std.mem.eql(u8, args[0], "react") or std.mem.eql(u8, args[0], "unreact")) {
        if (args.len != 3) {
            try io.eprint("{s} {s}: expected PR EMOJI\n", .{ command_context, args[0] });
            return CliError.UserError;
        }
        const pull_id = try command_repo.resolvePullId(args[1]);
        defer allocator.free(pull_id);
        try reaction.createReactionEvent(allocator, "pull", pull_id, args[2], std.mem.eql(u8, args[0], "react"));
        return;
    }

    if (std.mem.eql(u8, args[0], "merge")) {
        if (args.len < 2) {
            try io.eprint("{s} merge: PR is required\n", .{command_context});
            return CliError.UserError;
        }
        var merge_oid: ?[]const u8 = null;
        var target_oid: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--merge-oid")) {
                merge_oid = try util.requireValue(args, &i, "--merge-oid");
            } else if (std.mem.eql(u8, arg, "--target-oid")) {
                target_oid = try util.requireValue(args, &i, "--target-oid");
            } else {
                try io.eprint("{s} merge: unknown option '{s}'\n", .{ command_context, arg });
                return CliError.UserError;
            }
        }
        if ((merge_oid == null or std.mem.trim(u8, merge_oid.?, " \t\r\n").len == 0) and
            (target_oid == null or std.mem.trim(u8, target_oid.?, " \t\r\n").len == 0))
        {
            try io.eprint("{s} merge: --merge-oid or --target-oid is required\n", .{command_context});
            return CliError.UserError;
        }
        const pull_id = try command_repo.resolvePullId(args[1]);
        defer allocator.free(pull_id);
        try pull_mod.createPullMergedEvent(allocator, pull_id, merge_oid, target_oid);
        return;
    }

    if (!std.mem.eql(u8, args[0], "create") and !std.mem.eql(u8, args[0], "new") and !std.mem.eql(u8, args[0], "open")) {
        try io.eprint("{s}: expected subcommand 'list', 'view', 'create', or a PR update command\n", .{command_context});
        return CliError.UserError;
    }

    var title: ?[]const u8 = null;
    var body: []const u8 = "";
    var base_ref: ?[]const u8 = null;
    var head_ref: ?[]const u8 = null;
    var draft = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
            title = try util.requireValue(args, &i, "--title");
        } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
            body = try util.requireValue(args, &i, "--body");
        } else if (std.mem.eql(u8, arg, "--base") or std.mem.eql(u8, arg, "-B")) {
            base_ref = try util.requireValue(args, &i, "--base");
        } else if (std.mem.eql(u8, arg, "--head") or std.mem.eql(u8, arg, "-H")) {
            head_ref = try util.requireValue(args, &i, "--head");
        } else if (std.mem.eql(u8, arg, "--draft") or std.mem.eql(u8, arg, "-d")) {
            draft = true;
        } else {
            try io.eprint("{s} {s}: unknown option '{s}'\n", .{ command_context, args[0], arg });
            return CliError.UserError;
        }
    }

    if (title == null or std.mem.trim(u8, title.?, " \t\r\n").len == 0) {
        try io.eprint("{s} {s}: --title is required\n", .{ command_context, args[0] });
        return CliError.UserError;
    }
    if (base_ref == null or std.mem.trim(u8, base_ref.?, " \t\r\n").len == 0) {
        try io.eprint("{s} {s}: --base is required\n", .{ command_context, args[0] });
        return CliError.UserError;
    }
    if (head_ref == null or std.mem.trim(u8, head_ref.?, " \t\r\n").len == 0) {
        try io.eprint("{s} {s}: --head is required\n", .{ command_context, args[0] });
        return CliError.UserError;
    }

    try pull_mod.createPullOpenedEvent(allocator, title.?, body, base_ref.?, head_ref.?, draft);
}
