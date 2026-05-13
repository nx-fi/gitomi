const cli = @import("cli.zig");

pub fn main() void {
    cli.main();
}

test {
    _ = @import("json_writer.zig");
    _ = @import("util.zig");
    _ = @import("repo.zig");
    _ = @import("event.zig");
    _ = @import("index.zig");
    _ = @import("comment.zig");
    _ = @import("pull.zig");
    _ = @import("sync.zig");
    _ = @import("web.zig");
}
