const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const sync = @import("../sync.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendEmptyCell = shared.appendEmptyCell;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const gitChecked = git.gitChecked;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;

const FlashKind = enum {
    success,
    failure,
};

const Flash = struct {
    kind: FlashKind,
    message: []const u8,
};

const RefScope = struct {
    label: []const u8,
    detail: []const u8,
    class: []const u8,
};

pub fn renderRefsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const flash: ?Flash = if (hasQueryToken(target, "sync=ok"))
        .{ .kind = .success, .message = "Sync completed against origin." }
    else
        null;
    return renderRefsPageWithFlash(allocator, repo, flash);
}

pub fn handleRefsSyncPost(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    sync.syncPull(allocator, "origin") catch |err| {
        try sendSyncFailure(allocator, repo, stream, err);
        return;
    };
    sync.syncPush(allocator, "origin") catch |err| {
        try sendSyncFailure(allocator, repo, stream, err);
        return;
    };
    try sendRedirect(allocator, stream, "/refs?sync=ok");
}

fn sendSyncFailure(allocator: Allocator, repo: Repo, stream: std.net.Stream, err: anyerror) !void {
    const message = try std.fmt.allocPrint(allocator, "Sync failed: {s}. Check that origin is reachable and the Gitomi refs are valid.", .{@errorName(err)});
    defer allocator.free(message);
    const body = try renderRefsPageWithFlash(allocator, repo, .{ .kind = .failure, .message = message });
    defer allocator.free(body);
    try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
}

fn renderRefsPageWithFlash(allocator: Allocator, repo: Repo, flash: ?Flash) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Refs", "refs");
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendRefsHeader(&buf, allocator);
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
    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Location</th><th>Ref</th><th>Object</th><th>Updated</th></tr></thead>
        \\      <tbody>
    );

    const refs = gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname:short)%09%(committerdate:relative)",
        "refs/heads",
        "refs/remotes",
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
        const scope = classifyRef(ref);
        try appendTemplate(&buf, allocator,
            \\<tr><td><span class="ref-scope ref-scope-{class}">{scope}</span><span class="ref-scope-detail">{detail}</span></td><td><code>{ref}</code></td><td><code>{oid}</code></td><td>{updated}</td></tr>
        , .{
            .class = scope.class,
            .scope = scope.label,
            .detail = scope.detail,
            .ref = ref,
            .oid = oid,
            .updated = updated,
        });
        shown += 1;
    }

    if (shown == 0) {
        try appendEmptyCell(&buf, allocator, 4, "No refs found.");
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

fn appendRefsHeader(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<div class="section-head refs-head">
        \\  <div>
        \\    <p class="eyebrow">Git references</p>
        \\    <h1>Branches, Tags, Remote Tracking, and Gitomi Refs</h1>
        \\  </div>
        \\  <form method="post" action="/refs/sync" class="refs-sync-form">
        \\    <button class="button primary refs-sync-button" type="submit" title="Sync Gitomi refs with origin"><span class="button-icon icon-sync" aria-hidden="true"></span><span>Sync</span></button>
        \\  </form>
        \\</div>
    );
}

fn classifyRef(ref: []const u8) RefScope {
    if (std.mem.startsWith(u8, ref, "refs/remotes/")) {
        return .{ .label = "Remote", .detail = "tracking", .class = "remote" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/staging/")) {
        return .{ .label = "Remote", .detail = "staged by sync", .class = "remote" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/quarantine/")) {
        return .{ .label = "Local", .detail = "quarantined", .class = "local" };
    }
    if (std.mem.eql(u8, ref, "refs/gitomi/genesis")) {
        return .{ .label = "Gitomi", .detail = "trust root", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/inbox/")) {
        return .{ .label = "Gitomi", .detail = "authoritative inbox", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/snapshots/")) {
        return .{ .label = "Local cache", .detail = "snapshot", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/runs/")) {
        return .{ .label = "Local", .detail = "workflow run", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/heads/")) {
        return .{ .label = "Local", .detail = "branch", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/tags/")) {
        return .{ .label = "Local", .detail = "tag", .class = "local" };
    }
    return .{ .label = "Local", .detail = "ref", .class = "local" };
}

fn hasQueryToken(target: []const u8, token: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        if (std.mem.eql(u8, pair, token)) return true;
    }
    return false;
}

test "web refs classify local and remote refs" {
    try std.testing.expectEqualStrings("Local", classifyRef("refs/heads/main").label);
    try std.testing.expectEqualStrings("branch", classifyRef("refs/heads/main").detail);
    try std.testing.expectEqualStrings("Remote", classifyRef("refs/remotes/origin/main").label);
    try std.testing.expectEqualStrings("authoritative inbox", classifyRef("refs/gitomi/inbox/alice/laptop").detail);
    try std.testing.expectEqualStrings("snapshot", classifyRef("refs/gitomi/snapshots/019e").detail);
    try std.testing.expectEqualStrings("staged by sync", classifyRef("refs/gitomi/staging/origin/inbox/alice/laptop").detail);
    try std.testing.expectEqualStrings("quarantined", classifyRef("refs/gitomi/quarantine/origin/inbox/alice/laptop").detail);
}
