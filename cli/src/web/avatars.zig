const std = @import("std");
const html = @import("html.zig");
const nouns_assets = @import("vendor/nouns-assets/image_data.zig");

const Allocator = std.mem.Allocator;

pub fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try appendAvatarContainer(buf, allocator, "issue-avatar", extra_class, name);
}

pub fn appendUserAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try appendAvatarContainer(buf, allocator, "user-avatar", "", name);
}

fn appendAvatarContainer(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    base_class: []const u8,
    extra_class: []const u8,
    name: []const u8,
) !void {
    try html.appendTemplate(buf, allocator,
        \\<span class="{base_class} nouns-avatar {extra_class}" title="{name}" aria-label="{name}">
    , .{
        .base_class = base_class,
        .extra_class = extra_class,
        .name = name,
    });
    try appendNounsAvatarSvg(buf, allocator, nounsAvatarSeed(name));
    try buf.appendSlice(allocator, "</span>");
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
