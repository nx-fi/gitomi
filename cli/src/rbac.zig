const std = @import("std");
const errors = @import("errors.zig");
const event_builders = @import("event/builders.zig");
const event_validation = @import("event/validation.zig");
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
    if (!event_validation.isKnownRole(role)) {
        try eprint("gt acl grant: role must be reader, reporter, contributor, maintainer, or owner\n", .{});
        return CliError.InvalidArgument;
    }
    const principal = try util.checkedRefSegment(allocator, raw_principal, "principal");
    defer allocator.free(principal);

    var writer = try EventWriter.init(allocator, "gt acl grant");
    defer writer.deinit();

    const actor_role = try loadAuthorizedActorRole(allocator, &writer, "gt acl grant");
    defer allocator.free(actor_role);
    if (!event_validation.roleAtLeast(actor_role, role)) {
        try eprint("gt acl grant: refusing to grant {s}; current actor {s} has role {s}\n", .{ role, writer.cfg.principal, actor_role });
        return CliError.Unauthorized;
    }
    try requireActorRoleAtLeast(&writer, actor_role, "owner", "gt acl grant", "grant ACL roles");

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

    const actor_role = try loadAuthorizedActorRole(allocator, &writer, "gt acl revoke");
    defer allocator.free(actor_role);
    try requireActorRoleAtLeast(&writer, actor_role, "owner", "gt acl revoke", "revoke ACL roles");

    const role = (try index.directRoleForPrincipal(allocator, writer.repo, principal)) orelse {
        try eprint("gt acl revoke: {s} has no direct role\n", .{principal});
        return CliError.NotFound;
    };
    defer allocator.free(role);
    if (std.mem.eql(u8, role, "owner") and (try index.aclRoleRevocationWouldRemoveLastOwner(allocator, writer.repo, principal))) {
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

pub fn createTeamCreatedEvent(allocator: Allocator, raw_slug: []const u8, name_arg: ?[]const u8, description_arg: ?[]const u8) !void {
    const slug = try checkedTeamSlug(allocator, raw_slug, "gt team create");
    defer allocator.free(slug);

    var writer = try EventWriter.init(allocator, "gt team create");
    defer writer.deinit();
    try requireActorOwner(allocator, &writer, "gt team create", "create teams");

    if (try index.teamExists(allocator, writer.repo, slug)) {
        try eprint("gt team create: team {s} already exists\n", .{slug});
        return CliError.UserError;
    }

    const name = try normalizedOptional(allocator, name_arg);
    defer if (name) |value| allocator.free(value);
    const description = try normalizedOptional(allocator, description_arg);
    defer if (description) |value| allocator.free(value);

    const event_body = try buildTeamCreatedEvent(allocator, &writer, slug, name orelse slug, description);
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "team.created {s}", .{slug});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt team", subject, event_body);
    defer allocator.free(commit_oid);

    try out("created team @{s}\n", .{slug});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createTeamUpdatedEvent(allocator: Allocator, raw_slug: []const u8, name_arg: ?[]const u8, description_arg: ?[]const u8) !void {
    const slug = try checkedTeamSlug(allocator, raw_slug, "gt team edit");
    defer allocator.free(slug);

    var writer = try EventWriter.init(allocator, "gt team edit");
    defer writer.deinit();
    try requireActorOwner(allocator, &writer, "gt team edit", "edit teams");

    if (!(try index.teamExists(allocator, writer.repo, slug))) {
        try eprint("gt team edit: team {s} does not exist\n", .{slug});
        return CliError.NotFound;
    }

    const name = try normalizedOptional(allocator, name_arg);
    defer if (name) |value| allocator.free(value);
    const description = try normalizedOptional(allocator, description_arg);
    defer if (description) |value| allocator.free(value);
    if (name == null and description == null) {
        try eprint("gt team edit: expected --name or --description\n", .{});
        return CliError.MissingArgument;
    }

    const event_body = try buildTeamUpdatedEvent(allocator, &writer, slug, name, description);
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "team.updated {s}", .{slug});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt team", subject, event_body);
    defer allocator.free(commit_oid);

    try out("updated team @{s}\n", .{slug});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createTeamMemberAddedEvent(allocator: Allocator, raw_slug: []const u8, raw_principal: []const u8) !void {
    try createTeamMemberEvent(allocator, raw_slug, raw_principal, true);
}

pub fn createTeamMemberRemovedEvent(allocator: Allocator, raw_slug: []const u8, raw_principal: []const u8) !void {
    try createTeamMemberEvent(allocator, raw_slug, raw_principal, false);
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
    try requireActorOwner(allocator, &writer, "gt identity add-device", "add identity devices");

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
    try requireActorOwner(allocator, &writer, "gt identity revoke-device", "revoke identity devices");

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

fn requireActorOwner(allocator: Allocator, writer: *const EventWriter, command_context: []const u8, action: []const u8) !void {
    const actor_role = try loadAuthorizedActorRole(allocator, writer, command_context);
    defer allocator.free(actor_role);
    try requireActorRoleAtLeast(writer, actor_role, "owner", command_context, action);
}

fn loadAuthorizedActorRole(allocator: Allocator, writer: *const EventWriter, command_context: []const u8) ![]u8 {
    const actor_role = (try index.effectiveWriteRoleForPrincipal(allocator, writer.repo, writer.cfg.principal)) orelse {
        try eprint("{s}: current actor {s} has no effective role\n", .{ command_context, writer.cfg.principal });
        return CliError.Unauthorized;
    };
    errdefer allocator.free(actor_role);

    if (!(try index.actorDeviceAuthorizedForWrite(allocator, writer.repo, writer.cfg.principal, writer.cfg.device))) {
        try eprint("{s}: current actor device {s}/{s} is not active\n", .{ command_context, writer.cfg.principal, writer.cfg.device });
        return CliError.Unauthorized;
    }

    return actor_role;
}

fn requireActorRoleAtLeast(
    writer: *const EventWriter,
    actor_role: []const u8,
    required_role: []const u8,
    command_context: []const u8,
    action: []const u8,
) !void {
    if (event_validation.roleAtLeast(actor_role, required_role)) return;
    try eprint("{s}: owner role required to {s}; current actor {s} has role {s}\n", .{ command_context, action, writer.cfg.principal, actor_role });
    return CliError.Unauthorized;
}

fn buildAclEvent(allocator: Allocator, writer: *const EventWriter, principal: []const u8, role: []const u8, grant: bool) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_builders.buildAclRoleJson(allocator, writer.cfg, writer.nextSeq(), principal, role, event_uuid, idem, occurred_at, writer.eventParents(), grant);
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
    return try event_builders.buildIdentityDeviceAddedJson(allocator, writer.cfg, writer.nextSeq(), principal, device, public_key, fingerprint, scheme, event_uuid, idem, occurred_at, writer.eventParents());
}

fn buildIdentityRevokedEvent(allocator: Allocator, writer: *const EventWriter, principal: []const u8, device: []const u8) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_builders.buildIdentityDeviceRevokedJson(allocator, writer.cfg, writer.nextSeq(), principal, device, event_uuid, idem, occurred_at, writer.eventParents());
}

fn createTeamMemberEvent(allocator: Allocator, raw_slug: []const u8, raw_principal: []const u8, add: bool) !void {
    const command_context = if (add) "gt team add-member" else "gt team remove-member";
    const slug = try checkedTeamSlug(allocator, raw_slug, command_context);
    defer allocator.free(slug);
    const principal = try util.checkedRefSegment(allocator, raw_principal, "principal");
    defer allocator.free(principal);
    if (std.mem.startsWith(u8, principal, "@")) {
        try eprint("{s}: nested team membership is not supported\n", .{command_context});
        return CliError.InvalidArgument;
    }

    var writer = try EventWriter.init(allocator, command_context);
    defer writer.deinit();
    try requireActorOwner(allocator, &writer, command_context, if (add) "add team members" else "remove team members");

    if (!(try index.teamExists(allocator, writer.repo, slug))) {
        try eprint("{s}: team {s} does not exist\n", .{ command_context, slug });
        return CliError.NotFound;
    }
    if (!add and !(try index.teamMemberActive(allocator, writer.repo, slug, principal))) {
        try eprint("{s}: {s} is not an active member of {s}\n", .{ command_context, principal, slug });
        return CliError.NotFound;
    }

    const event_body = try buildTeamMemberEvent(allocator, &writer, slug, principal, add);
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ if (add) "team.member_added" else "team.member_removed", slug, principal });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt team", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} {s} {s} team @{s}\n", .{ if (add) "added" else "removed", principal, if (add) "to" else "from", slug });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

fn checkedTeamSlug(allocator: Allocator, raw_slug: []const u8, command_context: []const u8) ![]u8 {
    const slug = std.mem.trim(u8, raw_slug, " \t\r\n");
    if (!util.isRefSafeSegment(slug) or std.mem.indexOfScalar(u8, slug, '@') != null) {
        try eprint("{s}: team slug must be a ref-safe segment without '@'\n", .{command_context});
        return CliError.InvalidArgument;
    }
    return try allocator.dupe(u8, slug);
}

fn normalizedOptional(allocator: Allocator, value: ?[]const u8) !?[]u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn buildTeamCreatedEvent(allocator: Allocator, writer: *const EventWriter, slug: []const u8, name: []const u8, description: ?[]const u8) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_builders.buildTeamCreatedJson(allocator, writer.cfg, writer.nextSeq(), slug, name, description, event_uuid, idem, occurred_at, writer.eventParents());
}

fn buildTeamUpdatedEvent(allocator: Allocator, writer: *const EventWriter, slug: []const u8, name: ?[]const u8, description: ?[]const u8) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_builders.buildTeamUpdatedJson(allocator, writer.cfg, writer.nextSeq(), slug, name, description, event_uuid, idem, occurred_at, writer.eventParents());
}

fn buildTeamMemberEvent(allocator: Allocator, writer: *const EventWriter, slug: []const u8, principal: []const u8, add: bool) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    return try event_builders.buildTeamMemberJson(allocator, writer.cfg, writer.nextSeq(), slug, principal, event_uuid, idem, occurred_at, writer.eventParents(), add);
}
