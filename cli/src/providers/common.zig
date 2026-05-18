const std = @import("std");
const errors = @import("../errors.zig");
const event_model = @import("../event/model.zig");
const event_builders = @import("../event/builders.zig");
const event_writer_mod = @import("../event_writer.zig");
const event_json = @import("../event/json.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");
const import_bot = @import("import_bot.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const eprint = io.eprint;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonString = json_writer.appendJsonString;

pub const BaseImportOptions = struct {
    api_url: []const u8,
    token_arg: ?[]const u8 = null,
    from_file: ?[]const u8 = null,
    include_comments: bool = true,
    bot_principal: []const u8 = import_bot.principal,
    bot_device: []const u8,
    max_pages: usize = 10,
    map_file: ?[]const u8 = null,
};

pub const ParseImportArgsResult = struct {
    allocator: Allocator,
    token_source_owned: ?[]u8 = null,

    pub fn deinit(self: *ParseImportArgsResult) void {
        if (self.token_source_owned) |value| self.allocator.free(value);
        self.token_source_owned = null;
    }

    fn replaceTokenSource(self: *ParseImportArgsResult, value: []u8) void {
        if (self.token_source_owned) |old| self.allocator.free(old);
        self.token_source_owned = value;
    }
};

pub fn parseImportArgs(allocator: Allocator, args: []const []const u8, options: anytype, comptime Hooks: type) !ParseImportArgsResult {
    var result = ParseImportArgsResult{ .allocator = allocator };
    errdefer result.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--api-url")) {
            options.base.api_url = try util.requireValue(args, &i, "--api-url");
        } else if (std.mem.eql(u8, arg, "--token")) {
            _ = try util.requireValue(args, &i, "--token");
            try eprint("{s}: --token exposes credentials in process lists; use {s}\n", .{ Hooks.command_context, Hooks.token_help });
            return CliError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            const env_name = try util.requireValue(args, &i, "--token-env");
            const value = try secretFromEnv(allocator, Hooks.command_context, env_name);
            result.replaceTokenSource(value);
            options.base.token_arg = result.token_source_owned;
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            const path = try util.requireValue(args, &i, "--token-file");
            const value = try secretFromFile(allocator, Hooks.command_context, path);
            result.replaceTokenSource(value);
            options.base.token_arg = result.token_source_owned;
        } else if (std.mem.eql(u8, arg, "--from-file")) {
            options.base.from_file = try util.requireValue(args, &i, "--from-file");
        } else if (std.mem.eql(u8, arg, "--no-comments")) {
            options.base.include_comments = false;
        } else if (std.mem.eql(u8, arg, "--import-bot")) {
            options.base.bot_principal = try util.requireValue(args, &i, "--import-bot");
        } else if (std.mem.eql(u8, arg, "--device")) {
            options.base.bot_device = try util.requireValue(args, &i, "--device");
        } else if (std.mem.eql(u8, arg, "--max-pages")) {
            options.base.max_pages = std.fmt.parseUnsigned(usize, try util.requireValue(args, &i, "--max-pages"), 10) catch {
                try eprint("{s}: --max-pages must be a positive integer\n", .{Hooks.command_context});
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            options.base.map_file = try util.requireValue(args, &i, "--map-file");
        } else if (try Hooks.parseProviderArg(allocator, args, &i, arg, options)) {
            continue;
        } else {
            try eprint("{s}: unknown option '{s}'\n", .{ Hooks.command_context, arg });
            return CliError.UserError;
        }
    }

    return result;
}

pub const ImportDelegationConfig = struct {
    command_context: []const u8,
    provider_name: []const u8,
    capability: []const u8,
    scope: []const u8,
};

pub fn ensureImportDelegation(allocator: Allocator, principal: []const u8, device: []const u8, config: ImportDelegationConfig) !void {
    const checked_principal = try util.checkedRefSegment(allocator, principal, "principal");
    defer allocator.free(checked_principal);
    const checked_device = try util.checkedRefSegment(allocator, device, "device");
    defer allocator.free(checked_device);

    var writer = try EventWriter.init(allocator, config.command_context);
    defer writer.deinit();

    const role = try index.roleForPrincipal(allocator, writer.repo, writer.cfg.principal);
    defer if (role) |value| allocator.free(value);
    if (role == null or !roleAtLeastMaintainer(role.?)) {
        try eprint("{s}: {s} must be maintainer or owner to delegate {s} import authority\n", .{ config.command_context, writer.cfg.principal, config.provider_name });
        return CliError.Unauthorized;
    }

    if (!(try index.isIdentityDeviceActive(allocator, writer.repo, writer.cfg.principal, writer.cfg.device))) {
        try eprint("{s}: configured actor {s}/{s} is not an active device\n", .{ config.command_context, writer.cfg.principal, writer.cfg.device });
        return CliError.Unauthorized;
    }

    var signing_key = try repo_mod.configuredSigningKey(allocator);
    defer signing_key.deinit();
    if (std.mem.trim(u8, signing_key.public_key, " \t\r\n").len == 0) {
        try eprint("{s}: signing public key is required to delegate import-bot; configure Git signing with user.signingkey\n", .{config.command_context});
        return CliError.MissingArgument;
    }

    if (try index.hasActiveDelegation(allocator, writer.repo, checked_principal, checked_device, config.capability, config.scope, signing_key.fingerprint)) {
        return;
    }

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try util.rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const body = try event_builders.buildAclDelegationJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        checked_principal,
        checked_device,
        config.capability,
        config.scope,
        .{
            .scheme = signing_key.scheme,
            .public_key = signing_key.public_key,
            .fingerprint = signing_key.fingerprint,
        },
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        true,
    );
    defer allocator.free(body);
    const subject_line = try std.fmt.allocPrint(allocator, "acl.delegation_granted {s}/{s} {s}", .{ checked_principal, checked_device, config.capability });
    defer allocator.free(subject_line);
    const commit = try writer.write(config.command_context, subject_line, body);
    allocator.free(commit);
    try index.ensureIndex(allocator, writer.repo);
}

fn roleAtLeastMaintainer(role: []const u8) bool {
    return std.mem.eql(u8, role, "maintainer") or std.mem.eql(u8, role, "owner");
}

pub fn secretFromEnv(allocator: Allocator, command: []const u8, env_name: []const u8) ![]u8 {
    const value = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            try eprint("{s}: environment variable {s} is not set\n", .{ command, env_name });
            return CliError.MissingArgument;
        },
        else => return err,
    };
    errdefer allocator.free(value);
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) {
        try eprint("{s}: environment variable {s} must not be empty\n", .{ command, env_name });
        return CliError.MissingArgument;
    }
    return value;
}

pub fn secretFromFile(allocator: Allocator, command: []const u8, path: []const u8) ![]u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            try eprint("{s}: secret file {s} was not found\n", .{ command, path });
            return CliError.MissingArgument;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) {
        try eprint("{s}: secret file {s} must not be empty\n", .{ command, path });
        return CliError.MissingArgument;
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn sizedString(allocator: Allocator, value: ?[]const u8, fallback: []const u8, max_bytes: usize) ![]u8 {
    const raw = value orelse fallback;
    return sizedStringWithMarker(allocator, raw, max_bytes, "\n\n[truncated by gitomi import]");
}

fn sizedStringWithMarker(allocator: Allocator, raw: []const u8, max_bytes: usize, marker: []const u8) ![]u8 {
    if (raw.len <= max_bytes) return allocator.dupe(u8, raw);

    if (max_bytes <= marker.len) return allocator.dupe(u8, raw[0..utf8PrefixLen(raw, max_bytes)]);

    const prefix_len = utf8PrefixLen(raw, max_bytes - marker.len);
    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(allocator);
    try out_buf.appendSlice(allocator, raw[0..prefix_len]);
    try out_buf.appendSlice(allocator, marker);
    return try out_buf.toOwnedSlice(allocator);
}

pub fn subject(allocator: Allocator, prefix: []const u8, title: []const u8) ![]u8 {
    const title_limit = if (prefix.len >= git.max_event_subject_bytes) 0 else git.max_event_subject_bytes - prefix.len;
    const title_line = try subjectLine(allocator, title);
    defer allocator.free(title_line);
    const title_part = try sizedStringWithMarker(allocator, title_line, title_limit, " [truncated by gitomi import]");
    defer allocator.free(title_part);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, title_part });
}

fn subjectLine(allocator: Allocator, title: []const u8) ![]u8 {
    const line = try allocator.dupe(u8, title);
    for (line) |*byte| {
        if (byte.* == '\r' or byte.* == '\n') byte.* = ' ';
    }
    return line;
}

pub fn utf8PrefixLen(value: []const u8, max_bytes: usize) usize {
    var len = @min(value.len, max_bytes);
    while (len > 0 and len < value.len and (value[len] & 0xc0) == 0x80) {
        len -= 1;
    }
    return len;
}

pub fn singleArrayBody(allocator: Allocator, key: []const u8, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldStringArray(&buf, allocator, key, &.{value}, false);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

pub fn appendStringField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: []const u8) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonFieldString(buf, allocator, key, value, false);
}

pub fn appendBoolField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: bool) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonFieldBool(buf, allocator, key, value, false);
}

pub fn appendStringArrayValueField(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, key: []const u8, value: ?std.json.Value) !void {
    const array = event_json.jsonArray(value) orelse return;
    if (array.items.len == 0) return;
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    var first_item = true;
    for (array.items) |item| {
        if (item != .string) continue;
        if (!first_item) try buf.append(allocator, ',');
        first_item = false;
        try appendJsonString(buf, allocator, item.string);
    }
    try buf.append(allocator, ']');
}

pub fn parseResponseNumber(allocator: Allocator, raw: []const u8, key: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    return event_json.jsonInteger(root.get(key));
}

pub fn legacyNumber(root: std.json.ObjectMap, key: []const u8) ?i64 {
    const legacy = switch (root.get("legacy") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    return event_json.jsonInteger(legacy.get(key));
}

pub fn timestampOrNow(allocator: Allocator, value: ?std.json.Value) ![]u8 {
    if (event_json.jsonString(value)) |timestamp| {
        if (timestamp.len != 0 and timestamp[timestamp.len - 1] == 'Z') {
            return allocator.dupe(u8, timestamp);
        }
    }
    return util.rfc3339Now(allocator);
}

pub fn firstJsonValue(a: ?std.json.Value, b: ?std.json.Value) ?std.json.Value {
    return if (a) |value| value else b;
}

pub fn firstJsonValue3(a: ?std.json.Value, b: ?std.json.Value, c: ?std.json.Value) ?std.json.Value {
    return firstJsonValue(firstJsonValue(a, b), c);
}

pub fn namedArray(allocator: Allocator, value: ?std.json.Value, key: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    try appendNamedArray(allocator, &list, value, key);
    return list.toOwnedSlice(allocator);
}

pub fn appendNamedArray(allocator: Allocator, list: *std.ArrayList([]u8), value: ?std.json.Value, key: []const u8) !void {
    const actual = value orelse return;
    switch (actual) {
        .array => |array| return appendNamedArrayItems(allocator, list, array, key),
        .object => |object| {
            if (event_json.jsonString(object.get(key))) |name| {
                if (name.len != 0) try list.append(allocator, try sizedString(allocator, name, "", git.max_payload_atom_bytes));
            }
            if (event_json.jsonArray(object.get("nodes"))) |nodes| try appendNamedArrayItems(allocator, list, nodes, key);
            if (event_json.jsonArray(object.get("edges"))) |edges| {
                for (edges.items) |edge| {
                    if (edge != .object) continue;
                    const node = switch (edge.object.get("node") orelse continue) {
                        .object => |node_object| node_object,
                        else => continue,
                    };
                    if (event_json.jsonString(node.get(key))) |name| {
                        if (name.len != 0) try list.append(allocator, try sizedString(allocator, name, "", git.max_payload_atom_bytes));
                    }
                }
            }
        },
        .string => |string| if (string.len != 0) try list.append(allocator, try sizedString(allocator, string, "", git.max_payload_atom_bytes)),
        else => {},
    }
}

fn appendNamedArrayItems(allocator: Allocator, list: *std.ArrayList([]u8), array: std.json.Array, key: []const u8) !void {
    for (array.items) |item| {
        if (item == .string) {
            try list.append(allocator, try sizedString(allocator, item.string, "", git.max_payload_atom_bytes));
        } else if (item == .object) {
            if (event_json.jsonString(item.object.get(key))) |name| {
                if (name.len != 0) try list.append(allocator, try sizedString(allocator, name, "", git.max_payload_atom_bytes));
            }
        }
    }
}

pub fn optionalUnsignedField(object: std.json.ObjectMap, keys: []const []const u8) ?u64 {
    for (keys) |key| {
        if (jsonOptionalUnsigned(object.get(key))) |value| return value;
    }
    return null;
}

pub fn nestedString(object: std.json.ObjectMap, parent_key: []const u8, child_key: []const u8) ?[]const u8 {
    const parent = switch (object.get(parent_key) orelse return null) {
        .object => |map| map,
        else => return null,
    };
    return event_json.jsonString(parent.get(child_key));
}

pub fn jsonOptionalUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    const integer = switch (actual) {
        .integer => |i| i,
        .object => |object| return jsonOptionalUnsigned(object.get("totalCount")) orelse jsonOptionalUnsigned(object.get("count")),
        else => return null,
    };
    if (integer < 0) return null;
    return @intCast(integer);
}

pub fn urlPathEscape(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        const unreserved = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0f]);
        }
    }
    return buf.toOwnedSlice(allocator);
}

pub const StringListDiff = struct {
    allocator: Allocator,
    added: [][]u8,
    removed: [][]u8,

    pub fn deinit(self: *StringListDiff) void {
        git.freeStringList(self.allocator, self.added);
        git.freeStringList(self.allocator, self.removed);
    }
};

pub fn diffStringLists(allocator: Allocator, desired: []const []const u8, current: []const []const u8) !StringListDiff {
    var added: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, added.items);
    var removed: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, removed.items);

    for (desired) |value| {
        if (value.len == 0) continue;
        if (!containsString(current, value)) {
            try added.append(allocator, try allocator.dupe(u8, value));
        }
    }
    for (current) |value| {
        if (value.len == 0) continue;
        if (!containsString(desired, value)) {
            try removed.append(allocator, try allocator.dupe(u8, value));
        }
    }
    return .{
        .allocator = allocator,
        .added = try added.toOwnedSlice(allocator),
        .removed = try removed.toOwnedSlice(allocator),
    };
}

pub fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn queryStringList(allocator: Allocator, db: *index.SqliteDb, sql_text: []const u8, object_id: []const u8) ![][]u8 {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    var list: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, list.items);
    while (try stmt.step()) {
        try list.append(allocator, try stmt.columnTextDup(allocator, 0));
    }
    return try list.toOwnedSlice(allocator);
}

pub const ObjectKind = enum {
    issue,
    pull,

    fn name(self: ObjectKind) []const u8 {
        return switch (self) {
            .issue => "issue",
            .pull => "pull",
        };
    }
};

pub const IssueOpenedOptions = struct {
    issue_id: []const u8,
    occurred_at: []const u8,
    title: []const u8,
    body_text: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
    legacy: event_model.LegacyInfo,
    metadata: event_model.IssueOpenedMetadata = .{},
    command_context: []const u8,
    subject: []const u8,
};

pub const PullOpenedOptions = struct {
    pull_id: []const u8,
    occurred_at: []const u8,
    title: []const u8,
    body_text: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
    legacy: event_model.LegacyInfo,
    metadata: event_model.PullOpenedMetadata = .{},
    command_context: []const u8,
    subject: []const u8,
};

pub const StringEventOptions = struct {
    object_kind: ObjectKind,
    object_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
    occurred_at: []const u8,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const IssueUpdatedOptions = struct {
    issue_id: []const u8,
    occurred_at: []const u8,
    update: event_model.IssueUpdate,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const PullUpdatedOptions = struct {
    pull_id: []const u8,
    occurred_at: []const u8,
    update: event_model.PullUpdate,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const PullMergedOptions = struct {
    pull_id: []const u8,
    occurred_at: []const u8,
    merge_oid: []const u8,
    target_oid: ?[]const u8,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const ImportedCommentRef = struct {
    id: []u8,
    event_hash: []u8,

    pub fn deinit(self: ImportedCommentRef, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.event_hash);
    }
};

pub const CommentAddedOptions = struct {
    parent_kind: []const u8,
    parent_id: []const u8,
    occurred_at: []const u8,
    body_text: []const u8,
    metadata: event_model.CommentAddedMetadata = .{},
    reply_parent_hash: []const u8 = "",
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const CommentBodySetOptions = struct {
    comment_id: []const u8,
    occurred_at: []const u8,
    body_text: []const u8,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const CommentRedactedOptions = struct {
    comment_id: []const u8,
    occurred_at: []const u8,
    reason: []const u8,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub fn constStringList(values: [][]u8) []const []const u8 {
    return @ptrCast(values);
}

pub fn openedSubjectPrefix(
    allocator: Allocator,
    object_kind: ObjectKind,
    object_id: []const u8,
    provider_name: []const u8,
    remote_number_prefix: []const u8,
    remote_number: u64,
) ![]u8 {
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, object_id);
    return std.fmt.allocPrint(
        allocator,
        "{s}.opened #{s} {s} {s}{d} ",
        .{ object_kind.name(), object_ref, provider_name, remote_number_prefix, remote_number },
    );
}

pub fn writeImportedIssueOpened(allocator: Allocator, writer: *EventWriter, options: IssueOpenedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildIssueOpenedJsonWithLegacyAndMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.issue_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        options.title,
        options.body_text,
        options.labels,
        options.assignees,
        options.legacy,
        options.metadata,
    );
    defer allocator.free(body);
    try stageAndFreeCommit(allocator, writer, options.command_context, options.subject, body);
}

pub fn writeImportedPullOpened(allocator: Allocator, writer: *EventWriter, options: PullOpenedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildPullOpenedJsonWithLegacyAndMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.pull_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        options.title,
        options.body_text,
        options.base_ref,
        options.head_ref,
        options.draft,
        options.legacy,
        options.metadata,
    );
    defer allocator.free(body);
    try stageAndFreeCommit(allocator, writer, options.command_context, options.subject, body);
}

pub fn writeImportedStringEvent(allocator: Allocator, writer: *EventWriter, options: StringEventOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = switch (options.object_kind) {
        .issue => try event_builders.buildIssueStringPayloadJson(
            allocator,
            writer.cfg,
            writer.nextSeq(),
            options.object_id,
            event_uuid,
            idem,
            options.occurred_at,
            writer.stagedEventParents(),
            options.event_type,
            options.payload_key,
            options.payload_value,
        ),
        .pull => try event_builders.buildPullStringPayloadJson(
            allocator,
            writer.cfg,
            writer.nextSeq(),
            options.object_id,
            event_uuid,
            idem,
            options.occurred_at,
            writer.stagedEventParents(),
            options.event_type,
            options.payload_key,
            options.payload_value,
        ),
    };
    defer allocator.free(body);
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, options.object_id);
    const subject_line = try std.fmt.allocPrint(allocator, "{s} #{s}{s}", .{ options.event_type, object_ref, options.subject_suffix });
    defer allocator.free(subject_line);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject_line, body);
}

pub fn writeImportedIssueUpdated(allocator: Allocator, writer: *EventWriter, options: IssueUpdatedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildIssueUpdatedJson(allocator, writer.cfg, writer.nextSeq(), options.issue_id, event_uuid, idem, options.occurred_at, writer.stagedEventParents(), options.update);
    defer allocator.free(body);
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, options.issue_id);
    const subject_line = try std.fmt.allocPrint(allocator, "issue.updated #{s}{s}", .{ issue_ref, options.subject_suffix });
    defer allocator.free(subject_line);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject_line, body);
}

pub fn writeImportedPullUpdated(allocator: Allocator, writer: *EventWriter, options: PullUpdatedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildPullUpdatedJson(allocator, writer.cfg, writer.nextSeq(), options.pull_id, event_uuid, idem, options.occurred_at, writer.stagedEventParents(), options.update);
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, options.pull_id);
    const subject_line = try std.fmt.allocPrint(allocator, "pull.updated #{s}{s}", .{ pull_ref, options.subject_suffix });
    defer allocator.free(subject_line);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject_line, body);
}

pub fn writeImportedPullMerged(allocator: Allocator, writer: *EventWriter, options: PullMergedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildPullMergedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.pull_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        if (options.merge_oid.len == 0) null else options.merge_oid,
        options.target_oid,
    );
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, options.pull_id);
    const subject_line = try std.fmt.allocPrint(allocator, "pull.merged #{s}{s}", .{ pull_ref, options.subject_suffix });
    defer allocator.free(subject_line);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject_line, body);
}

pub fn writeImportedCommentAdded(allocator: Allocator, writer: *EventWriter, options: CommentAddedOptions) !ImportedCommentRef {
    var comment_id: ?[]u8 = try util.newUuidV7(allocator);
    errdefer if (comment_id) |value| allocator.free(value);
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    var related: std.ArrayList([]const u8) = .empty;
    defer related.deinit(allocator);
    const base_parents = writer.stagedEventParents();
    try related.appendSlice(allocator, base_parents.related);
    if (options.reply_parent_hash.len != 0 and !containsString(related.items, options.reply_parent_hash)) {
        try related.append(allocator, options.reply_parent_hash);
    }
    const parents = event_model.EventParents{
        .log = base_parents.log,
        .anchor = base_parents.anchor,
        .causal = base_parents.causal,
        .related = related.items,
    };
    const body = try event_builders.buildCommentAddedJsonWithMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        comment_id.?,
        event_uuid,
        idem,
        options.occurred_at,
        parents,
        options.parent_kind,
        options.parent_id,
        options.body_text,
        options.metadata,
    );
    defer allocator.free(body);
    const subject_line = try std.fmt.allocPrint(allocator, "comment.added #{s}{s}", .{ comment_id.?[0..7], options.subject_suffix });
    defer allocator.free(subject_line);
    const commit = try writer.stage(options.command_context, subject_line, body);
    errdefer allocator.free(commit);
    const result = ImportedCommentRef{
        .id = comment_id.?,
        .event_hash = commit,
    };
    comment_id = null;
    return result;
}

pub fn writeImportedCommentBodySet(allocator: Allocator, writer: *EventWriter, options: CommentBodySetOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildCommentBodySetJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.comment_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        options.body_text,
    );
    defer allocator.free(body);
    var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const comment_ref = util.shortObjectRef(&comment_ref_buf, options.comment_id);
    const subject_line = try std.fmt.allocPrint(allocator, "comment.body_set #{s}{s}", .{ comment_ref, options.subject_suffix });
    defer allocator.free(subject_line);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject_line, body);
}

pub fn writeImportedCommentRedacted(allocator: Allocator, writer: *EventWriter, options: CommentRedactedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildCommentRedactedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.comment_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        options.reason,
    );
    defer allocator.free(body);
    var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const comment_ref = util.shortObjectRef(&comment_ref_buf, options.comment_id);
    const subject_line = try std.fmt.allocPrint(allocator, "comment.redacted #{s}{s}", .{ comment_ref, options.subject_suffix });
    defer allocator.free(subject_line);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject_line, body);
}

fn stageAndFreeCommit(allocator: Allocator, writer: *EventWriter, command_context: []const u8, subject_line: []const u8, body: []const u8) !void {
    const commit = try writer.stage(command_context, subject_line, body);
    allocator.free(commit);
}
