const std = @import("std");
const errors = @import("errors.zig");
const git = @import("git.zig");
const io = @import("io.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;
const gitChecked = git.gitChecked;
const gitConfigValue = git.gitConfigValue;
const sanitizeRefSegment = util.sanitizeRefSegment;
const newUuidV7 = util.newUuidV7;
const trimOwned = util.trimOwned;

const config_max_size = 128 * 1024;

pub const Repo = struct {
    allocator: Allocator,
    root: []u8,
    git_dir: []u8,
    gitomi_dir: []u8,
    config_path: []u8,
    index_path: []u8,

    pub fn deinit(self: *Repo) void {
        self.allocator.free(self.root);
        self.allocator.free(self.git_dir);
        self.allocator.free(self.gitomi_dir);
        self.allocator.free(self.config_path);
        self.allocator.free(self.index_path);
    }
};

pub const Config = struct {
    allocator: Allocator,
    repo_id: []u8,
    principal: []u8,
    device: []u8,
    seq: u64,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.repo_id);
        self.allocator.free(self.principal);
        self.allocator.free(self.device);
    }
};

pub fn discoverRepo(allocator: Allocator) !Repo {
    const root_raw = gitChecked(allocator, &.{ "rev-parse", "--show-toplevel" }) catch |err| {
        if (err == CliError.GitFailed) {
            try eprint("gt: not inside a Git repository\n", .{});
            return CliError.NotGitRepository;
        }
        return err;
    };
    const root = try trimOwned(allocator, root_raw);
    errdefer allocator.free(root);

    const git_dir_raw = gitChecked(allocator, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }) catch |err| {
        allocator.free(root);
        return err;
    };
    const git_dir = try trimOwned(allocator, git_dir_raw);
    errdefer allocator.free(git_dir);

    const gitomi_dir = try std.fs.path.join(allocator, &.{ git_dir, "gitomi" });
    errdefer allocator.free(gitomi_dir);
    const config_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "config.toml" });
    errdefer allocator.free(config_path);
    const index_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "index.sqlite" });
    errdefer allocator.free(index_path);

    return .{
        .allocator = allocator,
        .root = root,
        .git_dir = git_dir,
        .gitomi_dir = gitomi_dir,
        .config_path = config_path,
        .index_path = index_path,
    };
}

pub fn loadConfig(allocator: Allocator, path: []const u8) !Config {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, config_max_size) catch |err| switch (err) {
        error.FileNotFound => return CliError.ConfigNotFound,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseConfig(allocator, bytes);
}

pub fn parseConfig(allocator: Allocator, bytes: []const u8) !Config {
    var repo_id: ?[]u8 = null;
    var principal: ?[]u8 = null;
    var device: ?[]u8 = null;
    var seq: ?u64 = null;
    errdefer {
        if (repo_id) |v| allocator.free(v);
        if (principal) |v| allocator.free(v);
        if (device) |v| allocator.free(v);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const value = stripTomlString(raw_value) catch return CliError.ConfigInvalid;

        if (std.mem.eql(u8, key, "repo_id")) {
            if (repo_id) |old| allocator.free(old);
            repo_id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "principal")) {
            if (principal) |old| allocator.free(old);
            principal = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "device")) {
            if (device) |old| allocator.free(old);
            device = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "seq")) {
            seq = std.fmt.parseUnsigned(u64, raw_value, 10) catch return CliError.ConfigInvalid;
        }
    }

    if (repo_id == null or principal == null or device == null) {
        return CliError.ConfigInvalid;
    }

    return .{
        .allocator = allocator,
        .repo_id = repo_id.?,
        .principal = principal.?,
        .device = device.?,
        .seq = seq orelse 0,
    };
}

pub fn stripTomlString(raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

pub fn writeConfig(path: []const u8, cfg: Config) !void {
    const content = try std.fmt.allocPrint(cfg.allocator,
        \\# Gitomi repo-local configuration.
        \\repo_id = "{s}"
        \\principal = "{s}"
        \\device = "{s}"
        \\seq = {d}
        \\
    , .{ cfg.repo_id, cfg.principal, cfg.device, cfg.seq });
    defer cfg.allocator.free(content);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

pub fn inboxRef(allocator: Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "refs/gitomi/inbox/{s}/{s}", .{ cfg.principal, cfg.device });
}

pub fn defaultPrincipal(allocator: Allocator) ![]u8 {
    if (gitConfigValue(allocator, "user.email")) |value| {
        defer allocator.free(value);
        const sanitized = try sanitizeRefSegment(allocator, value);
        if (sanitized.len != 0) return sanitized;
        allocator.free(sanitized);
    } else |_| {}

    if (gitConfigValue(allocator, "user.name")) |value| {
        defer allocator.free(value);
        const sanitized = try sanitizeRefSegment(allocator, value);
        if (sanitized.len != 0) return sanitized;
        allocator.free(sanitized);
    } else |_| {}

    const id = try newUuidV7(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "principal-{s}", .{id[0..7]});
}

pub fn defaultDevice(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOSTNAME")) |value| {
        defer allocator.free(value);
        const sanitized = try sanitizeRefSegment(allocator, value);
        if (sanitized.len != 0) return sanitized;
        allocator.free(sanitized);
    } else |_| {}

    const id = try newUuidV7(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "device-{s}", .{id[0..7]});
}

test "config parser accepts minimal config" {
    var cfg = try parseConfig(std.testing.allocator,
        \\repo_id = "018f0000-0000-7000-8000-000000000001"
        \\principal = "alice"
        \\device = "laptop"
        \\seq = 42
        \\
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("018f0000-0000-7000-8000-000000000001", cfg.repo_id);
    try std.testing.expectEqualStrings("alice", cfg.principal);
    try std.testing.expectEqualStrings("laptop", cfg.device);
    try std.testing.expectEqual(@as(u64, 42), cfg.seq);
}
