const std = @import("std");
const errors = @import("errors.zig");
const git = @import("git.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;
const gitChecked = git.gitChecked;
const gitConfigValue = git.gitConfigValue;
const sanitizeRefSegment = util.sanitizeRefSegment;
const newUuidV7 = util.newUuidV7;
const sha256Hex = util.sha256Hex;
const trimOwned = util.trimOwned;
const appendJsonFieldString = json_writer.appendJsonFieldString;

const config_max_size = 128 * 1024;
pub const genesis_ref = "refs/gitomi/genesis";
pub const genesis_schema = "urn:gitomi:genesis:v1";

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
            seq = std.fmt.parseUnsigned(u64, raw_value, 10) catch null;
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

pub fn loadConfigForWrite(allocator: Allocator, repo: Repo) !Config {
    var cfg = try loadConfig(allocator, repo.config_path);
    errdefer cfg.deinit();
    try validateConfigRepoId(allocator, cfg);
    try recoverConfigSeq(allocator, &cfg);
    return cfg;
}

pub fn validateConfigRepoId(allocator: Allocator, cfg: Config) !void {
    const genesis_oid = try git.resolveOptionalRef(allocator, genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);
    const oid = genesis_oid orelse return;
    const genesis_repo_id = try genesisRepoId(allocator, oid);
    defer allocator.free(genesis_repo_id);
    if (std.mem.eql(u8, cfg.repo_id, genesis_repo_id)) return;
    try eprint("gt: config repo_id {s} does not match genesis repo_id {s}\n", .{ cfg.repo_id, genesis_repo_id });
    return CliError.ConfigInvalid;
}

pub fn recoverConfigSeq(allocator: Allocator, cfg: *Config) !void {
    const ref = try inboxRef(allocator, cfg.*);
    defer allocator.free(ref);
    const head = try git.resolveOptionalRef(allocator, ref);
    defer if (head) |oid| allocator.free(oid);
    if (head == null) return;

    const log = try git.gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", "--format=%b%x1e", ref });
    defer allocator.free(log);

    var max_seq = cfg.seq;
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const body = std.mem.trim(u8, record_raw, " \t\r\n");
        if (body.len == 0) continue;
        const seq = parseSeqForActor(allocator, body, cfg.principal, cfg.device) catch null;
        if (seq) |value| {
            if (value > max_seq) max_seq = value;
        }
    }
    cfg.seq = max_seq;
}

fn genesisRepoId(allocator: Allocator, commit: []const u8) ![]u8 {
    const spec = try std.fmt.allocPrint(allocator, "{s}:.gitomi/genesis.json", .{commit});
    defer allocator.free(spec);
    const raw = try git.gitChecked(allocator, &.{ "show", spec });
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return CliError.ConfigInvalid;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return CliError.ConfigInvalid,
    };
    const repo_id = jsonString(root.get("repo_id")) orelse return CliError.ConfigInvalid;
    if (!util.looksLikeUuid(repo_id)) return CliError.ConfigInvalid;
    return allocator.dupe(u8, repo_id);
}

fn parseSeqForActor(allocator: Allocator, body: []const u8, principal: []const u8, device: []const u8) !?u64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const actor = jsonObject(root.get("actor")) orelse return null;
    const actor_principal = jsonString(actor.get("principal")) orelse return null;
    const actor_device = jsonString(actor.get("device")) orelse return null;
    if (!std.mem.eql(u8, actor_principal, principal) or !std.mem.eql(u8, actor_device, device)) return null;
    const seq_value = root.get("seq") orelse return null;
    return switch (seq_value) {
        .integer => |seq| if (seq >= 0) @as(u64, @intCast(seq)) else null,
        else => null,
    };
}

pub fn inboxRef(allocator: Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "refs/gitomi/inbox/{s}/{s}", .{ cfg.principal, cfg.device });
}

pub fn signingPublicKey(allocator: Allocator) ![]u8 {
    const signing_key = gitConfigValue(allocator, "user.signingkey") catch return allocator.dupe(u8, "");
    defer allocator.free(signing_key);
    const trimmed = std.mem.trim(u8, signing_key, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    if (std.mem.startsWith(u8, trimmed, "ssh-")) {
        return allocator.dupe(u8, trimmed);
    }

    const pub_path = if (std.mem.endsWith(u8, trimmed, ".pub"))
        try allocator.dupe(u8, trimmed)
    else
        try std.fmt.allocPrint(allocator, "{s}.pub", .{trimmed});
    defer allocator.free(pub_path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, pub_path, 1024 * 1024) catch return allocator.dupe(u8, "");
    return trimOwned(allocator, bytes);
}

pub fn signingKeyFingerprint(allocator: Allocator, public_key: []const u8) ![]u8 {
    if (public_key.len == 0) return allocator.dupe(u8, "");
    const hash = try sha256Hex(allocator, public_key);
    defer allocator.free(hash);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hash});
}

pub fn buildGenesisManifestJson(
    allocator: Allocator,
    cfg: Config,
    public_key: []const u8,
    fingerprint: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "$schema", genesis_schema, true);
    try appendJsonFieldString(&buf, allocator, "repo_id", cfg.repo_id, true);
    try buf.appendSlice(allocator, "\"owner\":{");
    try appendJsonFieldString(&buf, allocator, "principal", cfg.principal, true);
    try appendJsonFieldString(&buf, allocator, "role", "owner", false);
    try buf.appendSlice(allocator, "},");
    try buf.appendSlice(allocator, "\"device\":{");
    try appendJsonFieldString(&buf, allocator, "principal", cfg.principal, true);
    try appendJsonFieldString(&buf, allocator, "id", cfg.device, true);
    try buf.appendSlice(allocator, "\"signing_key\":{");
    try appendJsonFieldString(&buf, allocator, "scheme", "ssh", true);
    try appendJsonFieldString(&buf, allocator, "public_key", public_key, true);
    try appendJsonFieldString(&buf, allocator, "fingerprint", fingerprint, false);
    try buf.appendSlice(allocator, "}}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn writeGenesisRef(allocator: Allocator, manifest_json: []const u8, force: bool) ![]u8 {
    const existing = try git.resolveOptionalRef(allocator, genesis_ref);
    defer if (existing) |oid| allocator.free(oid);
    if (existing != null and !force) return allocator.dupe(u8, existing.?);

    const blob_raw = try git.gitCheckedInput(allocator, &.{ "hash-object", "-w", "--stdin" }, manifest_json);
    const blob = try trimOwned(allocator, blob_raw);
    defer allocator.free(blob);

    const dir_tree_input = try std.fmt.allocPrint(allocator, "100644 blob {s}\tgenesis.json\n", .{blob});
    defer allocator.free(dir_tree_input);
    const dir_tree_raw = try git.gitCheckedInput(allocator, &.{"mktree"}, dir_tree_input);
    const dir_tree = try trimOwned(allocator, dir_tree_raw);
    defer allocator.free(dir_tree);

    const root_tree_input = try std.fmt.allocPrint(allocator, "040000 tree {s}\t.gitomi\n", .{dir_tree});
    defer allocator.free(root_tree_input);
    const root_tree_raw = try git.gitCheckedInput(allocator, &.{"mktree"}, root_tree_input);
    const root_tree = try trimOwned(allocator, root_tree_raw);
    defer allocator.free(root_tree);

    const commit_raw = git.gitChecked(allocator, &.{ "commit-tree", "-S", "-m", "gitomi genesis", "-m", manifest_json, root_tree }) catch |err| {
        if (err == CliError.GitFailed) {
            try eprint("gt init: failed to create signed genesis commit; check Git commit signing configuration\n", .{});
        }
        return err;
    };
    const commit = try trimOwned(allocator, commit_raw);
    errdefer allocator.free(commit);

    if (existing) |old| {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", genesis_ref, commit, old });
        defer allocator.free(updated);
    } else {
        const updated = try git.gitChecked(allocator, &.{ "update-ref", genesis_ref, commit, "" });
        defer allocator.free(updated);
    }
    return commit;
}

pub fn validateGenesisManifest(allocator: Allocator, commit: []const u8) !void {
    const spec = try std.fmt.allocPrint(allocator, "{s}:.gitomi/genesis.json", .{commit});
    defer allocator.free(spec);
    const raw = git.gitChecked(allocator, &.{ "show", spec }) catch |err| {
        if (err == CliError.GitFailed) try eprint("gt sync: rejecting genesis {s}: missing .gitomi/genesis.json\n", .{commit});
        return err;
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        try eprint("gt sync: rejecting genesis {s}: manifest is not valid JSON\n", .{commit});
        return CliError.UserError;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt sync: rejecting genesis {s}: manifest must be an object\n", .{commit});
            return CliError.UserError;
        },
    };

    const schema = jsonString(root.get("$schema")) orelse return invalidGenesis(commit, "$schema must be a string");
    if (!std.mem.eql(u8, schema, genesis_schema)) return invalidGenesis(commit, "$schema is not urn:gitomi:genesis:v1");
    const repo_id = jsonString(root.get("repo_id")) orelse return invalidGenesis(commit, "repo_id must be a string");
    if (!util.looksLikeUuid(repo_id)) return invalidGenesis(commit, "repo_id must be a UUID");
    const owner = jsonObject(root.get("owner")) orelse return invalidGenesis(commit, "owner must be an object");
    _ = jsonString(owner.get("principal")) orelse return invalidGenesis(commit, "owner.principal must be a string");
    const role = jsonString(owner.get("role")) orelse return invalidGenesis(commit, "owner.role must be a string");
    if (!std.mem.eql(u8, role, "owner")) return invalidGenesis(commit, "owner.role must be owner");
    const device = jsonObject(root.get("device")) orelse return invalidGenesis(commit, "device must be an object");
    _ = jsonString(device.get("principal")) orelse return invalidGenesis(commit, "device.principal must be a string");
    _ = jsonString(device.get("id")) orelse return invalidGenesis(commit, "device.id must be a string");
    const signing_key = jsonObject(device.get("signing_key")) orelse return invalidGenesis(commit, "device.signing_key must be an object");
    _ = jsonString(signing_key.get("public_key")) orelse return invalidGenesis(commit, "signing_key.public_key must be a string");
    _ = jsonString(signing_key.get("fingerprint")) orelse return invalidGenesis(commit, "signing_key.fingerprint must be a string");
}

fn invalidGenesis(commit: []const u8, message: []const u8) CliError {
    eprint("gt sync: rejecting genesis {s}: {s}\n", .{ commit, message }) catch {};
    return CliError.UserError;
}

fn jsonObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const actual = value orelse return null;
    return switch (actual) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    const string = switch (actual) {
        .string => |s| s,
        else => return null,
    };
    return if (string.len == 0) null else string;
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
