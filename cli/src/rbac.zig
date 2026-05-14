const std = @import("std");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const out = io.out;
const eprint = io.eprint;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;

pub fn createAclGrantEvent(allocator: Allocator, raw_principal: []const u8, role: []const u8) !void {
    if (!event_mod.isKnownRole(role)) {
        try eprint("gt acl grant: role must be reader, reporter, contributor, maintainer, or owner\n", .{});
        return CliError.InvalidArgument;
    }
    const principal = try util.checkedRefSegment(allocator, raw_principal, "principal");
    defer allocator.free(principal);

    var writer = try EventWriter.init(allocator, "gt acl grant");
    defer writer.deinit();

    const event_body = try buildAclEvent(allocator, &writer, principal, role, true);
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "acl.role_granted {s} {s}", .{ principal, role });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt acl", subject, event_body);
    defer allocator.free(commit_oid);

    try out("granted {s} to {s}\n", .{ role, principal });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createAclRevokeEvent(allocator: Allocator, raw_principal: []const u8) !void {
    const principal = try util.checkedRefSegment(allocator, raw_principal, "principal");
    defer allocator.free(principal);

    var writer = try EventWriter.init(allocator, "gt acl revoke");
    defer writer.deinit();

    const role = (try index.roleForPrincipal(allocator, writer.repo, principal)) orelse {
        try eprint("gt acl revoke: {s} has no effective role\n", .{principal});
        return CliError.NotFound;
    };
    defer allocator.free(role);
    if (std.mem.eql(u8, principal, writer.cfg.principal) and std.mem.eql(u8, role, "owner") and try index.countOwners(allocator, writer.repo) <= 1) {
        try eprint("gt acl revoke: refusing to revoke the last owner\n", .{});
        return CliError.Unauthorized;
    }

    const event_body = try buildAclEvent(allocator, &writer, principal, role, false);
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "acl.role_revoked {s} {s}", .{ principal, role });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt acl", subject, event_body);
    defer allocator.free(commit_oid);

    try out("revoked {s} from {s}\n", .{ role, principal });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIdentityDeviceAddedEvent(
    allocator: Allocator,
    raw_principal: []const u8,
    raw_device: []const u8,
    public_key_arg: ?[]const u8,
    fingerprint_arg: ?[]const u8,
    scheme: []const u8,
) !void {
    const principal = try util.checkedRefSegment(allocator, raw_principal, "principal");
    defer allocator.free(principal);
    const device = try util.checkedRefSegment(allocator, raw_device, "device");
    defer allocator.free(device);

    var writer = try EventWriter.init(allocator, "gt identity add-device");
    defer writer.deinit();

    var configured_key: ?repo_mod.SigningKey = null;
    defer if (configured_key) |*key| key.deinit();

    const public_key = if (public_key_arg) |value| try allocator.dupe(u8, value) else blk: {
        configured_key = try repo_mod.configuredSigningKey(allocator);
        break :blk try allocator.dupe(u8, configured_key.?.public_key);
    };
    defer allocator.free(public_key);
    if (std.mem.trim(u8, public_key, " \t\r\n").len == 0) {
        try eprint("gt identity add-device: signing public key is required; configure user.signingkey or pass --public-key\n", .{});
        return CliError.MissingArgument;
    }
    const fingerprint = if (fingerprint_arg) |value| try allocator.dupe(u8, value) else if (configured_key) |key| try allocator.dupe(u8, key.fingerprint) else try repo_mod.signingKeyFingerprint(allocator, public_key);
    defer allocator.free(fingerprint);
    const effective_scheme = if (configured_key) |key| key.scheme else scheme;

    const event_body = try buildIdentityAddedEvent(allocator, &writer, principal, device, public_key, fingerprint, effective_scheme);
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "identity.device_added {s}/{s}", .{ principal, device });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt identity", subject, event_body);
    defer allocator.free(commit_oid);

    try out("added device {s}/{s}\n", .{ principal, device });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIdentityDeviceRevokedEvent(allocator: Allocator, raw_principal: []const u8, raw_device: []const u8) !void {
    const principal = try util.checkedRefSegment(allocator, raw_principal, "principal");
    defer allocator.free(principal);
    const device = try util.checkedRefSegment(allocator, raw_device, "device");
    defer allocator.free(device);

    var writer = try EventWriter.init(allocator, "gt identity revoke-device");
    defer writer.deinit();
    if (!(try index.isIdentityDeviceActive(allocator, writer.repo, principal, device))) {
        try eprint("gt identity revoke-device: {s}/{s} is not an active device\n", .{ principal, device });
        return CliError.NotFound;
    }

    const event_body = try buildIdentityRevokedEvent(allocator, &writer, principal, device);
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "identity.device_revoked {s}/{s}", .{ principal, device });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt identity", subject, event_body);
    defer allocator.free(commit_oid);

    try out("revoked device {s}/{s}\n", .{ principal, device });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

fn buildAclEvent(allocator: Allocator, writer: *const EventWriter, principal: []const u8, role: []const u8, grant: bool) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_mod.buildAclRoleJson(allocator, writer.cfg, writer.nextSeq(), principal, role, event_uuid, idem, occurred_at, writer.eventParents(), grant);
}

fn buildIdentityAddedEvent(
    allocator: Allocator,
    writer: *const EventWriter,
    principal: []const u8,
    device: []const u8,
    public_key: []const u8,
    fingerprint: []const u8,
    scheme: []const u8,
) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_mod.buildIdentityDeviceAddedJson(allocator, writer.cfg, writer.nextSeq(), principal, device, public_key, fingerprint, scheme, event_uuid, idem, occurred_at, writer.eventParents());
}

fn buildIdentityRevokedEvent(allocator: Allocator, writer: *const EventWriter, principal: []const u8, device: []const u8) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_mod.buildIdentityDeviceRevokedJson(allocator, writer.cfg, writer.nextSeq(), principal, device, event_uuid, idem, occurred_at, writer.eventParents());
}
