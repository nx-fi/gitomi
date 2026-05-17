const std = @import("std");
const html = @import("html.zig");
const nouns_assets = @import("../vendor/nouns-assets/image_data.zig");

const Allocator = std.mem.Allocator;

pub fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try appendAvatarContainer(buf, allocator, "issue-avatar", extra_class, name, "");
}

pub fn appendAvatarWithUrl(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, avatar_url: []const u8, extra_class: []const u8) !void {
    try appendAvatarContainer(buf, allocator, "issue-avatar", extra_class, name, avatar_url);
}

pub fn appendGitIdentityAvatar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    name: []const u8,
    email: []const u8,
    avatar_url: []const u8,
    extra_class: []const u8,
) !void {
    try appendGitIdentityAvatarContainer(buf, allocator, "issue-avatar", extra_class, name, email, avatar_url);
}

pub fn appendAvatarWithIdentity(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    github_source: []const u8,
    email_source: []const u8,
    seed_name: []const u8,
    avatar_url: []const u8,
    extra_class: []const u8,
) !void {
    try appendAvatarContainerWithIdentity(buf, allocator, "issue-avatar", extra_class, label, seed_name, avatar_url, github_source, email_source);
}

pub fn appendUserAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try appendAvatarContainer(buf, allocator, "user-avatar", "", name, "");
}

pub fn appendUserAvatarFromGitIdentity(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, email: []const u8, avatar_url: []const u8) !void {
    try appendGitIdentityAvatarContainer(buf, allocator, "user-avatar", "", name, email, avatar_url);
}

fn appendAvatarContainer(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    base_class: []const u8,
    extra_class: []const u8,
    name: []const u8,
    avatar_url: []const u8,
) !void {
    try appendAvatarContainerWithIdentity(buf, allocator, base_class, extra_class, name, name, avatar_url, name, name);
}

fn appendGitIdentityAvatarContainer(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    base_class: []const u8,
    extra_class: []const u8,
    name: []const u8,
    email: []const u8,
    avatar_url: []const u8,
) !void {
    const trimmed_name = std.mem.trim(u8, name, " \t\r\n");
    const trimmed_email = std.mem.trim(u8, email, " \t\r\n<>");
    const label = if (trimmed_name.len != 0) trimmed_name else if (trimmed_email.len != 0) trimmed_email else "Unknown";
    const email_source = if (trimmed_email.len != 0) trimmed_email else label;
    const normalized_email = try normalizedAvatarEmailOwned(allocator, email_source);
    defer if (normalized_email) |value| allocator.free(value);
    const seed_name = normalized_email orelse label;

    try appendAvatarContainerWithIdentity(buf, allocator, base_class, extra_class, label, seed_name, avatar_url, label, email_source);
}

fn appendAvatarContainerWithIdentity(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    base_class: []const u8,
    extra_class: []const u8,
    label: []const u8,
    seed_name: []const u8,
    avatar_url: []const u8,
    github_source: []const u8,
    email_source: []const u8,
) !void {
    const github_login = githubLogin(github_source);
    const gravatar_email = try normalizedAvatarEmailOwned(allocator, email_source);
    defer if (gravatar_email) |email| allocator.free(email);

    try html.appendTemplate(buf, allocator,
        \\<span class="{base_class} nouns-avatar {extra_class}" title="{name}" aria-label="{name}">
    , .{
        .base_class = base_class,
        .extra_class = extra_class,
        .name = label,
    });
    try appendNounsAvatarSvg(buf, allocator, nounsAvatarSeed(seed_name));
    if (avatar_url.len != 0) try appendRemoteAvatarCandidate(buf, allocator, avatar_url, github_login);
    if (github_login) |login| try appendGithubAvatarCandidate(buf, allocator, login);
    if (gravatar_email) |email| try appendGravatarAvatarCandidate(buf, allocator, email);
    try buf.appendSlice(allocator, "</span>");
}

fn appendRemoteAvatarCandidate(buf: *std.ArrayList(u8), allocator: Allocator, avatar_url: []const u8, github_login: ?[]const u8) !void {
    const is_github = isGithubAvatarUrl(avatar_url) and github_login != null;
    try buf.appendSlice(allocator, "<img class=\"avatar-image\" data-avatar-source=\"");
    try buf.appendSlice(allocator, if (is_github) "github" else "remote");
    if (is_github) {
        try buf.appendSlice(allocator, "\" data-avatar-github-login=\"");
        try html.appendHtml(buf, allocator, github_login.?);
    }
    try buf.appendSlice(allocator, "\" src=\"");
    try html.appendHtml(buf, allocator, avatar_url);
    try buf.appendSlice(allocator, "\" alt=\"\" aria-hidden=\"true\" loading=\"lazy\" decoding=\"async\" crossorigin=\"anonymous\">");
}

fn appendGithubAvatarCandidate(buf: *std.ArrayList(u8), allocator: Allocator, login: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<img class="avatar-image" data-avatar-source="github" data-avatar-github-login="
    );
    try html.appendHtml(buf, allocator, login);
    try buf.appendSlice(allocator,
        \\" src="https://github.com/
    );
    try appendUrlPathSegment(buf, allocator, login);
    try buf.appendSlice(allocator,
        \\.png?size=80" alt="" aria-hidden="true" loading="lazy" decoding="async" crossorigin="anonymous">
    );
}

fn appendGravatarAvatarCandidate(buf: *std.ArrayList(u8), allocator: Allocator, email: []const u8) !void {
    var hash: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(email, &hash, .{});

    var hex: [std.crypto.hash.Md5.digest_length * 2]u8 = undefined;
    hexLower(&hex, hash[0..]);

    try html.appendTemplate(buf, allocator,
        \\<img class="avatar-image" data-avatar-source="gravatar" src="https://www.gravatar.com/avatar/{hash}?s=80&amp;d=404" alt="" aria-hidden="true" loading="lazy" decoding="async" crossorigin="anonymous">
    , .{ .hash = hex[0..] });
}

fn githubLogin(name: []const u8) ?[]const u8 {
    if (avatarEmail(name) != null) return null;
    var trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "@")) trimmed = trimmed[1..];
    if (!isGithubLogin(trimmed)) return null;
    return trimmed;
}

fn isGithubLogin(value: []const u8) bool {
    if (value.len == 0 or value.len > 100) return false;
    if (std.mem.endsWith(u8, value, "[bot]")) {
        const prefix = value[0 .. value.len - "[bot]".len];
        return isGithubLoginCore(prefix);
    }
    return value.len <= 39 and isGithubLoginCore(value);
}

fn isGithubLoginCore(value: []const u8) bool {
    if (value.len == 0 or value[0] == '-' or value[value.len - 1] == '-') return false;
    for (value) |c| {
        if ((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-')
        {
            continue;
        }
        return false;
    }
    return true;
}

fn isGithubAvatarUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://avatars.githubusercontent.com/") or
        std.mem.startsWith(u8, value, "http://avatars.githubusercontent.com/") or
        std.mem.startsWith(u8, value, "https://github.com/") or
        std.mem.startsWith(u8, value, "http://github.com/");
}

fn normalizedAvatarEmailOwned(allocator: Allocator, name: []const u8) !?[]u8 {
    const email = avatarEmail(name) orelse return null;
    const normalized = try allocator.alloc(u8, email.len);
    for (email, 0..) |c, i| normalized[i] = std.ascii.toLower(c);
    return normalized;
}

fn avatarEmail(name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return null;
    const candidate = if (std.mem.indexOfScalar(u8, trimmed, '<')) |start| blk: {
        const rest = trimmed[start + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        break :blk std.mem.trim(u8, rest[0..end], " \t\r\n");
    } else trimmed;

    const at = std.mem.indexOfScalar(u8, candidate, '@') orelse return null;
    if (at == 0 or at == candidate.len - 1) return null;
    if (std.mem.indexOfScalar(u8, candidate[at + 1 ..], '@') != null) return null;
    for (candidate) |c| {
        if (std.ascii.isWhitespace(c) or c == '<' or c == '>') return null;
    }
    return candidate;
}

fn appendUrlPathSegment(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if ((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~')
        {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0f]);
        }
    }
}

fn hexLower(out: []u8, bytes: []const u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

const NounsAvatarSeed = struct {
    background: usize,
    body: usize,
    accessory: usize,
    head: usize,
    glasses: usize,
};

fn nounsAvatarSeed(name: []const u8) NounsAvatarSeed {
    const hash = fnv1a64(name);
    return .{
        .background = @intCast(hash % nouns_assets.bgcolors.len),
        .body = @intCast((hash >> 8) % nouns_assets.bodies.len),
        .accessory = @intCast((hash >> 20) % nouns_assets.accessories.len),
        .head = @intCast((hash >> 32) % nouns_assets.heads.len),
        .glasses = @intCast((hash >> 48) % nouns_assets.glasses.len),
    };
}

fn fnv1a64(value: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (value) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn appendNounsAvatarSvg(buf: *std.ArrayList(u8), allocator: Allocator, seed: NounsAvatarSeed) !void {
    try html.appendTemplate(buf, allocator,
        \\<svg class="nouns-avatar-svg" width="320" height="320" viewBox="0 0 320 320" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges">
        \\<rect width="100%" height="100%" fill="#{background}" />
    , .{ .background = nouns_assets.bgcolors[seed.background] });
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.bodies[seed.body]);
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.accessories[seed.accessory]);
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.heads[seed.head]);
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.glasses[seed.glasses]);
    try buf.appendSlice(allocator,
        \\</svg>
    );
}

fn appendNounsAvatarPartSvg(buf: *std.ArrayList(u8), allocator: Allocator, data: []const u8) !void {
    if (!std.mem.startsWith(u8, data, "0x") or data.len < 12) return error.InvalidNounsAsset;

    const top: u16 = try hexByteAt(data, 4);
    const right: u16 = try hexByteAt(data, 6);
    const left: u16 = try hexByteAt(data, 10);
    if (right <= left) return;

    var current_x: u16 = left;
    var current_y: u16 = top;
    var cursor: usize = 12;
    while (cursor + 4 <= data.len) : (cursor += 4) {
        var draw_length: u16 = try hexByteAt(data, cursor);
        const color_index: usize = try hexByteAt(data, cursor + 2);
        while (draw_length > 0) {
            const length = @min(draw_length, right - current_x);
            if (length == 0) return error.InvalidNounsAsset;
            if (color_index != 0) {
                if (color_index >= nouns_assets.palette.len) return error.InvalidNounsAsset;
                try html.appendTemplate(buf, allocator,
                    \\<rect width="{width}" height="10" x="{x}" y="{y}" fill="#{color}" />
                , .{
                    .width = length * 10,
                    .x = current_x * 10,
                    .y = current_y * 10,
                    .color = nouns_assets.palette[color_index],
                });
            }
            current_x += length;
            if (current_x == right) {
                current_x = left;
                current_y += 1;
            }
            draw_length -= length;
        }
    }
}

fn hexByteAt(data: []const u8, offset: usize) !u8 {
    if (offset + 2 > data.len) return error.InvalidNounsAsset;
    return std.fmt.parseInt(u8, data[offset .. offset + 2], 16) catch error.InvalidNounsAsset;
}
