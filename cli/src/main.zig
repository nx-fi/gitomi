const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init.Minimal) void {
    cli.main(init.args);
}

test {
    _ = @import("json_writer.zig");
    _ = @import("util.zig");
    _ = @import("repo.zig");
    _ = @import("event.zig");
    _ = @import("inbox_commit.zig");
    _ = @import("event_writer.zig");
    _ = @import("index.zig");
    _ = @import("comment.zig");
    _ = @import("cmd_common.zig");
    _ = @import("reaction.zig");
    _ = @import("pr.zig");
    _ = @import("work_items.zig");
    _ = @import("project.zig");
    _ = @import("milestone.zig");
    _ = @import("rbac.zig");
    _ = @import("actions.zig");
    _ = @import("runs.zig");
    _ = @import("quarantine.zig");
    _ = @import("sync.zig");
    _ = @import("fsck.zig");
    _ = @import("providers.zig");
    _ = @import("web.zig");
}
