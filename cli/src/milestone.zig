const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const milestone = @This();
const out = io.out;
const isIssueState = cmd_common.isIssueState;
const newUuidV7 = util.newUuidV7;
const requireNonEmptyOption = cmd_common.requireNonEmptyOption;
const rfc3339Now = util.rfc3339Now;

pub fn createMilestoneCreatedEvent(
    allocator: Allocator,
    title: []const u8,
    description: []const u8,
    due_at: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt milestone create");
    defer writer.deinit();

    const milestone_id = try newUuidV7(allocator);
    defer allocator.free(milestone_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildMilestoneCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        milestone_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        title,
        description,
        due_at,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "milestone.created ^{s} {s}", .{ milestone_id[0..7], title });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt milestone", subject, event_body);
    defer allocator.free(commit_oid);

    try out("created milestone ^{s}\n", .{milestone_id[0..7]});
    try out("  id:     {s}\n", .{milestone_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createMilestoneUpdatedEvent(
    allocator: Allocator,
    milestone_id: []const u8,
    update: event_mod.MilestoneUpdate,
) !void {
    var writer = try EventWriter.init(allocator, "gt milestone edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildMilestoneUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        milestone_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        update,
    );
    defer allocator.free(event_body);

    const short_id = milestone_id[0..@min(milestone_id.len, 7)];
    const subject = try std.fmt.allocPrint(allocator, "milestone.updated ^{s}", .{short_id});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt milestone", subject, event_body);
    defer allocator.free(commit_oid);

    try out("milestone.updated ^{s}\n", .{short_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createMilestoneStringEvent(
    allocator: Allocator,
    milestone_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt milestone");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildMilestoneStringPayloadJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        milestone_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    const short_id = milestone_id[0..@min(milestone_id.len, 7)];
    const subject = try std.fmt.allocPrint(allocator, "{s} ^{s} {s}", .{ event_type, short_id, payload_value });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt milestone", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} ^{s}\n", .{ event_type, short_id });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn cmdMilestone(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt milestone: expected subcommand 'list', 'create', 'edit', 'close', or 'reopen'\n", .{});
        return CliError.UserError;
    }

    var command_repo = cmd_common.CommandRepo.init(allocator);
    defer command_repo.deinit();

    if (std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else {
                try io.eprint("gt milestone list: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        const repo = try command_repo.indexedRepo();
        try index.listMilestonesFromIndex(allocator, repo, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "create")) {
        var title: ?[]const u8 = null;
        var description: []const u8 = "";
        var due_at: []const u8 = "";
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--title") or std.mem.eql(u8, args[i], "-t")) {
                title = try util.requireValue(args, &i, "--title");
            } else if (std.mem.eql(u8, args[i], "--description") or std.mem.eql(u8, args[i], "-d")) {
                description = try util.requireValue(args, &i, "--description");
            } else if (std.mem.eql(u8, args[i], "--due")) {
                due_at = try util.requireValue(args, &i, "--due");
            } else {
                try io.eprint("gt milestone create: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (title == null or std.mem.trim(u8, title.?, " \t\r\n").len == 0) {
            try io.eprint("gt milestone create: --title is required\n", .{});
            return CliError.UserError;
        }
        try milestone.createMilestoneCreatedEvent(allocator, title.?, description, due_at);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("gt milestone edit: MILESTONE is required\n", .{});
            return CliError.UserError;
        }

        var update = event_mod.MilestoneUpdate{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--title") or std.mem.eql(u8, args[i], "-t")) {
                update.title = try util.requireValue(args, &i, "--title");
            } else if (std.mem.eql(u8, args[i], "--description") or std.mem.eql(u8, args[i], "-d")) {
                update.description = try util.requireValue(args, &i, "--description");
            } else if (std.mem.eql(u8, args[i], "--due")) {
                update.due_at = try util.requireValue(args, &i, "--due");
            } else if (std.mem.eql(u8, args[i], "--state")) {
                const state = try util.requireValue(args, &i, "--state");
                if (!isIssueState(state)) {
                    try io.eprint("gt milestone edit: --state must be open or closed\n", .{});
                    return CliError.UserError;
                }
                update.state = state;
            } else {
                try io.eprint("gt milestone edit: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (!update.hasChanges()) {
            try io.eprint("gt milestone edit: at least one update option is required\n", .{});
            return CliError.UserError;
        }
        if (update.title) |title| {
            try requireNonEmptyOption("gt milestone edit", "--title", title);
        }

        const milestone_id = try command_repo.resolveMilestoneId(args[1]);
        defer allocator.free(milestone_id);
        try milestone.createMilestoneUpdatedEvent(allocator, milestone_id, update);
        return;
    }

    if (std.mem.eql(u8, args[0], "close") or std.mem.eql(u8, args[0], "reopen")) {
        if (args.len != 2) {
            try io.eprint("gt milestone {s}: expected MILESTONE\n", .{args[0]});
            return CliError.UserError;
        }
        const milestone_id = try command_repo.resolveMilestoneId(args[1]);
        defer allocator.free(milestone_id);
        const state: []const u8 = if (std.mem.eql(u8, args[0], "close")) "closed" else "open";
        try milestone.createMilestoneStringEvent(allocator, milestone_id, "milestone.state_set", "state", state);
        return;
    }

    try io.eprint("gt milestone: expected subcommand 'list', 'create', 'edit', 'close', or 'reopen'\n", .{});
    return CliError.UserError;
}
