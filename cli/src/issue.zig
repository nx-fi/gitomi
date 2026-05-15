const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const comment = @import("comment.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const reaction = @import("reaction.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");
const work_items = @import("work_items.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const issue = @This();
const out = io.out;
const eprint = io.eprint;
const EventWriter = event_writer_mod.EventWriter;
const buildIssueOpenedJson = event_mod.buildIssueOpenedJson;
const buildIssueProjectEventJson = event_mod.buildIssueProjectEventJson;
const buildIssueProjectFieldClearedJson = event_mod.buildIssueProjectFieldClearedJson;
const buildIssueProjectFieldSetJson = event_mod.buildIssueProjectFieldSetJson;
const buildIssueStringPayloadJson = event_mod.buildIssueStringPayloadJson;
const buildIssueUpdatedJson = event_mod.buildIssueUpdatedJson;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;
const shortObjectRef = util.shortObjectRef;
const short_object_ref_len = util.short_object_ref_len;
const createCommentForParentCommand = comment.createCommentForParentCommand;
const dupeNonEmptyOption = cmd_common.dupeNonEmptyOption;
const isIssueState = cmd_common.isIssueState;
const jsonStringArgument = cmd_common.jsonStringArgument;
const parseBodyReplyOptions = cmd_common.parseBodyReplyOptions;
const parseCollectionMutation = cmd_common.parseCollectionMutation;
const parsePositiveIntegerOption = cmd_common.parsePositiveIntegerOption;
const projectNameForCommand = cmd_common.projectNameForCommand;
const requireBodyOption = cmd_common.requireBodyOption;
const requireNonEmptyOption = cmd_common.requireNonEmptyOption;
const resolveIssueIdForCommand = cmd_common.resolveIssueIdForCommand;
const resolveProjectColumnForCommand = cmd_common.resolveProjectColumnForCommand;
const resolveProjectFieldIdForCommand = cmd_common.resolveProjectFieldIdForCommand;
const resolveProjectIdForCommand = cmd_common.resolveProjectIdForCommand;
const validateJsonArgument = cmd_common.validateJsonArgument;

pub fn createIssueOpenedEvent(
    allocator: Allocator,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue open");
    defer writer.deinit();

    const issue_id = try newUuidV7(allocator);
    defer allocator.free(issue_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try buildIssueOpenedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        title,
        body,
        labels,
        assignees,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.opened #{s} {s}", .{ issue_ref, title });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("opened issue #{s}\n", .{issue_ref});
    try out("  id:     {s}\n", .{issue_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueStringEvent(
    allocator: Allocator,
    issue_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try buildIssueStringPayloadJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, issue_ref, payload_value });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, issue_ref });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueUpdatedEvent(
    allocator: Allocator,
    issue_id: []const u8,
    update: event_mod.IssueUpdate,
) !void {
    if (!update.hasChanges()) {
        try eprint("gt issue edit: at least one update option is required\n", .{});
        return CliError.InvalidArgument;
    }

    var writer = try EventWriter.init(allocator, "gt issue edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try buildIssueUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        update,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.updated #{s}", .{issue_ref});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("issue.updated #{s}\n", .{issue_ref});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueProjectEvent(
    allocator: Allocator,
    issue_id: []const u8,
    project: []const u8,
    column: []const u8,
    project_ref: ?[]const u8,
    column_ref: ?[]const u8,
    add: bool,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue project");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();
    const event_type: []const u8 = if (add) "issue.project_added" else "issue.project_removed";

    const event_body = try buildIssueProjectEventJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        project,
        column,
        project_ref,
        column_ref,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, issue_ref, project });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, issue_ref });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueProjectFieldSetEvent(
    allocator: Allocator,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: ?[]const u8,
    field_id: ?[]const u8,
    field_key: ?[]const u8,
    value_json: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue project-field set");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try buildIssueProjectFieldSetJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        project_id,
        project_ref,
        field_id,
        field_key,
        value_json,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.project_field_set #{s} @{s}", .{ issue_ref, project_id[0..@min(project_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("issue.project_field_set #{s}\n", .{issue_ref});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueProjectFieldClearedEvent(
    allocator: Allocator,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: ?[]const u8,
    field_id: ?[]const u8,
    field_key: ?[]const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue project-field clear");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try buildIssueProjectFieldClearedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        project_id,
        project_ref,
        field_id,
        field_key,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.project_field_cleared #{s} @{s}", .{ issue_ref, project_id[0..@min(project_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("issue.project_field_cleared #{s}\n", .{issue_ref});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn cmdIssue(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt issue: expected subcommand 'list', 'show', 'open', 'comment', or an issue update command\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var agent_view = false;
        var filters = work_items.IssueListOptions{ .allocator = allocator };
        defer filters.deinit();
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
                    try io.eprint("gt issue list: --view must be summary or agent\n", .{});
                    return CliError.UserError;
                }
            } else if (std.mem.eql(u8, arg, "--agent")) {
                agent_view = true;
            } else if (std.mem.eql(u8, arg, "--state")) {
                const value = try util.requireValue(args, &i, "--state");
                filters.state = work_items.issueStateFilterFromValue(value) orelse {
                    try io.eprint("gt issue list: --state must be open, closed, or all\n", .{});
                    return CliError.UserError;
                };
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--author")) {
                filters.author = try dupeNonEmptyOption(allocator, "gt issue list", "--author", try util.requireValue(args, &i, "--author"));
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--label")) {
                filters.label = try dupeNonEmptyOption(allocator, "gt issue list", "--label", try util.requireValue(args, &i, "--label"));
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--project")) {
                filters.project = try dupeNonEmptyOption(allocator, "gt issue list", "--project", try util.requireValue(args, &i, "--project"));
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--milestone")) {
                filters.milestone = try dupeNonEmptyOption(allocator, "gt issue list", "--milestone", try util.requireValue(args, &i, "--milestone"));
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--assignee")) {
                filters.assignee = try dupeNonEmptyOption(allocator, "gt issue list", "--assignee", try util.requireValue(args, &i, "--assignee"));
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--sort")) {
                const value = try util.requireValue(args, &i, "--sort");
                filters.sort = work_items.issueSortFromValue(value) orelse {
                    try io.eprint("gt issue list: --sort must be newest, oldest, or updated\n", .{});
                    return CliError.UserError;
                };
                filtered = true;
            } else if (std.mem.eql(u8, arg, "--limit")) {
                filters.limit = try parsePositiveIntegerOption("gt issue list", "--limit", try util.requireValue(args, &i, "--limit"));
                filtered = true;
            } else {
                try io.eprint("gt issue list: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        if (agent_view) {
            var db = try work_items.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
            defer db.deinit();
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try work_items.appendIssueListAgentJson(&buf, allocator, &db, filters);
            try io.out("{s}\n", .{buf.items});
            return;
        }
        if (filtered) {
            var db = try work_items.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
            defer db.deinit();
            if (json) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                try work_items.appendIssueListAgentJson(&buf, allocator, &db, filters);
                try io.out("{s}\n", .{buf.items});
                return;
            }
            var stmt = try work_items.prepareIssueListStmt(allocator, &db, filters);
            defer stmt.deinit();
            while (try stmt.step()) {
                var row = try work_items.issueListRowFromStmt(allocator, &stmt);
                defer row.deinit(allocator);
                var ref_buf: [util.short_object_ref_len]u8 = undefined;
                try io.out("#{s} {s} {s}\n", .{ util.shortObjectRef(&ref_buf, row.id), row.state, row.title });
            }
            return;
        }
        try index.listIssuesFromIndex(allocator, repo, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len < 2) {
            try io.eprint("gt issue show: ISSUE is required\n", .{});
            return CliError.UserError;
        }
        var json = false;
        var agent_view = false;
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
                    try io.eprint("gt issue show: --view must be summary or agent\n", .{});
                    return CliError.UserError;
                }
            } else if (std.mem.eql(u8, arg, "--agent")) {
                agent_view = true;
            } else {
                try io.eprint("gt issue show: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }

        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        const issue_id = try index.resolveIssueId(allocator, repo, args[1]);
        defer allocator.free(issue_id);
        if (agent_view) {
            var db = try work_items.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
            defer db.deinit();
            const detail = (try work_items.loadIssueDetail(allocator, &db, issue_id)) orelse {
                try io.eprint("gt issue: no issue matches {s}\n", .{issue_id});
                return CliError.NotFound;
            };
            defer detail.deinit(allocator);
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try work_items.appendIssueAgentJson(&buf, allocator, &db, detail);
            try io.out("{s}\n", .{buf.items});
            return;
        }
        try index.showIssueFromIndex(allocator, repo, issue_id, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("gt issue edit: ISSUE is required\n", .{});
            return CliError.UserError;
        }

        var update = event_mod.IssueUpdate{};
        var labels_added: std.ArrayList([]const u8) = .empty;
        defer labels_added.deinit(allocator);
        var labels_removed: std.ArrayList([]const u8) = .empty;
        defer labels_removed.deinit(allocator);
        var assignees_added: std.ArrayList([]const u8) = .empty;
        defer assignees_added.deinit(allocator);
        var assignees_removed: std.ArrayList([]const u8) = .empty;
        defer assignees_removed.deinit(allocator);

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--title")) {
                update.title = try util.requireValue(args, &i, "--title");
            } else if (std.mem.eql(u8, arg, "--body")) {
                update.body = try util.requireValue(args, &i, "--body");
            } else if (std.mem.eql(u8, arg, "--state")) {
                const state = try util.requireValue(args, &i, "--state");
                if (!isIssueState(state)) {
                    try io.eprint("gt issue edit: --state must be open or closed\n", .{});
                    return CliError.UserError;
                }
                update.state = state;
            } else if (std.mem.eql(u8, arg, "--label")) {
                const value = try util.requireValue(args, &i, "--label");
                try requireNonEmptyOption("gt issue edit", "--label", value);
                try labels_added.append(allocator, value);
            } else if (std.mem.eql(u8, arg, "--unlabel")) {
                const value = try util.requireValue(args, &i, "--unlabel");
                try requireNonEmptyOption("gt issue edit", "--unlabel", value);
                try labels_removed.append(allocator, value);
            } else if (std.mem.eql(u8, arg, "--assignee")) {
                const value = try util.requireValue(args, &i, "--assignee");
                try requireNonEmptyOption("gt issue edit", "--assignee", value);
                try assignees_added.append(allocator, value);
            } else if (std.mem.eql(u8, arg, "--unassign")) {
                const value = try util.requireValue(args, &i, "--unassign");
                try requireNonEmptyOption("gt issue edit", "--unassign", value);
                try assignees_removed.append(allocator, value);
            } else {
                try io.eprint("gt issue edit: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }

        update.labels_added = labels_added.items;
        update.labels_removed = labels_removed.items;
        update.assignees_added = assignees_added.items;
        update.assignees_removed = assignees_removed.items;
        if (!update.hasChanges()) {
            try io.eprint("gt issue edit: at least one update option is required\n", .{});
            return CliError.UserError;
        }
        if (update.title) |title| {
            try requireNonEmptyOption("gt issue edit", "--title", title);
        }

        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        try issue.createIssueUpdatedEvent(allocator, issue_id, update);
        return;
    }

    if (std.mem.eql(u8, args[0], "title") or std.mem.eql(u8, args[0], "body")) {
        const payload_key: []const u8 = if (std.mem.eql(u8, args[0], "title")) "title" else "body";
        const event_type: []const u8 = if (std.mem.eql(u8, args[0], "title")) "issue.title_set" else "issue.body_set";
        const option_name: []const u8 = if (std.mem.eql(u8, args[0], "title")) "--title" else "--body";
        if (args.len < 2) {
            try io.eprint("gt issue {s}: ISSUE is required\n", .{args[0]});
            return CliError.UserError;
        }
        var value: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, option_name)) {
                value = try util.requireValue(args, &i, option_name);
            } else {
                try io.eprint("gt issue {s}: unknown option '{s}'\n", .{ args[0], arg });
                return CliError.UserError;
            }
        }
        if (value == null or std.mem.trim(u8, value.?, " \t\r\n").len == 0) {
            try io.eprint("gt issue {s}: {s} is required\n", .{ args[0], option_name });
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        try issue.createIssueStringEvent(allocator, issue_id, event_type, payload_key, value.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "comment")) {
        if (args.len < 2) {
            try io.eprint("gt issue comment: ISSUE is required\n", .{});
            return CliError.UserError;
        }
        const options = try parseBodyReplyOptions("gt issue comment", args, 2);
        const body = try requireBodyOption("gt issue comment", options.body);
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        try createCommentForParentCommand(allocator, "gt issue comment", "issue", "issue", issue_id, body, options.reply_ref);
        return;
    }

    if (std.mem.eql(u8, args[0], "close") or std.mem.eql(u8, args[0], "reopen")) {
        if (args.len < 2) {
            try io.eprint("gt issue {s}: expected ISSUE\n", .{args[0]});
            return CliError.UserError;
        }
        var body: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else {
                try io.eprint("gt issue {s}: unknown option '{s}'\n", .{ args[0], arg });
                return CliError.UserError;
            }
        }
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        if (body) |comment_body| {
            try requireNonEmptyOption(if (std.mem.eql(u8, args[0], "close")) "gt issue close" else "gt issue reopen", "--body", comment_body);
            try comment.createCommentAddedEvent(allocator, "issue", issue_id, comment_body);
        }
        const state: []const u8 = if (std.mem.eql(u8, args[0], "close")) "closed" else "open";
        try issue.createIssueStringEvent(allocator, issue_id, "issue.state_set", "state", state);
        return;
    }

    if (std.mem.eql(u8, args[0], "label") or std.mem.eql(u8, args[0], "assignee")) {
        if (args.len != 4) {
            try io.eprint("gt issue {s}: expected ISSUE add|remove VALUE\n", .{args[0]});
            return CliError.UserError;
        }
        const collection = args[0];
        const parsed = try parseCollectionMutation("gt issue", collection, args[1], args[2]);
        const object_ref = parsed.object_ref;
        const op = parsed.op;
        if (!std.mem.eql(u8, op, "add") and !std.mem.eql(u8, op, "remove")) {
            try io.eprint("gt issue {s}: expected add or remove\n", .{collection});
            return CliError.UserError;
        }
        if (std.mem.trim(u8, args[3], " \t\r\n").len == 0) {
            try io.eprint("gt issue {s}: value must not be empty\n", .{collection});
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, object_ref);
        defer allocator.free(issue_id);
        const event_type = try std.fmt.allocPrint(allocator, "issue.{s}_{s}", .{ collection, if (std.mem.eql(u8, op, "add")) "added" else "removed" });
        defer allocator.free(event_type);
        const payload_key: []const u8 = if (std.mem.eql(u8, collection, "label")) "label" else "assignee";
        try issue.createIssueStringEvent(allocator, issue_id, event_type, payload_key, args[3]);
        return;
    }

    if (std.mem.eql(u8, args[0], "milestone")) {
        if (args.len < 2) {
            try io.eprint("gt issue milestone: ISSUE is required\n", .{});
            return CliError.UserError;
        }
        var value: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--milestone")) {
                value = try util.requireValue(args, &i, "--milestone");
            } else {
                try io.eprint("gt issue milestone: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (value == null) {
            try io.eprint("gt issue milestone: --milestone is required\n", .{});
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        try issue.createIssueStringEvent(allocator, issue_id, "issue.milestone_set", "milestone", value.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "project")) {
        if (args.len < 5) {
            try io.eprint("gt issue project: expected ISSUE add|remove PROJECT --column COLUMN\n", .{});
            return CliError.UserError;
        }
        const parsed = try parseCollectionMutation("gt issue", "project", args[1], args[2]);
        const issue_ref = parsed.object_ref;
        const op = parsed.op;
        if (!std.mem.eql(u8, op, "add") and !std.mem.eql(u8, op, "remove")) {
            try io.eprint("gt issue project: expected add or remove\n", .{});
            return CliError.UserError;
        }
        const project_name = args[3];
        try requireNonEmptyOption("gt issue project", "PROJECT", project_name);
        var column: ?[]const u8 = null;
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--column") or std.mem.eql(u8, args[i], "-c")) {
                column = try util.requireValue(args, &i, "--column");
            } else {
                try io.eprint("gt issue project: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (column == null or std.mem.trim(u8, column.?, " \t\r\n").len == 0) {
            try io.eprint("gt issue project: --column is required\n", .{});
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, issue_ref);
        defer allocator.free(issue_id);
        const project_id = try resolveProjectIdForCommand(allocator, project_name);
        defer allocator.free(project_id);
        const canonical_project_name = try projectNameForCommand(allocator, project_id);
        defer allocator.free(canonical_project_name);
        var resolved_column = try resolveProjectColumnForCommand(allocator, project_id, column.?);
        defer resolved_column.deinit(allocator);
        try issue.createIssueProjectEvent(allocator, issue_id, canonical_project_name, resolved_column.column, project_id, resolved_column.column_ref, std.mem.eql(u8, op, "add"));
        return;
    }

    if (std.mem.eql(u8, args[0], "project-field")) {
        if (args.len < 5) {
            try io.eprint("gt issue project-field: expected ISSUE set|clear PROJECT FIELD\n", .{});
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        const op = args[2];
        if (!std.mem.eql(u8, op, "set") and !std.mem.eql(u8, op, "clear")) {
            try io.eprint("gt issue project-field: expected set or clear\n", .{});
            return CliError.UserError;
        }
        const project_ref = args[3];
        const field_ref = args[4];
        const project_id = try resolveProjectIdForCommand(allocator, project_ref);
        defer allocator.free(project_id);
        const field_id = try resolveProjectFieldIdForCommand(allocator, project_id, field_ref);
        defer allocator.free(field_id);

        if (std.mem.eql(u8, op, "clear")) {
            if (args.len != 5) {
                try io.eprint("gt issue project-field clear: unexpected option '{s}'\n", .{args[5]});
                return CliError.UserError;
            }
            try issue.createIssueProjectFieldClearedEvent(allocator, issue_id, project_id, project_ref, field_id, null);
            return;
        }

        var value_json: ?[]u8 = null;
        defer if (value_json) |value| allocator.free(value);
        var i: usize = 5;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--value")) {
                if (value_json != null) {
                    try io.eprint("gt issue project-field set: provide only one value option\n", .{});
                    return CliError.UserError;
                }
                value_json = try jsonStringArgument(allocator, try util.requireValue(args, &i, "--value"));
            } else if (std.mem.eql(u8, arg, "--value-json")) {
                if (value_json != null) {
                    try io.eprint("gt issue project-field set: provide only one value option\n", .{});
                    return CliError.UserError;
                }
                const raw_json = try util.requireValue(args, &i, "--value-json");
                try validateJsonArgument(allocator, "gt issue project-field set", "--value-json", raw_json);
                value_json = try allocator.dupe(u8, raw_json);
            } else {
                try io.eprint("gt issue project-field set: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }
        if (value_json == null) {
            try io.eprint("gt issue project-field set: --value or --value-json is required\n", .{});
            return CliError.UserError;
        }
        try issue.createIssueProjectFieldSetEvent(allocator, issue_id, project_id, project_ref, field_id, null, value_json.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "react") or std.mem.eql(u8, args[0], "unreact")) {
        if (args.len != 3) {
            try io.eprint("gt issue {s}: expected ISSUE EMOJI\n", .{args[0]});
            return CliError.UserError;
        }
        const issue_id = try resolveIssueIdForCommand(allocator, args[1]);
        defer allocator.free(issue_id);
        try reaction.createReactionEvent(allocator, "issue", issue_id, args[2], std.mem.eql(u8, args[0], "react"));
        return;
    }

    if (!std.mem.eql(u8, args[0], "open")) {
        try io.eprint("gt issue: expected subcommand 'list', 'show', 'open', 'comment', or an issue update command\n", .{});
        return CliError.UserError;
    }

    var title: ?[]const u8 = null;
    var body: []const u8 = "";
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);
    var assignees: std.ArrayList([]const u8) = .empty;
    defer assignees.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
            title = try util.requireValue(args, &i, "--title");
        } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
            body = try util.requireValue(args, &i, "--body");
        } else if (std.mem.eql(u8, arg, "--label") or std.mem.eql(u8, arg, "-l")) {
            try labels.append(allocator, try util.requireValue(args, &i, "--label"));
        } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "-a")) {
            try assignees.append(allocator, try util.requireValue(args, &i, "--assignee"));
        } else {
            try io.eprint("gt issue open: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }

    if (title == null or std.mem.trim(u8, title.?, " \t\r\n").len == 0) {
        try io.eprint("gt issue open: --title is required\n", .{});
        return CliError.UserError;
    }

    try issue.createIssueOpenedEvent(allocator, title.?, body, labels.items, assignees.items);
}
