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
    cursors_path: []u8,

    pub fn deinit(self: *Repo) void {
        self.allocator.free(self.root);
        self.allocator.free(self.git_dir);
        self.allocator.free(self.gitomi_dir);
        self.allocator.free(self.config_path);
        self.allocator.free(self.index_path);
        self.allocator.free(self.cursors_path);
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

pub const GenesisManifest = struct {
    allocator: Allocator,
    repo_id: []u8,
    owner_principal: []u8,
    owner_role: []u8,
    device_principal: []u8,
    device_id: []u8,
    public_key: []u8,
    fingerprint: []u8,

    pub fn deinit(self: *GenesisManifest) void {
        self.allocator.free(self.repo_id);
        self.allocator.free(self.owner_principal);
        self.allocator.free(self.owner_role);
        self.allocator.free(self.device_principal);
        self.allocator.free(self.device_id);
        self.allocator.free(self.public_key);
        self.allocator.free(self.fingerprint);
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
    const cursors_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "cursors.sqlite" });
    errdefer allocator.free(cursors_path);

    return .{
        .allocator = allocator,
        .root = root,
        .git_dir = git_dir,
        .gitomi_dir = gitomi_dir,
        .config_path = config_path,
        .index_path = index_path,
        .cursors_path = cursors_path,
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

    var parser = ConfigParser{
        .allocator = allocator,
        .bytes = bytes,
    };
    while (try parser.next()) |entry| {
        const value = entry.value.bytes;
        var moved = false;
        defer if (!moved) allocator.free(value);

        if (std.mem.eql(u8, entry.key, "repo_id")) {
            if (repo_id) |old| allocator.free(old);
            repo_id = value;
            moved = true;
        } else if (std.mem.eql(u8, entry.key, "principal")) {
            if (principal) |old| allocator.free(old);
            principal = value;
            moved = true;
        } else if (std.mem.eql(u8, entry.key, "device")) {
            if (device) |old| allocator.free(old);
            device = value;
            moved = true;
        } else if (std.mem.eql(u8, entry.key, "seq")) {
            if (entry.value.kind != .bare) return CliError.ConfigInvalid;
            seq = std.fmt.parseUnsigned(u64, value, 10) catch return CliError.ConfigInvalid;
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

const TomlValueKind = enum { string, bare };

const ParsedTomlValue = struct {
    bytes: []u8,
    kind: TomlValueKind,
};

const ConfigEntry = struct {
    key: []const u8,
    value: ParsedTomlValue,
};

const ConfigParser = struct {
    allocator: Allocator,
    bytes: []const u8,
    pos: usize = 0,

    fn next(self: *ConfigParser) !?ConfigEntry {
        self.skipTrivia();
        if (self.pos >= self.bytes.len) return null;

        const key_start = self.pos;
        while (self.pos < self.bytes.len and isTomlBareKeyChar(self.bytes[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == key_start) return CliError.ConfigInvalid;
        const key = self.bytes[key_start..self.pos];

        self.skipHorizontalWhitespace();
        if (self.pos >= self.bytes.len or self.bytes[self.pos] != '=') return CliError.ConfigInvalid;
        self.pos += 1;
        self.skipHorizontalWhitespace();

        const value = try self.parseValue();
        errdefer self.allocator.free(value.bytes);

        self.skipHorizontalWhitespace();
        if (self.pos < self.bytes.len) {
            if (self.bytes[self.pos] == '#') {
                self.skipRestOfLine();
            } else if (!self.consumeNewline()) {
                return CliError.ConfigInvalid;
            }
        }

        return .{ .key = key, .value = value };
    }

    fn parseValue(self: *ConfigParser) !ParsedTomlValue {
        if (self.pos >= self.bytes.len) return CliError.ConfigInvalid;
        if (self.startsWith("\"\"\"")) return .{ .bytes = try self.parseBasicString(true), .kind = .string };
        if (self.startsWith("'''")) return .{ .bytes = try self.parseLiteralString(true), .kind = .string };
        if (self.bytes[self.pos] == '"') return .{ .bytes = try self.parseBasicString(false), .kind = .string };
        if (self.bytes[self.pos] == '\'') return .{ .bytes = try self.parseLiteralString(false), .kind = .string };
        return .{ .bytes = try self.parseBareValue(), .kind = .bare };
    }

    fn parseBareValue(self: *ConfigParser) ![]u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and self.bytes[self.pos] != '#' and self.bytes[self.pos] != '\r' and self.bytes[self.pos] != '\n') {
            self.pos += 1;
        }
        const value = std.mem.trim(u8, self.bytes[start..self.pos], " \t");
        if (value.len == 0) return CliError.ConfigInvalid;
        return self.allocator.dupe(u8, value);
    }

    fn parseBasicString(self: *ConfigParser, multiline: bool) ![]u8 {
        self.pos += if (multiline) 3 else 1;
        if (multiline) _ = self.consumeNewline();

        var out_buf: std.ArrayList(u8) = .empty;
        errdefer out_buf.deinit(self.allocator);

        while (self.pos < self.bytes.len) {
            if (multiline) {
                if (self.startsWith("\"\"\"")) {
                    self.pos += 3;
                    return out_buf.toOwnedSlice(self.allocator);
                }
            } else if (self.bytes[self.pos] == '"') {
                self.pos += 1;
                return out_buf.toOwnedSlice(self.allocator);
            } else if (self.bytes[self.pos] == '\r' or self.bytes[self.pos] == '\n') {
                return CliError.ConfigInvalid;
            }

            if (self.bytes[self.pos] == '\\') {
                try self.appendBasicEscape(&out_buf, multiline);
            } else {
                try out_buf.append(self.allocator, self.bytes[self.pos]);
                self.pos += 1;
            }
        }

        return CliError.ConfigInvalid;
    }

    fn appendBasicEscape(self: *ConfigParser, out_buf: *std.ArrayList(u8), multiline: bool) !void {
        self.pos += 1;
        if (self.pos >= self.bytes.len) return CliError.ConfigInvalid;

        const escaped = self.bytes[self.pos];
        switch (escaped) {
            'b' => try out_buf.append(self.allocator, 0x08),
            't' => try out_buf.append(self.allocator, '\t'),
            'n' => try out_buf.append(self.allocator, '\n'),
            'f' => try out_buf.append(self.allocator, 0x0c),
            'r' => try out_buf.append(self.allocator, '\r'),
            '"' => try out_buf.append(self.allocator, '"'),
            '\\' => try out_buf.append(self.allocator, '\\'),
            'u' => {
                try self.appendUnicodeEscape(out_buf, 4);
                return;
            },
            'U' => {
                try self.appendUnicodeEscape(out_buf, 8);
                return;
            },
            '\r', '\n' => {
                if (!multiline) return CliError.ConfigInvalid;
                _ = self.consumeNewline();
                self.skipMultilineContinuationWhitespace();
                return;
            },
            else => return CliError.ConfigInvalid,
        }
        self.pos += 1;
    }

    fn appendUnicodeEscape(self: *ConfigParser, out_buf: *std.ArrayList(u8), digits: usize) !void {
        if (self.pos + 1 + digits > self.bytes.len) return CliError.ConfigInvalid;
        var codepoint: u32 = 0;
        for (self.bytes[self.pos + 1 .. self.pos + 1 + digits]) |c| {
            const digit = std.fmt.charToDigit(c, 16) catch return CliError.ConfigInvalid;
            codepoint = codepoint * 16 + digit;
        }

        if (codepoint > std.math.maxInt(u21)) return CliError.ConfigInvalid;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@as(u21, @intCast(codepoint)), &encoded) catch return CliError.ConfigInvalid;
        try out_buf.appendSlice(self.allocator, encoded[0..len]);
        self.pos += 1 + digits;
    }

    fn parseLiteralString(self: *ConfigParser, multiline: bool) ![]u8 {
        self.pos += if (multiline) 3 else 1;
        if (multiline) _ = self.consumeNewline();
        const start = self.pos;

        while (self.pos < self.bytes.len) {
            if (multiline) {
                if (self.startsWith("'''")) {
                    const value = self.bytes[start..self.pos];
                    self.pos += 3;
                    return self.allocator.dupe(u8, value);
                }
            } else if (self.bytes[self.pos] == '\'') {
                const value = self.bytes[start..self.pos];
                self.pos += 1;
                return self.allocator.dupe(u8, value);
            } else if (self.bytes[self.pos] == '\r' or self.bytes[self.pos] == '\n') {
                return CliError.ConfigInvalid;
            }
            self.pos += 1;
        }

        return CliError.ConfigInvalid;
    }

    fn startsWith(self: *const ConfigParser, needle: []const u8) bool {
        return self.pos + needle.len <= self.bytes.len and std.mem.eql(u8, self.bytes[self.pos .. self.pos + needle.len], needle);
    }

    fn skipTrivia(self: *ConfigParser) void {
        while (self.pos < self.bytes.len) {
            self.skipHorizontalWhitespace();
            if (self.pos >= self.bytes.len) return;
            if (self.bytes[self.pos] == '#') {
                self.skipRestOfLine();
            } else if (!self.consumeNewline()) {
                return;
            }
        }
    }

    fn skipHorizontalWhitespace(self: *ConfigParser) void {
        while (self.pos < self.bytes.len and (self.bytes[self.pos] == ' ' or self.bytes[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipRestOfLine(self: *ConfigParser) void {
        while (self.pos < self.bytes.len and self.bytes[self.pos] != '\r' and self.bytes[self.pos] != '\n') {
            self.pos += 1;
        }
        _ = self.consumeNewline();
    }

    fn consumeNewline(self: *ConfigParser) bool {
        if (self.pos >= self.bytes.len) return false;
        if (self.bytes[self.pos] == '\n') {
            self.pos += 1;
            return true;
        }
        if (self.bytes[self.pos] == '\r') {
            self.pos += 1;
            if (self.pos < self.bytes.len and self.bytes[self.pos] == '\n') self.pos += 1;
            return true;
        }
        return false;
    }

    fn skipMultilineContinuationWhitespace(self: *ConfigParser) void {
        while (self.pos < self.bytes.len) {
            if (self.bytes[self.pos] == ' ' or self.bytes[self.pos] == '\t') {
                self.pos += 1;
            } else if (!self.consumeNewline()) {
                return;
            }
        }
    }
};

fn isTomlBareKeyChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-' or c == '.';
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

    var max_seq: u64 = 0;
    var found = false;
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const body = std.mem.trim(u8, record_raw, " \t\r\n");
        if (body.len == 0) continue;
        const seq = parseSeqForActor(allocator, body, cfg.principal, cfg.device) catch null;
        if (seq) |value| {
            found = true;
            if (value > max_seq) max_seq = value;
        }
    }
    if (found) cfg.seq = max_seq;
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
    const trimmed = std.mem.trim(u8, public_key, " \t\r\n");
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    _ = fields.next() orelse return error.InvalidSigningPublicKey;
    const encoded_key = fields.next() orelse return error.InvalidSigningPublicKey;

    const decoder = if (std.mem.indexOfScalar(u8, encoded_key, '=') == null)
        std.base64.standard_no_pad.Decoder
    else
        std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded_key);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try decoder.decode(decoded, encoded_key);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded, &digest, .{});

    const prefix = "SHA256:";
    const encoded_len = std.base64.standard_no_pad.Encoder.calcSize(digest.len);
    const fingerprint = try allocator.alloc(u8, prefix.len + encoded_len);
    @memcpy(fingerprint[0..prefix.len], prefix);
    _ = std.base64.standard_no_pad.Encoder.encode(fingerprint[prefix.len..], digest[0..]);
    return fingerprint;
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
    var manifest = try loadGenesisManifest(allocator, commit);
    defer manifest.deinit();
}

pub fn loadGenesisManifest(allocator: Allocator, commit: []const u8) !GenesisManifest {
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
    const owner_principal = jsonString(owner.get("principal")) orelse return invalidGenesis(commit, "owner.principal must be a string");
    const role = jsonString(owner.get("role")) orelse return invalidGenesis(commit, "owner.role must be a string");
    if (!std.mem.eql(u8, role, "owner")) return invalidGenesis(commit, "owner.role must be owner");
    const device = jsonObject(root.get("device")) orelse return invalidGenesis(commit, "device must be an object");
    const device_principal = jsonString(device.get("principal")) orelse return invalidGenesis(commit, "device.principal must be a string");
    const device_id = jsonString(device.get("id")) orelse return invalidGenesis(commit, "device.id must be a string");
    const signing_key = jsonObject(device.get("signing_key")) orelse return invalidGenesis(commit, "device.signing_key must be an object");
    const public_key = jsonString(signing_key.get("public_key")) orelse return invalidGenesis(commit, "signing_key.public_key must be a string");
    const fingerprint = jsonString(signing_key.get("fingerprint")) orelse return invalidGenesis(commit, "signing_key.fingerprint must be a string");

    var repo_id_owned: ?[]u8 = try allocator.dupe(u8, repo_id);
    errdefer if (repo_id_owned) |value| allocator.free(value);
    var owner_principal_owned: ?[]u8 = try allocator.dupe(u8, owner_principal);
    errdefer if (owner_principal_owned) |value| allocator.free(value);
    var owner_role_owned: ?[]u8 = try allocator.dupe(u8, role);
    errdefer if (owner_role_owned) |value| allocator.free(value);
    var device_principal_owned: ?[]u8 = try allocator.dupe(u8, device_principal);
    errdefer if (device_principal_owned) |value| allocator.free(value);
    var device_id_owned: ?[]u8 = try allocator.dupe(u8, device_id);
    errdefer if (device_id_owned) |value| allocator.free(value);
    var public_key_owned: ?[]u8 = try allocator.dupe(u8, public_key);
    errdefer if (public_key_owned) |value| allocator.free(value);
    var fingerprint_owned: ?[]u8 = try allocator.dupe(u8, fingerprint);
    errdefer if (fingerprint_owned) |value| allocator.free(value);

    const manifest = GenesisManifest{
        .allocator = allocator,
        .repo_id = repo_id_owned.?,
        .owner_principal = owner_principal_owned.?,
        .owner_role = owner_role_owned.?,
        .device_principal = device_principal_owned.?,
        .device_id = device_id_owned.?,
        .public_key = public_key_owned.?,
        .fingerprint = fingerprint_owned.?,
    };
    repo_id_owned = null;
    owner_principal_owned = null;
    owner_role_owned = null;
    device_principal_owned = null;
    device_id_owned = null;
    public_key_owned = null;
    fingerprint_owned = null;
    return manifest;
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

test "config parser accepts inline comments and escaped strings" {
    var cfg = try parseConfig(std.testing.allocator,
        \\# local edits should not break config loading
        \\repo_id = "018f0000-0000-7000-8000-000000000001" # generated id
        \\principal = "alice\nops"
        \\device = "lap\u0074op" # escaped t
        \\seq = 43 # recovered after writes
        \\
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("018f0000-0000-7000-8000-000000000001", cfg.repo_id);
    try std.testing.expectEqualStrings("alice\nops", cfg.principal);
    try std.testing.expectEqualStrings("laptop", cfg.device);
    try std.testing.expectEqual(@as(u64, 43), cfg.seq);
}

test "config parser accepts multiline strings" {
    var cfg = try parseConfig(std.testing.allocator,
        \\repo_id = "018f0000-0000-7000-8000-000000000001"
        \\principal = """
        \\alice
        \\ops
        \\"""
        \\device = '''
        \\laptop
        \\'''
        \\seq = 0
        \\
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("alice\nops\n", cfg.principal);
    try std.testing.expectEqualStrings("laptop\n", cfg.device);
    try std.testing.expectEqual(@as(u64, 0), cfg.seq);
}

test "signing key fingerprint uses OpenSSH SHA256 form" {
    const public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBzDcgcRLK0dOuLZ/Gl37fAKM3xVHKPSkQakRGwpthnx test@example.com";
    const fingerprint = try signingKeyFingerprint(std.testing.allocator, public_key);
    defer std.testing.allocator.free(fingerprint);
    try std.testing.expectEqualStrings("SHA256:UPzoeVtlEpSaFm0nmnPA5RVCLxms2/NEgO5uHEitDgk", fingerprint);
}
