const std = @import("std");
const github_live = @import("../providers/github/live.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;

pub fn handleLiveModePost(
    allocator: Allocator,
    stream: @import("compat").net.Stream,
    form_body: []const u8,
    redirect_target: []const u8,
) !void {
    const enabled_owned = (try shared.formValueOwned(allocator, form_body, "enabled")) orelse try allocator.dupe(u8, "false");
    defer allocator.free(enabled_owned);

    if (!github_live.setRuntimeActive(enabledFromFormValue(enabled_owned))) {
        try shared.sendPlainResponse(allocator, stream, 409, "Conflict", "Live mode is not available\n");
        return;
    }

    try shared.sendRedirect(allocator, stream, redirect_target);
}

fn enabledFromFormValue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "on");
}

test "live mode form values parse enabled state" {
    try std.testing.expect(enabledFromFormValue("true"));
    try std.testing.expect(enabledFromFormValue("TRUE"));
    try std.testing.expect(enabledFromFormValue("1"));
    try std.testing.expect(enabledFromFormValue("on"));
    try std.testing.expect(!enabledFromFormValue("false"));
    try std.testing.expect(!enabledFromFormValue(""));
}
