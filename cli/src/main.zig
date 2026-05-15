const cli = @import("cli.zig");

pub fn main() void {
    cli.main();
}

test {
    _ = @import("json_writer.zig");
    _ = @import("util.zig");
    _ = @import("repo.zig");
    _ = @import("event.zig");
    _ = @import("event_writer.zig");
    _ = @import("index.zig");
    _ = @import("comment.zig");
    _ = @import("reaction.zig");
    _ = @import("pull.zig");
    _ = @import("work_items.zig");
    _ = @import("project.zig");
    _ = @import("milestone.zig");
    _ = @import("rbac.zig");
    _ = @import("actions.zig");
    _ = @import("runs.zig");
    _ = @import("sync.zig");
    _ = @import("github.zig");
    _ = @import("web.zig");
}
