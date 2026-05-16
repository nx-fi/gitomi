const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const common = @import("common.zig");
const importer = @import("importer.zig");
const exporter = @import("exporter.zig");

const CliError = errors.CliError;
const default_api_url = common.default_api_url;
const GitHubClient = common.GitHubClient;
const githubSizedString = common.githubSizedString;
const githubSubject = common.githubSubject;
const parseRepoSlug = common.parseRepoSlug;
const githubIssueLabels = common.githubIssueLabels;
const githubPullReviewers = common.githubPullReviewers;
const githubAuthorLogin = common.githubAuthorLogin;
const githubMilestoneTitle = common.githubMilestoneTitle;
const githubOptionalUnsignedField = common.githubOptionalUnsignedField;
const singleArrayBody = common.singleArrayBody;
const githubFixtureProjects = common.githubFixtureProjects;
const freeProjectPlacements = common.freeProjectPlacements;
const urlPathEscape = common.urlPathEscape;
const parseResponseNumber = common.parseResponseNumber;
const issueNumberFromContentUrl = importer.issueNumberFromContentUrl;
const githubIssueCreateBody = exporter.githubIssueCreateBody;
const githubPullCreateBody = exporter.githubPullCreateBody;
const githubIssuePatchBody = exporter.githubIssuePatchBody;
const githubCommentBody = exporter.githubCommentBody;

test "github import text capping preserves utf8 and limit" {
    const raw = "hello 世界 this text is too long";
    const capped = try githubSizedString(std.testing.allocator, raw, "", 18);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(capped.len <= 18);
    try std.testing.expect(std.unicode.utf8ValidateSlice(capped));
}

test "github import subject stays within event subject limit" {
    const title = try std.testing.allocator.alloc(u8, git.max_event_subject_bytes * 2);
    defer std.testing.allocator.free(title);
    @memset(title, 'a');

    const subject = try githubSubject(std.testing.allocator, "issue.opened #1234567 GitHub #1 ", title);
    defer std.testing.allocator.free(subject);
    try std.testing.expect(subject.len <= git.max_event_subject_bytes);
}

test "github repo slugs and API paths are validated" {
    const slug = try parseRepoSlug("owner/repo");
    try std.testing.expectEqualStrings("owner", slug.owner);
    try std.testing.expectEqualStrings("repo", slug.name);
    try std.testing.expectEqualStrings("owner/repo", slug.slug);

    try std.testing.expectError(CliError.InvalidArgument, parseRepoSlug("owner"));
    try std.testing.expectError(CliError.InvalidArgument, parseRepoSlug("owner/"));
    try std.testing.expectError(CliError.InvalidArgument, parseRepoSlug("/repo"));

    const client = GitHubClient{
        .allocator = std.testing.allocator,
        .api_url = default_api_url,
        .repo = slug,
        .token = null,
    };
    const path = try client.repoPath(std.testing.allocator, "/issues");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/repos/owner/repo/issues", path);
}

test "github import helpers extract labels authors milestones and counts" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "labels": [{"name":"bug"}, "help wanted"],
        \\  "tags": [{"name":"triage"}],
        \\  "requested_reviewers": [{"login":"alice"}],
        \\  "reviewers": ["bob"],
        \\  "user": {"login": "carol"},
        \\  "milestone": {"title": "v1"},
        \\  "commits": 3,
        \\  "deletions": -1
        \\}
    , .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const labels = try githubIssueLabels(std.testing.allocator, root);
    defer git.freeStringList(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 3), labels.len);
    try std.testing.expectEqualStrings("bug", labels[0]);
    try std.testing.expectEqualStrings("help wanted", labels[1]);
    try std.testing.expectEqualStrings("triage", labels[2]);

    const reviewers = try githubPullReviewers(std.testing.allocator, root);
    defer git.freeStringList(std.testing.allocator, reviewers);
    try std.testing.expectEqual(@as(usize, 2), reviewers.len);
    try std.testing.expectEqualStrings("alice", reviewers[0]);
    try std.testing.expectEqualStrings("bob", reviewers[1]);

    try std.testing.expectEqualStrings("carol", githubAuthorLogin(root).?);
    try std.testing.expectEqualStrings("v1", githubMilestoneTitle(root).?);
    try std.testing.expectEqual(@as(?u64, 3), githubOptionalUnsignedField(root, &.{"commits"}));
    try std.testing.expect(githubOptionalUnsignedField(root, &.{"deletions"}) == null);
}

test "github export request body builders include supported fields" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "title": "Fix bug",
        \\  "body": "Details",
        \\  "state": "closed",
        \\  "labels": ["bug", "ci"],
        \\  "assignees": ["alice"],
        \\  "base_ref": "main",
        \\  "head_ref": "feature",
        \\  "draft": true
        \\}
    , .{});
    defer parsed.deinit();
    const payload = parsed.value.object;

    const issue_body = try githubIssueCreateBody(std.testing.allocator, payload);
    defer std.testing.allocator.free(issue_body);
    try std.testing.expectEqualStrings("{\"title\":\"Fix bug\",\"body\":\"Details\",\"labels\":[\"bug\",\"ci\"],\"assignees\":[\"alice\"]}", issue_body);

    const pull_body = try githubPullCreateBody(std.testing.allocator, payload);
    defer std.testing.allocator.free(pull_body);
    try std.testing.expectEqualStrings("{\"title\":\"Fix bug\",\"body\":\"Details\",\"base\":\"main\",\"head\":\"feature\",\"draft\":true}", pull_body);

    const patch_body = (try githubIssuePatchBody(std.testing.allocator, payload)).?;
    defer std.testing.allocator.free(patch_body);
    try std.testing.expectEqualStrings("{\"title\":\"Fix bug\",\"body\":\"Details\",\"state\":\"closed\"}", patch_body);

    const comment_body = try githubCommentBody(std.testing.allocator, "hello");
    defer std.testing.allocator.free(comment_body);
    try std.testing.expectEqualStrings("{\"body\":\"hello\"}", comment_body);

    const labels_body = try singleArrayBody(std.testing.allocator, "labels", "needs/triage");
    defer std.testing.allocator.free(labels_body);
    try std.testing.expectEqualStrings("{\"labels\":[\"needs/triage\"]}", labels_body);

    var empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer empty.deinit();
    try std.testing.expect((try githubIssuePatchBody(std.testing.allocator, empty.value.object)) == null);
}

test "github fixture project placement combines object and root mappings" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "issue": {
        \\    "number": 42,
        \\    "projects": ["Roadmap/Doing", {"project":"Backlog","column":"Todo"}]
        \\  },
        \\  "projects": {
        \\    "issue:42": [{"name":"Global","status":"Done"}]
        \\  }
        \\}
    , .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const issue = root.get("issue").?.object;

    const projects = try githubFixtureProjects(std.testing.allocator, root, "issue", 42, issue);
    defer freeProjectPlacements(std.testing.allocator, projects);
    try std.testing.expectEqual(@as(usize, 3), projects.len);
    try std.testing.expectEqualStrings("Roadmap", projects[0].project);
    try std.testing.expectEqualStrings("Doing", projects[0].column);
    try std.testing.expectEqualStrings("Backlog", projects[1].project);
    try std.testing.expectEqualStrings("Todo", projects[1].column);
    try std.testing.expectEqualStrings("Global", projects[2].project);
    try std.testing.expectEqualStrings("Done", projects[2].column);
}

test "github URL and response parsing helpers handle edge cases" {
    const escaped = try urlPathEscape(std.testing.allocator, "bug needs/triage");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("bug%20needs%2Ftriage", escaped);

    try std.testing.expectEqual(@as(?i64, 42), issueNumberFromContentUrl("https://api.github.com/repos/owner/repo/issues/42"));
    try std.testing.expect(issueNumberFromContentUrl("https://api.github.com/repos/owner/repo/issues/not-a-number") == null);
    try std.testing.expect(issueNumberFromContentUrl("https://api.github.com/repos/owner/repo/pulls/42") == null);

    try std.testing.expectEqual(@as(?i64, 17), parseResponseNumber(std.testing.allocator, "{\"number\":17}", "number"));
    try std.testing.expect(parseResponseNumber(std.testing.allocator, "[]", "number") == null);
    try std.testing.expect(parseResponseNumber(std.testing.allocator, "not json", "number") == null);
}
