const std = @import("std");
const repo_mod = @import("../repo.zig");
const shared = @import("../web/shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;

pub const HtmlBuilder = struct {
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator) HtmlBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HtmlBuilder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn append(self: *HtmlBuilder, value: []const u8) !void {
        try self.buf.appendSlice(self.allocator, value);
    }

    pub fn text(self: *HtmlBuilder, value: []const u8) !void {
        try shared.appendHtml(&self.buf, self.allocator, value);
    }

    pub fn template(self: *HtmlBuilder, comptime markup: []const u8, values: anytype) !void {
        try shared.appendTemplate(&self.buf, self.allocator, markup, values);
    }

    pub fn shellStart(self: *HtmlBuilder, repo: Repo, title: []const u8, active: []const u8) !void {
        try shared.appendShellStart(&self.buf, self.allocator, repo, title, active);
    }

    pub fn shellEnd(self: *HtmlBuilder) !void {
        try shared.appendShellEnd(&self.buf, self.allocator);
    }

    pub fn toOwnedSlice(self: *HtmlBuilder) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }
};

pub fn page(
    allocator: Allocator,
    repo: Repo,
    title: []const u8,
    active: []const u8,
    render_body: *const fn (*HtmlBuilder) anyerror!void,
) ![]u8 {
    var builder = HtmlBuilder.init(allocator);
    errdefer builder.deinit();

    try builder.shellStart(repo, title, active);
    try render_body(&builder);
    try builder.shellEnd();
    return builder.toOwnedSlice();
}
