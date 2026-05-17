const std = @import("std");
const common = @import("common.zig");
const exporter = @import("exporter.zig");

test "gitlab project refs and API paths are validated" {
    const project = try common.parseProjectRef("group/sub/project");
    try std.testing.expectEqualStrings("group/sub/project", project.path);
    try std.testing.expectError(error.InvalidArgument, common.parseProjectRef(""));

    const client = common.GitLabClient{
        .allocator = std.testing.allocator,
        .api_url = common.default_api_url,
        .project = project,
        .token = null,
    };
    const path = try client.projectPath(std.testing.allocator, "/issues");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/projects/group%2Fsub%2Fproject/issues", path);
}

test "gitlab export request body builders include supported fields" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "title": "Fix bug",
        \\  "body": "Details",
        \\  "state": "closed",
        \\  "labels": ["bug", "ci"],
        \\  "base_ref": "main",
        \\  "head_ref": "feature"
        \\}
    , .{});
    defer parsed.deinit();
    const payload = parsed.value.object;

    const issue_body = try exporter.gitlabIssueCreateBody(std.testing.allocator, payload, &.{});
    defer std.testing.allocator.free(issue_body);
    try std.testing.expectEqualStrings("{\"title\":\"Fix bug\",\"description\":\"Details\",\"labels\":\"bug,ci\"}", issue_body);

    const pull_body = try exporter.gitlabMergeRequestCreateBody(std.testing.allocator, payload, &.{}, &.{});
    defer std.testing.allocator.free(pull_body);
    try std.testing.expectEqualStrings("{\"title\":\"Fix bug\",\"description\":\"Details\",\"target_branch\":\"main\",\"source_branch\":\"feature\",\"labels\":\"bug,ci\"}", pull_body);

    const patch_body = (try exporter.gitlabIssuePatchBody(std.testing.allocator, payload)).?;
    defer std.testing.allocator.free(patch_body);
    try std.testing.expectEqualStrings("{\"title\":\"Fix bug\",\"description\":\"Details\",\"state_event\":\"close\"}", patch_body);

    const note_body = try exporter.gitlabNoteBody(std.testing.allocator, "hello");
    defer std.testing.allocator.free(note_body);
    try std.testing.expectEqualStrings("{\"body\":\"hello\"}", note_body);
}
