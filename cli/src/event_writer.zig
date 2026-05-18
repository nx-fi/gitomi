const std = @import("std");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;

pub const EventWriter = struct {
    allocator: Allocator,
    repo: repo_mod.Repo,
    cfg: repo_mod.Config,
    inbox_ref: []u8,
    prepared_parents: git.PreparedEventParents,
    related_heads: [][]u8,
    staged_head: ?[]u8 = null,
    persist_config: bool,

    pub fn init(allocator: Allocator, command_context: []const u8) !EventWriter {
        return initInternal(allocator, command_context, null, null, null, null, true);
    }

    pub fn initForActor(allocator: Allocator, command_context: []const u8, principal: []const u8, device: []const u8) !EventWriter {
        return initInternal(allocator, command_context, principal, device, null, null, false);
    }

    pub fn initForInboxRef(allocator: Allocator, command_context: []const u8, principal: []const u8, device: []const u8) !EventWriter {
        return initInternal(allocator, command_context, null, null, principal, device, true);
    }

    fn initInternal(
        allocator: Allocator,
        command_context: []const u8,
        actor_principal: ?[]const u8,
        actor_device: ?[]const u8,
        inbox_principal: ?[]const u8,
        inbox_device: ?[]const u8,
        persist_config: bool,
    ) !EventWriter {
        var repo = try repo_mod.discoverRepo(allocator);
        errdefer repo.deinit();

        var cfg = repo_mod.loadConfigForWrite(allocator, repo) catch |err| switch (err) {
            CliError.ConfigNotFound => {
                try eprint("{s}: Gitomi is not initialized; run `gt init`\n", .{command_context});
                return CliError.UserError;
            },
            else => return err,
        };
        errdefer cfg.deinit();

        if (actor_principal) |principal| {
            var checked_principal: ?[]u8 = try util.checkedRefSegment(allocator, principal, "principal");
            errdefer if (checked_principal) |value| allocator.free(value);
            var checked_device: ?[]u8 = try util.checkedRefSegment(allocator, actor_device.?, "device");
            errdefer if (checked_device) |value| allocator.free(value);

            allocator.free(cfg.principal);
            allocator.free(cfg.device);
            cfg.principal = checked_principal.?;
            cfg.device = checked_device.?;
            checked_principal = null;
            checked_device = null;
            cfg.seq = 0;
            try repo_mod.recoverConfigSeq(allocator, &cfg);
        }

        const inbox_ref = if (inbox_principal) |principal| blk: {
            const checked_principal = try util.checkedRefSegment(allocator, principal, "principal");
            defer allocator.free(checked_principal);
            const checked_device = try util.checkedRefSegment(allocator, inbox_device.?, "device");
            defer allocator.free(checked_device);
            break :blk try std.fmt.allocPrint(allocator, "refs/gitomi/inbox/{s}/{s}", .{ checked_principal, checked_device });
        } else try repo_mod.inboxRef(allocator, cfg);
        errdefer allocator.free(inbox_ref);
        if (inbox_principal != null) {
            try repo_mod.recoverConfigSeqFromInboxRef(allocator, &cfg, inbox_ref);
        }

        const genesis_oid = (try git.resolveOptionalRef(allocator, repo_mod.genesis_ref)) orelse {
            try eprint("{s}: Gitomi genesis ref is missing; run `gt init` or `gt sync`\n", .{command_context});
            return CliError.UserError;
        };
        defer allocator.free(genesis_oid);

        var prepared_parents = try git.prepareEventParents(allocator, inbox_ref, genesis_oid);
        errdefer prepared_parents.deinit();

        const related_heads = try buildRelatedHeads(allocator, repo, cfg, prepared_parents.old_head);
        errdefer git.freeStringList(allocator, related_heads);

        return .{
            .allocator = allocator,
            .repo = repo,
            .cfg = cfg,
            .inbox_ref = inbox_ref,
            .prepared_parents = prepared_parents,
            .related_heads = related_heads,
            .persist_config = persist_config,
        };
    }

    pub fn deinit(self: *EventWriter) void {
        if (self.staged_head) |head| self.allocator.free(head);
        git.freeStringList(self.allocator, self.related_heads);
        self.prepared_parents.deinit();
        self.allocator.free(self.inbox_ref);
        self.cfg.deinit();
        self.repo.deinit();
    }

    pub fn nextSeq(self: *const EventWriter) u64 {
        return self.cfg.seq + 1;
    }

    pub fn eventParents(self: *const EventWriter) event_mod.EventParents {
        return .{
            .log = self.prepared_parents.old_head,
            .anchor = self.prepared_parents.anchor,
            .causal = self.prepared_parents.causal_heads,
            .related = self.related_heads,
        };
    }

    pub fn stagedEventParents(self: *const EventWriter) event_mod.EventParents {
        if (self.staged_head) |head| {
            return .{
                .log = head,
                .anchor = null,
                .causal = &.{},
                .related = self.related_heads,
            };
        }
        return self.eventParents();
    }

    pub fn write(self: *EventWriter, command_context: []const u8, subject: []const u8, event_body: []const u8) ![]u8 {
        const committed_seq = self.nextSeq();
        try self.ensureEventFresh(command_context, event_body);
        try index.requireAuthorizedWrite(self.allocator, self.repo, event_body);
        const commit_oid = try writeSignedEvent(
            self.allocator,
            command_context,
            self.inbox_ref,
            subject,
            event_body,
            self.prepared_parents.old_head,
            self.prepared_parents.anchor,
            self.prepared_parents.causal_heads,
        );
        errdefer self.allocator.free(commit_oid);

        self.cfg.seq = committed_seq;
        if (self.persist_config) {
            try repo_mod.writeConfig(self.repo.config_path, self.cfg);
        }
        return commit_oid;
    }

    pub fn stage(self: *EventWriter, command_context: []const u8, subject: []const u8, event_body: []const u8) ![]u8 {
        const committed_seq = self.nextSeq();
        try self.ensureEventFresh(command_context, event_body);
        try index.requireAuthorizedWrite(self.allocator, self.repo, event_body);

        const parent_head = self.staged_head orelse self.prepared_parents.old_head;
        const anchor = if (self.staged_head == null) self.prepared_parents.anchor else null;
        const causal_heads = if (self.staged_head == null) self.prepared_parents.causal_heads else &.{};
        const commit_oid = try createSignedEventCommit(
            self.allocator,
            command_context,
            subject,
            event_body,
            parent_head,
            anchor,
            causal_heads,
        );
        errdefer self.allocator.free(commit_oid);

        const returned_oid = try self.allocator.dupe(u8, commit_oid);
        errdefer self.allocator.free(returned_oid);

        if (self.staged_head) |old_staged_head| self.allocator.free(old_staged_head);
        self.staged_head = commit_oid;
        self.cfg.seq = committed_seq;
        return returned_oid;
    }

    pub fn commitStaged(self: *EventWriter) !void {
        const commit_oid = self.staged_head orelse return;
        try self.ensureInboxHeadUnchanged("gt");
        try updateEventRef(self.allocator, "gt", self.inbox_ref, commit_oid, self.prepared_parents.old_head);
        if (self.persist_config) {
            try repo_mod.writeConfig(self.repo.config_path, self.cfg);
        }
        self.allocator.free(commit_oid);
        self.staged_head = null;
    }

    fn ensureEventFresh(self: *EventWriter, command_context: []const u8, event_body: []const u8) !void {
        var envelope = event_mod.parseValidatedEnvelope(self.allocator, event_body) catch {
            try eprint("{s}: refusing to write invalid event body\n", .{command_context});
            return CliError.InvalidEvent;
        };
        defer envelope.deinit();

        if (!std.mem.eql(u8, envelope.actor_principal, self.cfg.principal) or
            !std.mem.eql(u8, envelope.actor_device, self.cfg.device))
        {
            try eprint(
                "{s}: refusing to write event for actor {s}/{s} through inbox {s}/{s}\n",
                .{ command_context, envelope.actor_principal, envelope.actor_device, self.cfg.principal, self.cfg.device },
            );
            return CliError.UserError;
        }

        const expected_seq = self.nextSeq();
        if (envelope.seq < 0 or @as(u64, @intCast(envelope.seq)) != expected_seq) {
            try eprint(
                "{s}: refusing duplicate or stale event for {s}/{s}: event sequence {d} is not the next local sequence {d}\n",
                .{ command_context, self.cfg.principal, self.cfg.device, envelope.seq, expected_seq },
            );
            return CliError.LocalInboxChanged;
        }

        try self.ensureInboxHeadUnchanged(command_context);
    }

    fn ensureInboxHeadUnchanged(self: *EventWriter, command_context: []const u8) !void {
        if (try inboxHeadMatches(self.allocator, self.inbox_ref, self.prepared_parents.old_head)) return;
        try eprint(
            "{s}: local inbox {s} changed while creating an event; reload the page or rerun the command so Gitomi can choose the next sequence\n",
            .{ command_context, self.inbox_ref },
        );
        return CliError.LocalInboxChanged;
    }
};

fn normalizeEventSubject(allocator: Allocator, subject: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var pending_space = false;
    for (subject) |c| {
        if (std.ascii.isWhitespace(c)) {
            pending_space = normalized.items.len != 0;
            continue;
        }

        if (pending_space) {
            if (normalized.items.len + 2 > git.max_event_subject_bytes) break;
            try normalized.append(allocator, ' ');
            pending_space = false;
        }

        if (normalized.items.len == git.max_event_subject_bytes) break;
        try normalized.append(allocator, c);
    }

    return normalized.toOwnedSlice(allocator);
}

fn validateEventSubject(command_context: []const u8, subject: []const u8) !void {
    if (subject.len > git.max_event_subject_bytes) {
        try eprint("{s}: event subject exceeds v1 subject size limit\n", .{command_context});
        return CliError.UserError;
    }
    if (std.mem.indexOfScalar(u8, subject, '\r') != null or std.mem.indexOfScalar(u8, subject, '\n') != null) {
        try eprint("{s}: event subject must be a single line\n", .{command_context});
        return CliError.UserError;
    }
}

test "event subject normalization removes body-polluting line breaks" {
    const normalized = try normalizeEventSubject(std.testing.allocator, "issue.body_set #1234567 first paragraph\n\nsecond paragraph");
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("issue.body_set #1234567 first paragraph second paragraph", normalized);
    try validateEventSubject("test", normalized);
    try std.testing.expectError(CliError.UserError, validateEventSubject("test", "issue.body_set #1234567\n\nbad"));
}

test "event subject normalization enforces subject size limit" {
    var raw: [git.max_event_subject_bytes + 32]u8 = undefined;
    @memset(&raw, 'x');

    const normalized = try normalizeEventSubject(std.testing.allocator, &raw);
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqual(@as(usize, git.max_event_subject_bytes), normalized.len);
    try validateEventSubject("test", normalized);
}

fn buildRelatedHeads(
    allocator: Allocator,
    repo: repo_mod.Repo,
    cfg: repo_mod.Config,
    old_head: ?[]const u8,
) ![][]u8 {
    var related: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, related.items);

    if (old_head) |head| {
        try appendUniqueOwned(allocator, &related, head);
    }

    const auth_heads = try index.authRelatedEventHashes(allocator, repo, cfg.principal, cfg.device);
    defer git.freeStringList(allocator, auth_heads);
    for (auth_heads) |head| {
        try appendUniqueOwned(allocator, &related, head);
    }

    return related.toOwnedSlice(allocator);
}

fn appendUniqueOwned(allocator: Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    if (value.len == 0) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

pub fn writeSignedEvent(
    allocator: Allocator,
    command_context: []const u8,
    inbox_ref: []const u8,
    subject: []const u8,
    event_body: []const u8,
    old_head: ?[]const u8,
    anchor: ?[]const u8,
    causal_heads: []const []const u8,
) ![]u8 {
    const commit_oid = try createSignedEventCommit(
        allocator,
        command_context,
        subject,
        event_body,
        old_head,
        anchor,
        causal_heads,
    );
    errdefer allocator.free(commit_oid);

    try updateEventRef(allocator, command_context, inbox_ref, commit_oid, old_head);
    return commit_oid;
}

fn createSignedEventCommit(
    allocator: Allocator,
    command_context: []const u8,
    subject: []const u8,
    event_body: []const u8,
    old_head: ?[]const u8,
    anchor: ?[]const u8,
    causal_heads: []const []const u8,
) ![]u8 {
    const empty_tree = try git.emptyTreeOid(allocator);
    defer allocator.free(empty_tree);
    const event_subject = try normalizeEventSubject(allocator, subject);
    defer allocator.free(event_subject);
    try validateEventSubject(command_context, event_subject);

    var commit_args: std.ArrayList([]const u8) = .empty;
    defer commit_args.deinit(allocator);
    try commit_args.append(allocator, "commit-tree");
    try commit_args.append(allocator, "-S");
    try commit_args.append(allocator, "-m");
    try commit_args.append(allocator, event_subject);
    try commit_args.append(allocator, "-m");
    try commit_args.append(allocator, event_body);
    try commit_args.append(allocator, empty_tree);

    const first_parent: ?[]const u8 = if (old_head) |head| head else anchor;
    if (first_parent) |head| {
        try commit_args.append(allocator, "-p");
        try commit_args.append(allocator, head);
        for (causal_heads) |known_head| {
            try commit_args.append(allocator, "-p");
            try commit_args.append(allocator, known_head);
        }
    }

    const commit_raw = git.gitChecked(allocator, commit_args.items) catch |err| {
        if (err == CliError.GitFailed) {
            try eprint("{s}: failed to create signed event commit; check Git commit signing configuration\n", .{command_context});
        }
        return err;
    };
    const commit_oid = try util.trimOwned(allocator, commit_raw);
    return commit_oid;
}

fn updateEventRef(allocator: Allocator, command_context: []const u8, inbox_ref: []const u8, commit_oid: []const u8, old_head: ?[]const u8) !void {
    const expected = old_head orelse "";
    var result = try git.runCommand(allocator, &.{ "git", "update-ref", inbox_ref, commit_oid, expected }, null, git.max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) return;

    if (!(try inboxHeadMatches(allocator, inbox_ref, old_head))) {
        try eprint(
            "{s}: local inbox {s} changed while creating an event; duplicate submission was blocked, reload the page or rerun the command\n",
            .{ command_context, inbox_ref },
        );
        return CliError.LocalInboxChanged;
    }

    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try eprint("git update-ref failed: {s}\n", .{stderr});
    } else {
        try eprint("git update-ref failed\n", .{});
    }
    return CliError.GitFailed;
}

fn inboxHeadMatches(allocator: Allocator, inbox_ref: []const u8, expected_head: ?[]const u8) !bool {
    const current = try git.resolveOptionalRef(allocator, inbox_ref);
    defer if (current) |head| allocator.free(head);
    return optionalHashEqual(current, expected_head);
}

fn optionalHashEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        if (right) |right_value| return std.mem.eql(u8, left_value, right_value);
        return false;
    }
    return right == null;
}
