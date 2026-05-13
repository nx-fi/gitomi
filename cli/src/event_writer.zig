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
    related_heads: [][]const u8,

    pub fn init(allocator: Allocator, command_context: []const u8) !EventWriter {
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

        const inbox_ref = try repo_mod.inboxRef(allocator, cfg);
        errdefer allocator.free(inbox_ref);

        var prepared_parents = try git.prepareEventParents(allocator, inbox_ref);
        errdefer prepared_parents.deinit();

        const related_heads = try allocator.alloc([]const u8, if (prepared_parents.old_head == null) 0 else 1);
        errdefer allocator.free(related_heads);
        if (prepared_parents.old_head) |head| related_heads[0] = head;

        return .{
            .allocator = allocator,
            .repo = repo,
            .cfg = cfg,
            .inbox_ref = inbox_ref,
            .prepared_parents = prepared_parents,
            .related_heads = related_heads,
        };
    }

    pub fn deinit(self: *EventWriter) void {
        self.allocator.free(self.related_heads);
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
            .causal = self.prepared_parents.causal_heads,
            .related = self.related_heads,
        };
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
            self.prepared_parents.causal_heads,
        );
        errdefer self.allocator.free(commit_oid);

        self.cfg.seq = committed_seq;
        try repo_mod.writeConfig(self.repo.config_path, self.cfg);
        return commit_oid;
    }
};

pub fn writeSignedEvent(
    allocator: Allocator,
    command_context: []const u8,
    inbox_ref: []const u8,
    subject: []const u8,
    event_body: []const u8,
    old_head: ?[]const u8,
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

    if (old_head) |head| {
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
    errdefer allocator.free(commit_oid);

    if (old_head) |head| {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, head });
        defer allocator.free(updated);
    } else {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, "" });
        defer allocator.free(updated);
    }

    return commit_oid;
}
