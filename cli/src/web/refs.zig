const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const gitChecked = git.gitChecked;

pub fn renderRefsPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Refs", "refs");
    try buf.appendSlice(allocator,
        \\<section class="panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Git references</p>
        \\      <h1>Branches, Tags, and Gitomi Refs</h1>
        \\    </div>
        \\  </div>
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Ref</th><th>Object</th><th>Updated</th></tr></thead>
        \\      <tbody>
    );

    const refs = gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname:short)%09%(committerdate:relative)",
        "refs/heads",
        "refs/tags",
        "refs/gitomi",
    }) catch try allocator.dupe(u8, "");
    defer allocator.free(refs);

    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const ref = cols.next() orelse "";
        const oid = cols.next() orelse "";
        const updated = cols.next() orelse "";
        try appendTemplate(&buf, allocator,
            \\<tr><td><code>{ref}</code></td><td><code>{oid}</code></td><td>{updated}</td></tr>
        , .{
            .ref = ref,
            .oid = oid,
            .updated = updated,
        });
        shown += 1;
    }

    if (shown == 0) {
        try buf.appendSlice(allocator, "<tr><td colspan=\"3\" class=\"empty-cell\">No refs found.</td></tr>");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}
