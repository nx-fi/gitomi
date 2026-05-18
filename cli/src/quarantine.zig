const std = @import("std");

const errors = @import("errors.zig");
const git = @import("git.zig");
const inbox_commit = @import("inbox_commit.zig");
const io = @import("io.zig");
const repo_mod = @import("repo.zig");
const sync = @import("sync.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

const quarantine_prefix = "refs/gitomi/quarantine/";

const QuarantineRef = struct {
    allocator: Allocator,
    ref: []u8,
    oid: []u8,
    remote: []u8,
    local_ref: []u8,
    head_prefix: []u8,

    fn deinit(self: *QuarantineRef) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
        self.allocator.free(self.remote);
        self.allocator.free(self.local_ref);
        self.allocator.free(self.head_prefix);
    }
};

const AdoptOptions = struct {
    ref: []const u8,
    replace_local: bool = false,
    keep: bool = false,
    yes: bool = false,
};

const RestoreOptions = struct {
    ref: []const u8,
    remote: ?[]const u8 = null,
    keep: bool = false,
    yes: bool = false,
};

const DropOptions = struct {
    ref: []const u8,
    yes: bool = false,
};

pub fn cmdQuarantine(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        try cmdList(allocator, if (args.len == 0) args else args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "inspect")) {
        try cmdInspect(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "adopt")) {
        try cmdAdopt(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "restore-local-to-remote")) {
        try cmdRestoreLocalToRemote(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "drop")) {
        try cmdDrop(allocator, args[1..]);
        return;
    }

    try io.eprint("gt quarantine: expected subcommand 'list', 'inspect', 'adopt', 'restore-local-to-remote', or 'drop'\n", .{});
    return CliError.UserError;
}

fn cmdList(allocator: Allocator, args: []const []const u8) !void {
    if (args.len != 0) {
        try io.eprint("gt quarantine list: unexpected argument '{s}'\n", .{args[0]});
        return CliError.UserError;
    }

    var refs = try loadQuarantineRefs(allocator);
    defer freeQuarantineRefs(allocator, &refs);

    if (refs.items.len == 0) {
        try io.out("no quarantined Gitomi inbox refs\n", .{});
        return;
    }

    for (refs.items) |*item| {
        const local_oid = try git.resolveOptionalRef(allocator, item.local_ref);
        defer if (local_oid) |oid| allocator.free(oid);
        const relation = try relationshipToLocal(allocator, local_oid, item.oid);
        try io.out("{s} {s} remote={s} local={s} status={s}\n", .{
            item.ref,
            shortOid(item.oid),
            item.remote,
            item.local_ref,
            relation,
        });
    }
}

fn cmdInspect(allocator: Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        try io.eprint("gt quarantine inspect: expected REF\n", .{});
        return CliError.UserError;
    }

    var item = try loadQuarantineRef(allocator, args[0]);
    defer item.deinit();

    const local_oid = try git.resolveOptionalRef(allocator, item.local_ref);
    defer if (local_oid) |oid| allocator.free(oid);
    const relation = try relationshipToLocal(allocator, local_oid, item.oid);

    try io.out("quarantine: {s}\n", .{item.ref});
    try io.out("head:       {s}\n", .{item.oid});
    try io.out("remote:     {s}\n", .{item.remote});
    try io.out("local_ref:  {s}\n", .{item.local_ref});
    try io.out("local_head: {s}\n", .{if (local_oid) |oid| oid else "absent"});
    try io.out("status:     {s}\n", .{relation});

    const log = try git.gitChecked(allocator, &.{
        "log",
        "--first-parent",
        "--decorate",
        "--oneline",
        "-20",
        item.ref,
    });
    defer allocator.free(log);
    if (std.mem.trim(u8, log, " \t\r\n").len != 0) {
        try io.out("\n{s}", .{log});
    }
}

fn cmdAdopt(allocator: Allocator, args: []const []const u8) !void {
    const options = try parseAdoptOptions(args);
    var item = try loadQuarantineRef(allocator, options.ref);
    defer item.deinit();

    const local_oid = try git.resolveOptionalRef(allocator, item.local_ref);
    defer if (local_oid) |oid| allocator.free(oid);

    const replaces_local = if (local_oid) |oid|
        !std.mem.eql(u8, oid, item.oid) and !(try git.isAncestor(allocator, oid, item.oid))
    else
        false;
    if (replaces_local and !options.replace_local) {
        try io.eprint("gt quarantine adopt: {s} does not fast-forward {s}; pass --replace-local to replace the local inbox head\n", .{
            item.ref,
            item.local_ref,
        });
        return CliError.UserError;
    }

    const admitted = try validateQuarantinedHead(allocator, item);
    if (!options.yes) {
        const phrase = try std.fmt.allocPrint(allocator, "adopt quarantined inbox {s}", .{item.local_ref});
        defer allocator.free(phrase);
        try requireConfirmation(allocator, "gt quarantine adopt", phrase);
    }

    if (local_oid) |oid| {
        if (!std.mem.eql(u8, oid, item.oid)) {
            const updated = try git.gitChecked(allocator, &.{ "update-ref", item.local_ref, item.oid, oid });
            defer allocator.free(updated);
        }
    } else {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", item.local_ref, item.oid, "" });
        defer allocator.free(updated);
    }

    if (!options.keep) try dropQuarantineRef(allocator, item);

    try io.out("adopted {s} into {s} ({d} event{s} validated)\n", .{
        item.ref,
        item.local_ref,
        admitted,
        if (admitted == 1) "" else "s",
    });
}

fn cmdRestoreLocalToRemote(allocator: Allocator, args: []const []const u8) !void {
    const options = try parseRestoreOptions(args);
    var item = try loadQuarantineRef(allocator, options.ref);
    defer item.deinit();

    const remote = options.remote orelse item.remote;
    const local_oid = (try git.resolveOptionalRef(allocator, item.local_ref)) orelse {
        try io.eprint("gt quarantine restore-local-to-remote: missing local inbox ref {s}\n", .{item.local_ref});
        return CliError.UserError;
    };
    defer allocator.free(local_oid);

    if (!options.yes) {
        const phrase = try std.fmt.allocPrint(allocator, "restore local inbox {s} to {s}", .{ item.local_ref, remote });
        defer allocator.free(phrase);
        try requireConfirmation(allocator, "gt quarantine restore-local-to-remote", phrase);
    }

    const lease = try std.fmt.allocPrint(allocator, "--force-with-lease={s}:{s}", .{ item.local_ref, item.oid });
    defer allocator.free(lease);
    const refspec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ item.local_ref, item.local_ref });
    defer allocator.free(refspec);
    const pushed = try git.gitChecked(allocator, &.{ "push", lease, remote, refspec });
    defer allocator.free(pushed);
    if (pushed.len != 0) try io.out("{s}", .{pushed});

    if (!options.keep) try dropQuarantineRef(allocator, item);

    try io.out("restored {s} on {s} to local head {s}\n", .{ item.local_ref, remote, local_oid });
}

fn cmdDrop(allocator: Allocator, args: []const []const u8) !void {
    const options = try parseDropOptions(args);
    var item = try loadQuarantineRef(allocator, options.ref);
    defer item.deinit();

    if (!options.yes) {
        const phrase = try std.fmt.allocPrint(allocator, "drop quarantine {s}", .{item.ref});
        defer allocator.free(phrase);
        try requireConfirmation(allocator, "gt quarantine drop", phrase);
    }

    try dropQuarantineRef(allocator, item);
    try io.out("dropped {s}\n", .{item.ref});
}

fn parseAdoptOptions(args: []const []const u8) !AdoptOptions {
    if (args.len == 0) {
        try io.eprint("gt quarantine adopt: expected REF [--replace-local] [--keep] [--yes]\n", .{});
        return CliError.UserError;
    }

    var options = AdoptOptions{ .ref = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--replace-local")) {
            options.replace_local = true;
        } else if (std.mem.eql(u8, arg, "--keep")) {
            options.keep = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.yes = true;
        } else {
            try io.eprint("gt quarantine adopt: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }
    return options;
}

fn parseRestoreOptions(args: []const []const u8) !RestoreOptions {
    if (args.len == 0) {
        try io.eprint("gt quarantine restore-local-to-remote: expected REF [--remote REMOTE] [--keep] [--yes]\n", .{});
        return CliError.UserError;
    }

    var options = RestoreOptions{ .ref = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--remote")) {
            i += 1;
            if (i >= args.len) {
                try io.eprint("gt quarantine restore-local-to-remote: --remote requires a value\n", .{});
                return CliError.UserError;
            }
            if (std.mem.trim(u8, args[i], " \t\r\n").len == 0) {
                try io.eprint("gt quarantine restore-local-to-remote: remote name is empty\n", .{});
                return CliError.UserError;
            }
            options.remote = args[i];
        } else if (std.mem.eql(u8, arg, "--keep")) {
            options.keep = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.yes = true;
        } else {
            try io.eprint("gt quarantine restore-local-to-remote: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }
    return options;
}

fn parseDropOptions(args: []const []const u8) !DropOptions {
    if (args.len == 0) {
        try io.eprint("gt quarantine drop: expected REF [--yes]\n", .{});
        return CliError.UserError;
    }

    var options = DropOptions{ .ref = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.yes = true;
        } else {
            try io.eprint("gt quarantine drop: unknown option '{s}'\n", .{arg});
            return CliError.UserError;
        }
    }
    return options;
}

fn loadQuarantineRefs(allocator: Allocator) !std.ArrayList(QuarantineRef) {
    const raw = try git.gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname)",
        quarantine_prefix,
    });
    defer allocator.free(raw);

    var refs: std.ArrayList(QuarantineRef) = .empty;
    errdefer freeQuarantineRefs(allocator, &refs);

    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = std.mem.trim(u8, line[0..tab], " \t\r\n");
        const oid = std.mem.trim(u8, line[tab + 1 ..], " \t\r\n");
        if (parseQuarantineRef(allocator, ref, oid)) |item| {
            try refs.append(allocator, item);
        } else |_| {
            continue;
        }
    }
    return refs;
}

fn loadQuarantineRef(allocator: Allocator, ref: []const u8) !QuarantineRef {
    if (!std.mem.startsWith(u8, ref, quarantine_prefix)) {
        try io.eprint("gt quarantine: {s} is not under {s}\n", .{ ref, quarantine_prefix });
        return CliError.UserError;
    }

    const oid = (try git.resolveOptionalRef(allocator, ref)) orelse {
        try io.eprint("gt quarantine: {s} does not exist\n", .{ref});
        return CliError.UserError;
    };
    defer allocator.free(oid);

    return parseQuarantineRef(allocator, ref, oid) catch |err| switch (err) {
        error.InvalidQuarantineRef => {
            try io.eprint("gt quarantine: malformed quarantine ref {s}\n", .{ref});
            return CliError.UserError;
        },
        else => return err,
    };
}

fn parseQuarantineRef(allocator: Allocator, ref: []const u8, oid: []const u8) !QuarantineRef {
    if (!std.mem.startsWith(u8, ref, quarantine_prefix)) return error.InvalidQuarantineRef;
    if (!isHexOid(oid)) return error.InvalidQuarantineRef;

    const suffix = ref[quarantine_prefix.len..];
    var fields = std.mem.splitScalar(u8, suffix, '/');
    const remote = fields.next() orelse return error.InvalidQuarantineRef;
    const inbox = fields.next() orelse return error.InvalidQuarantineRef;
    const principal = fields.next() orelse return error.InvalidQuarantineRef;
    const device = fields.next() orelse return error.InvalidQuarantineRef;
    const head_prefix = fields.next() orelse return error.InvalidQuarantineRef;
    if (fields.next() != null) return error.InvalidQuarantineRef;
    if (remote.len == 0 or principal.len == 0 or device.len == 0 or head_prefix.len == 0) return error.InvalidQuarantineRef;
    if (!std.mem.eql(u8, inbox, "inbox")) return error.InvalidQuarantineRef;
    if (!std.mem.startsWith(u8, oid, head_prefix)) return error.InvalidQuarantineRef;

    const local_ref = try std.fmt.allocPrint(allocator, "refs/gitomi/inbox/{s}/{s}", .{ principal, device });
    errdefer allocator.free(local_ref);
    if (inbox_commit.parseRefIdentity(local_ref) == null) return error.InvalidQuarantineRef;

    const ref_copy = try allocator.dupe(u8, ref);
    errdefer allocator.free(ref_copy);
    const oid_copy = try allocator.dupe(u8, oid);
    errdefer allocator.free(oid_copy);
    const remote_copy = try allocator.dupe(u8, remote);
    errdefer allocator.free(remote_copy);
    const head_prefix_copy = try allocator.dupe(u8, head_prefix);
    errdefer allocator.free(head_prefix_copy);

    return .{
        .allocator = allocator,
        .ref = ref_copy,
        .oid = oid_copy,
        .remote = remote_copy,
        .local_ref = local_ref,
        .head_prefix = head_prefix_copy,
    };
}

fn freeQuarantineRefs(allocator: Allocator, refs: *std.ArrayList(QuarantineRef)) void {
    for (refs.items) |*ref| ref.deinit();
    refs.deinit(allocator);
}

fn relationshipToLocal(allocator: Allocator, local_oid: ?[]const u8, quarantine_oid: []const u8) ![]const u8 {
    const local = local_oid orelse return "local-absent";
    if (std.mem.eql(u8, local, quarantine_oid)) return "same-as-local";
    if (try git.isAncestor(allocator, local, quarantine_oid)) return "quarantine-fast-forwards-local";
    if (try git.isAncestor(allocator, quarantine_oid, local)) return "local-ahead";
    return "diverged";
}

fn validateQuarantinedHead(allocator: Allocator, item: QuarantineRef) !usize {
    const genesis_oid = (try git.resolveOptionalRef(allocator, repo_mod.genesis_ref)) orelse {
        try io.eprint("gt quarantine adopt: refusing to adopt without {s}\n", .{repo_mod.genesis_ref});
        return CliError.UserError;
    };
    defer allocator.free(genesis_oid);

    const expected_repo_id = try expectedRepoIdForAdmission(allocator, genesis_oid);
    defer allocator.free(expected_repo_id);

    const empty_tree = try git.emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    return sync.validateInboxRange(allocator, item.ref, item.local_ref, null, empty_tree, genesis_oid, expected_repo_id);
}

fn expectedRepoIdForAdmission(allocator: Allocator, genesis_oid: []const u8) ![]u8 {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            var manifest = try repo_mod.loadGenesisManifest(allocator, genesis_oid);
            defer manifest.deinit();
            return try allocator.dupe(u8, manifest.repo_id);
        },
        CliError.ConfigInvalid => {
            try io.eprint("gt quarantine: invalid Gitomi config; run `gt init` or fix .git/gitomi/config.toml\n", .{});
            return err;
        },
        else => return err,
    };
    defer cfg.deinit();

    try repo_mod.validateConfigRepoId(allocator, cfg);
    return try allocator.dupe(u8, cfg.repo_id);
}

fn dropQuarantineRef(allocator: Allocator, item: QuarantineRef) !void {
    const deleted = try git.gitChecked(allocator, &.{ "update-ref", "-d", item.ref, item.oid });
    defer allocator.free(deleted);
}

fn shortOid(oid: []const u8) []const u8 {
    return oid[0..@min(oid.len, 12)];
}

fn isHexOid(value: []const u8) bool {
    if (value.len < 4) return false;
    for (value) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}

fn requireConfirmation(allocator: Allocator, command_name: []const u8, phrase: []const u8) !void {
    try io.out("Type '{s}' to continue: ", .{phrase});
    const answer = try readStdinLine(allocator, 1024);
    defer allocator.free(answer);

    if (!std.mem.eql(u8, std.mem.trim(u8, answer, " \t\r\n"), phrase)) {
        try io.eprint("{s}: aborted\n", .{command_name});
        return CliError.UserError;
    }
}

fn readStdinLine(allocator: Allocator, max_bytes: usize) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);

    const stdin = std.fs.File.stdin();
    var byte: [1]u8 = undefined;
    while (true) {
        const read_len = try stdin.read(&byte);
        if (read_len == 0 or byte[0] == '\n') break;
        if (line.items.len >= max_bytes) {
            try io.eprint("confirmation input is too long\n", .{});
            return CliError.UserError;
        }
        if (byte[0] != '\r') try line.append(allocator, byte[0]);
    }

    return try line.toOwnedSlice(allocator);
}

test "quarantine ref parsing maps to authoritative inbox" {
    var item = try parseQuarantineRef(
        std.testing.allocator,
        "refs/gitomi/quarantine/origin/inbox/alice/laptop/abcdef123456",
        "abcdef1234567890abcdef1234567890abcdef12",
    );
    defer item.deinit();

    try std.testing.expectEqualStrings("origin", item.remote);
    try std.testing.expectEqualStrings("refs/gitomi/inbox/alice/laptop", item.local_ref);
    try std.testing.expectEqualStrings("abcdef123456", item.head_prefix);
}

test "quarantine ref parser rejects malformed refs" {
    try std.testing.expectError(
        error.InvalidQuarantineRef,
        parseQuarantineRef(
            std.testing.allocator,
            "refs/gitomi/quarantine/origin/inbox/alice/laptop/extra/abcdef123456",
            "abcdef1234567890abcdef1234567890abcdef12",
        ),
    );
    try std.testing.expectError(
        error.InvalidQuarantineRef,
        parseQuarantineRef(
            std.testing.allocator,
            "refs/gitomi/quarantine/origin/inbox/alice/laptop/123456abcdef",
            "abcdef1234567890abcdef1234567890abcdef12",
        ),
    );
}

test "hex oid validation accepts sha1 and sha256 shaped values" {
    try std.testing.expect(isHexOid("abcdef1234567890abcdef1234567890abcdef12"));
    try std.testing.expect(isHexOid("abcdef1234567890abcdef1234567890abcdef12abcdef1234567890abcdef12"));
    try std.testing.expect(!isHexOid("not-an-oid"));
}
