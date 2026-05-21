const std = @import("std");
const event_validation = @import("../event/validation.zig");
const index = @import("../index.zig");
const rbac = @import("../rbac.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyCell = shared.appendEmptyCell;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const appendCsrfInput = shared.appendCsrfInput;
const formValueOwned = shared.formValueOwned;
const formHasValidCsrfToken = shared.formHasValidCsrfToken;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

const FlashKind = enum {
    success,
    failure,
};

const Flash = struct {
    kind: FlashKind,
    message: []const u8,
};

const roles = [_][]const u8{
    "reader",
    "reporter",
    "contributor",
    "maintainer",
    "owner",
};

pub fn renderAccessPage(allocator: Allocator, repo: Repo, csrf_token: []const u8) ![]u8 {
    return renderAccessPageWithFlash(allocator, repo, csrf_token, null);
}

pub fn handleAccessRolePost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, form_body: []const u8, csrf_token: []const u8) !void {
    if (!try formHasValidCsrfToken(allocator, form_body, csrf_token)) {
        try sendAccessError(allocator, repo, stream, 403, "Forbidden", "Invalid access form token. Reload the page and try again.", csrf_token);
        return;
    }

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    const principal_owned = (try formValueOwned(allocator, form_body, "principal")) orelse try allocator.dupe(u8, "");
    defer allocator.free(principal_owned);
    const principal = std.mem.trim(u8, principal_owned, " \t\r\n");
    if (principal.len == 0) {
        try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Principal is required.", csrf_token);
        return;
    }

    if (std.mem.eql(u8, action, "grant-role")) {
        const role_owned = (try formValueOwned(allocator, form_body, "role")) orelse try allocator.dupe(u8, "");
        defer allocator.free(role_owned);
        const role = std.mem.trim(u8, role_owned, " \t\r\n");
        if (!event_validation.isKnownRole(role)) {
            try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Role must be reader, reporter, contributor, maintainer, or owner.", csrf_token);
            return;
        }
        rbac.createAclGrantEvent(allocator, principal, role) catch |err| {
            try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not grant the role. Check that your actor is an owner and the target role is allowed."), csrf_token);
            return;
        };
    } else if (std.mem.eql(u8, action, "revoke-role")) {
        rbac.createAclRevokeEvent(allocator, principal) catch |err| {
            try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not revoke the role. The principal may have no role or this may be the last owner."), csrf_token);
            return;
        };
    } else {
        try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Unknown role action.", csrf_token);
        return;
    }

    try sendRedirect(allocator, stream, "/access");
}

pub fn handleAccessDevicePost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, form_body: []const u8, csrf_token: []const u8) !void {
    if (!try formHasValidCsrfToken(allocator, form_body, csrf_token)) {
        try sendAccessError(allocator, repo, stream, 403, "Forbidden", "Invalid access form token. Reload the page and try again.", csrf_token);
        return;
    }

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    const principal_owned = (try formValueOwned(allocator, form_body, "principal")) orelse try allocator.dupe(u8, "");
    defer allocator.free(principal_owned);
    const device_owned = (try formValueOwned(allocator, form_body, "device")) orelse try allocator.dupe(u8, "");
    defer allocator.free(device_owned);
    const principal = std.mem.trim(u8, principal_owned, " \t\r\n");
    const device = std.mem.trim(u8, device_owned, " \t\r\n");
    if (principal.len == 0 or device.len == 0) {
        try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Principal and device are required.", csrf_token);
        return;
    }

    if (std.mem.eql(u8, action, "add-device")) {
        const public_key_owned = (try formValueOwned(allocator, form_body, "public_key")) orelse try allocator.dupe(u8, "");
        defer allocator.free(public_key_owned);
        const fingerprint_owned = (try formValueOwned(allocator, form_body, "fingerprint")) orelse try allocator.dupe(u8, "");
        defer allocator.free(fingerprint_owned);
        const scheme_owned = (try formValueOwned(allocator, form_body, "scheme")) orelse try allocator.dupe(u8, "ssh");
        defer allocator.free(scheme_owned);
        const public_key = std.mem.trim(u8, public_key_owned, " \t\r\n");
        const fingerprint = std.mem.trim(u8, fingerprint_owned, " \t\r\n");
        const scheme = std.mem.trim(u8, scheme_owned, " \t\r\n");
        if (public_key.len == 0) {
            try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Signing public key is required when adding a device from the web UI.", csrf_token);
            return;
        }
        if (scheme.len == 0) {
            try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Signing scheme is required.", csrf_token);
            return;
        }
        rbac.createIdentityDeviceAddedEvent(
            allocator,
            principal,
            device,
            public_key,
            if (fingerprint.len == 0) null else fingerprint,
            scheme,
        ) catch |err| {
            try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not add the device. Check that your actor is an owner and the signing key is valid."), csrf_token);
            return;
        };
    } else if (std.mem.eql(u8, action, "revoke-device")) {
        rbac.createIdentityDeviceRevokedEvent(allocator, principal, device) catch |err| {
            try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not revoke the device. It may already be inactive or your actor may not be an owner."), csrf_token);
            return;
        };
    } else {
        try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Unknown device action.", csrf_token);
        return;
    }

    try sendRedirect(allocator, stream, "/access");
}

pub fn handleAccessTeamPost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, form_body: []const u8, csrf_token: []const u8) !void {
    if (!try formHasValidCsrfToken(allocator, form_body, csrf_token)) {
        try sendAccessError(allocator, repo, stream, 403, "Forbidden", "Invalid access form token. Reload the page and try again.", csrf_token);
        return;
    }

    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "");
    defer allocator.free(action_owned);
    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    const slug_owned = (try formValueOwned(allocator, form_body, "slug")) orelse try allocator.dupe(u8, "");
    defer allocator.free(slug_owned);
    const slug = std.mem.trim(u8, slug_owned, " \t\r\n");
    if (slug.len == 0) {
        try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Team slug is required.", csrf_token);
        return;
    }

    if (std.mem.eql(u8, action, "create-team")) {
        const name_owned = (try formValueOwned(allocator, form_body, "name")) orelse try allocator.dupe(u8, "");
        defer allocator.free(name_owned);
        const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
        defer allocator.free(description_owned);
        const name = std.mem.trim(u8, name_owned, " \t\r\n");
        const description = std.mem.trim(u8, description_owned, " \t\r\n");
        rbac.createTeamCreatedEvent(allocator, slug, if (name.len == 0) null else name, if (description.len == 0) null else description) catch |err| {
            try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not create the team. Check that your actor is an owner and the slug is available."), csrf_token);
            return;
        };
    } else if (std.mem.eql(u8, action, "edit-team")) {
        const name_owned = (try formValueOwned(allocator, form_body, "name")) orelse try allocator.dupe(u8, "");
        defer allocator.free(name_owned);
        const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
        defer allocator.free(description_owned);
        const name = std.mem.trim(u8, name_owned, " \t\r\n");
        const description = std.mem.trim(u8, description_owned, " \t\r\n");
        rbac.createTeamUpdatedEvent(allocator, slug, name, description) catch |err| {
            try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not update the team. Check that your actor is an owner and the team exists."), csrf_token);
            return;
        };
    } else if (std.mem.eql(u8, action, "add-member") or std.mem.eql(u8, action, "remove-member")) {
        const principal_owned = (try formValueOwned(allocator, form_body, "principal")) orelse try allocator.dupe(u8, "");
        defer allocator.free(principal_owned);
        const principal = std.mem.trim(u8, principal_owned, " \t\r\n");
        if (principal.len == 0) {
            try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Principal is required.", csrf_token);
            return;
        }
        if (std.mem.eql(u8, action, "add-member")) {
            rbac.createTeamMemberAddedEvent(allocator, slug, principal) catch |err| {
                try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not add the team member. Check that your actor is an owner and the team exists."), csrf_token);
                return;
            };
        } else {
            rbac.createTeamMemberRemovedEvent(allocator, slug, principal) catch |err| {
                try sendAccessError(allocator, repo, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), shared.writeFailureMessage(err, "Could not remove the team member. They may not be an active member or this may remove the last owner."), csrf_token);
                return;
            };
        }
    } else {
        try sendAccessError(allocator, repo, stream, 422, "Unprocessable Entity", "Unknown team action.", csrf_token);
        return;
    }

    try sendRedirect(allocator, stream, "/access");
}

fn sendAccessError(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, status: u16, reason: []const u8, message: []const u8, csrf_token: []const u8) !void {
    const body = try renderAccessPageWithFlash(allocator, repo, csrf_token, .{ .kind = .failure, .message = message });
    defer allocator.free(body);
    try sendResponse(allocator, stream, status, reason, "text/html", body, null);
}

fn renderAccessPageWithFlash(allocator: Allocator, repo: Repo, csrf_token: []const u8, flash: ?Flash) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Access", "access", "/access")) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Access", "access");
    try shared.appendSettingsLayoutStart(&buf, allocator, "access");
    try buf.appendSlice(allocator, "<section class=\"panel access-panel\">");
    try appendSectionHead(&buf, allocator, "Settings", "Access", null);
    if (flash) |item| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash {kind}">{message}</div>
        , .{
            .kind = switch (item.kind) {
                .success => "success",
                .failure => "error",
            },
            .message = item.message,
        });
    }
    try buf.appendSlice(allocator, "<div class=\"access-grid\">");
    try appendGrantRoleForm(&buf, allocator, csrf_token);
    try appendAddDeviceForm(&buf, allocator, csrf_token);
    try appendCreateTeamForm(&buf, allocator, csrf_token);
    try appendAddTeamMemberForm(&buf, allocator, csrf_token);
    try buf.appendSlice(allocator, "</div></section>");

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    try appendTeamTable(&buf, allocator, &db, csrf_token);
    try appendRoleTable(&buf, allocator, &db, csrf_token);
    try appendDeviceTable(&buf, allocator, &db, csrf_token);

    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendGrantRoleForm(buf: *std.ArrayList(u8), allocator: Allocator, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="access-card">
        \\  <h2>Grant role</h2>
        \\  <form class="issue-form access-form" method="post" action="/access/roles">
        \\    <input type="hidden" name="action" value="grant-role">
    );
    try appendCsrfInput(buf, allocator, csrf_token);
    try buf.appendSlice(allocator,
        \\    <label>Principal<input name="principal" required></label>
        \\    <label>Role<select name="role">
    );
    for (roles) |role| {
        try appendTemplate(buf, allocator, "<option value=\"{role}\">{role}</option>", .{ .role = role });
    }
    try buf.appendSlice(allocator,
        \\    </select></label>
        \\    <div class="form-actions"><button class="button primary" type="submit">Grant role</button></div>
        \\  </form>
        \\</section>
    );
}

fn appendAddDeviceForm(buf: *std.ArrayList(u8), allocator: Allocator, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="access-card">
        \\  <h2>Add device</h2>
        \\  <form class="issue-form access-form" method="post" action="/access/devices">
        \\    <input type="hidden" name="action" value="add-device">
    );
    try appendCsrfInput(buf, allocator, csrf_token);
    try buf.appendSlice(allocator,
        \\    <div class="access-form-row">
        \\      <label>Principal<input name="principal" required></label>
        \\      <label>Device<input name="device" required></label>
        \\    </div>
        \\    <label>Public key<textarea name="public_key" rows="3" required></textarea></label>
        \\    <div class="access-form-row">
        \\      <label>Fingerprint<input name="fingerprint" placeholder="Generated when blank"></label>
        \\      <label>Scheme<select name="scheme"><option value="ssh">ssh</option><option value="openpgp">openpgp</option></select></label>
        \\    </div>
        \\    <div class="form-actions"><button class="button primary" type="submit">Add device</button></div>
        \\  </form>
        \\</section>
    );
}

fn appendCreateTeamForm(buf: *std.ArrayList(u8), allocator: Allocator, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="access-card">
        \\  <h2>Create team</h2>
        \\  <form class="issue-form access-form" method="post" action="/access/teams">
        \\    <input type="hidden" name="action" value="create-team">
    );
    try appendCsrfInput(buf, allocator, csrf_token);
    try buf.appendSlice(allocator,
        \\    <div class="access-form-row">
        \\      <label>Slug<input name="slug" required></label>
        \\      <label>Name<input name="name"></label>
        \\    </div>
        \\    <label>Description<textarea name="description" rows="3"></textarea></label>
        \\    <div class="form-actions"><button class="button primary" type="submit">Create team</button></div>
        \\  </form>
        \\</section>
    );
}

fn appendAddTeamMemberForm(buf: *std.ArrayList(u8), allocator: Allocator, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="access-card">
        \\  <h2>Add team member</h2>
        \\  <form class="issue-form access-form" method="post" action="/access/teams">
        \\    <input type="hidden" name="action" value="add-member">
    );
    try appendCsrfInput(buf, allocator, csrf_token);
    try buf.appendSlice(allocator,
        \\    <div class="access-form-row">
        \\      <label>Team slug<input name="slug" required></label>
        \\      <label>Principal<input name="principal" required></label>
        \\    </div>
        \\    <div class="form-actions"><button class="button primary" type="submit">Add member</button></div>
        \\  </form>
        \\</section>
    );
}

fn appendTeamTable(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="panel access-table-panel">
        \\  <div class="section-head"><div><p class="eyebrow">Teams</p><h1>Permission Groups</h1></div></div>
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Team</th><th>Role</th><th>Description</th><th>Members</th><th>Actions</th></tr></thead>
        \\      <tbody>
    );
    var stmt = try db.prepare(
        \\SELECT t.slug, t.name, t.description, COALESCE(r.role, '')
        \\FROM teams t
        \\LEFT JOIN acl_roles r ON r.principal = '@' || t.slug
        \\ORDER BY t.slug
    );
    defer stmt.deinit();
    var shown: usize = 0;
    while (try stmt.step()) {
        const slug = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(slug);
        const name = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(name);
        const description = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(description);
        const role = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(role);
        try appendTemplate(buf, allocator,
            \\<tr><td><strong>@{slug}</strong><br><span class="muted">{name}</span></td><td>
        , .{ .slug = slug, .name = name });
        if (role.len == 0) {
            try buf.appendSlice(allocator, "<span class=\"muted\">No role</span>");
        } else {
            try appendTemplate(buf, allocator, "<span class=\"access-role-pill\">{role}</span>", .{ .role = role });
        }
        try appendTemplate(buf, allocator, "</td><td>{description}</td><td>", .{ .description = description });
        try appendTeamMembersCell(buf, allocator, db, slug, csrf_token);
        try buf.appendSlice(allocator, "</td><td>");
        try appendTeamEditForm(buf, allocator, slug, name, description, csrf_token);
        try buf.appendSlice(allocator, "</td></tr>");
        shown += 1;
    }
    if (shown == 0) try appendEmptyCell(buf, allocator, 5, "No teams found.");
    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
}

fn appendTeamMembersCell(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, slug: []const u8, csrf_token: []const u8) !void {
    var stmt = try db.prepare("SELECT principal FROM team_members WHERE slug = ? ORDER BY principal");
    defer stmt.deinit();
    try stmt.bindText(1, slug);
    var shown: usize = 0;
    try buf.appendSlice(allocator, "<div class=\"access-member-list\">");
    while (try stmt.step()) {
        const principal = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(principal);
        try buf.appendSlice(allocator, "<form class=\"access-member-chip\" method=\"post\" action=\"/access/teams\"><input type=\"hidden\" name=\"action\" value=\"remove-member\">");
        try appendCsrfInput(buf, allocator, csrf_token);
        try buf.appendSlice(allocator, "<input type=\"hidden\" name=\"slug\" value=\"");
        try shared.appendHtml(buf, allocator, slug);
        try buf.appendSlice(allocator, "\"><input type=\"hidden\" name=\"principal\" value=\"");
        try shared.appendHtml(buf, allocator, principal);
        try buf.appendSlice(allocator, "\"><span>");
        try shared.appendHtml(buf, allocator, principal);
        try buf.appendSlice(allocator, "</span><button class=\"button secondary\" type=\"submit\">Remove</button></form>");
        shown += 1;
    }
    if (shown == 0) try buf.appendSlice(allocator, "<span class=\"muted\">No members</span>");
    try buf.appendSlice(allocator, "</div>");
}

fn appendTeamEditForm(buf: *std.ArrayList(u8), allocator: Allocator, slug: []const u8, name: []const u8, description: []const u8, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator, "<form class=\"access-team-edit\" method=\"post\" action=\"/access/teams\"><input type=\"hidden\" name=\"action\" value=\"edit-team\">");
    try appendCsrfInput(buf, allocator, csrf_token);
    try buf.appendSlice(allocator, "<input type=\"hidden\" name=\"slug\" value=\"");
    try shared.appendHtml(buf, allocator, slug);
    try buf.appendSlice(allocator, "\"><label>Name<input name=\"name\" value=\"");
    try shared.appendHtml(buf, allocator, name);
    try buf.appendSlice(allocator, "\"></label><label>Description<input name=\"description\" value=\"");
    try shared.appendHtml(buf, allocator, description);
    try buf.appendSlice(allocator, "\"></label><button class=\"button secondary\" type=\"submit\">Update</button></form>");
}

fn appendRoleTable(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="panel access-table-panel">
        \\  <div class="section-head"><div><p class="eyebrow">ACL</p><h1>Role Grants</h1></div></div>
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Principal</th><th>Role</th><th>Grant Commit</th><th>Actions</th></tr></thead>
        \\      <tbody>
    );
    var stmt = try db.prepare("SELECT principal, role, grant_event_hash FROM acl_roles ORDER BY principal");
    defer stmt.deinit();
    var shown: usize = 0;
    while (try stmt.step()) {
        const principal = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(principal);
        const role = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(role);
        const grant_event_hash = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(grant_event_hash);
        try appendTemplate(buf, allocator,
            \\<tr><td><strong>{principal}</strong></td><td><span class="access-role-pill">{role}</span></td><td><code>{hash}</code></td><td>
        , .{
            .principal = principal,
            .role = role,
            .hash = grant_event_hash[0..@min(grant_event_hash.len, 12)],
        });
        try buf.appendSlice(allocator, "<form class=\"access-row-form\" method=\"post\" action=\"/access/roles\"><input type=\"hidden\" name=\"action\" value=\"revoke-role\">");
        try appendCsrfInput(buf, allocator, csrf_token);
        try buf.appendSlice(allocator, "<input type=\"hidden\" name=\"principal\" value=\"");
        try shared.appendHtml(buf, allocator, principal);
        try buf.appendSlice(allocator, "\"><button class=\"button secondary\" type=\"submit\">Revoke</button></form></td></tr>");
        shown += 1;
    }
    if (shown == 0) try appendEmptyCell(buf, allocator, 4, "No role grants found.");
    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
}

fn appendDeviceTable(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, csrf_token: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="panel access-table-panel">
        \\  <div class="section-head"><div><p class="eyebrow">Identity</p><h1>Devices</h1></div></div>
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Principal</th><th>Device</th><th>Status</th><th>Fingerprint</th><th>Public Key</th><th>Actions</th></tr></thead>
        \\      <tbody>
    );
    var stmt = try db.prepare(
        \\SELECT principal, device, key_fingerprint, public_key, COALESCE(revoked_event_hash, '')
        \\FROM identity_devices
        \\ORDER BY principal, device, key_fingerprint
    );
    defer stmt.deinit();
    var shown: usize = 0;
    while (try stmt.step()) {
        const principal = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(principal);
        const device = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(device);
        const fingerprint = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(fingerprint);
        const public_key = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(public_key);
        const revoked_event_hash = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(revoked_event_hash);
        const active = revoked_event_hash.len == 0;
        try appendTemplate(buf, allocator,
            \\<tr><td><strong>{principal}</strong></td><td>{device}</td><td><span class="{classes}">{status}</span></td><td><code>{fingerprint}</code></td><td><code>{public_key}</code></td><td>
        , .{
            .principal = principal,
            .device = device,
            .classes = shared.classes("access-device-status", &.{shared.class("revoked", !active)}),
            .status = if (active) "active" else "revoked",
            .fingerprint = fingerprint,
            .public_key = public_key[0..@min(public_key.len, 48)],
        });
        if (active) {
            try buf.appendSlice(allocator, "<form class=\"access-row-form\" method=\"post\" action=\"/access/devices\"><input type=\"hidden\" name=\"action\" value=\"revoke-device\">");
            try appendCsrfInput(buf, allocator, csrf_token);
            try buf.appendSlice(allocator, "<input type=\"hidden\" name=\"principal\" value=\"");
            try shared.appendHtml(buf, allocator, principal);
            try buf.appendSlice(allocator, "\"><input type=\"hidden\" name=\"device\" value=\"");
            try shared.appendHtml(buf, allocator, device);
            try buf.appendSlice(allocator, "\"><button class=\"button secondary\" type=\"submit\">Revoke</button></form>");
        } else {
            try buf.appendSlice(allocator, "<span class=\"muted\">No action</span>");
        }
        try buf.appendSlice(allocator, "</td></tr>");
        shown += 1;
    }
    if (shown == 0) try appendEmptyCell(buf, allocator, 6, "No devices found.");
    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
}
