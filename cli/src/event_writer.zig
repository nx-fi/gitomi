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
            const checked_principal = try util.checkedRefSegment(allocator, principal, "principal");
            errdefer allocator.free(checked_principal);
            const checked_device = try util.checkedRefSegment(allocator, actor_device.?, "device");
            errdefer allocator.free(checked_device);

            allocator.free(cfg.principal);
            allocator.free(cfg.device);
            cfg.principal = checked_principal;
            cfg.device = checked_device;
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
        try updateEventRef(self.allocator, self.inbox_ref, commit_oid, self.prepared_parents.old_head);
        self.allocator.free(commit_oid);
        self.staged_head = null;
    }
};

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

    try updateEventRef(allocator, inbox_ref, commit_oid, old_head);
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

    var commit_args: std.ArrayList([]const u8) = .empty;
    defer commit_args.deinit(allocator);
    try commit_args.append(allocator, "commit-tree");
    try commit_args.append(allocator, "-S");
    try commit_args.append(allocator, "-m");
    try commit_args.append(allocator, subject);
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

fn updateEventRef(allocator: Allocator, inbox_ref: []const u8, commit_oid: []const u8, old_head: ?[]const u8) !void {
    if (old_head) |head| {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, head });
        defer allocator.free(updated);
    } else {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, "" });
        defer allocator.free(updated);
    }
}
