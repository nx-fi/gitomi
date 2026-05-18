const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const model = @import("model.zig");
const builders = @import("builders.zig");
const validation = @import("validation.zig");

const Config = repo_mod.Config;
const event_schema = model.event_schema;
const IssueProjectPlacement = model.IssueProjectPlacement;
const buildIssueOpenedJson = builders.buildIssueOpenedJson;
const buildIssueUpdatedJson = builders.buildIssueUpdatedJson;
const buildLabelCreatedJson = builders.buildLabelCreatedJson;
const buildLabelUpdatedJson = builders.buildLabelUpdatedJson;
const buildProjectUpdatedJson = builders.buildProjectUpdatedJson;
const buildPullMergedJsonWithMetadata = builders.buildPullMergedJsonWithMetadata;
const validateEventEnvelope = validation.validateEventEnvelope;
const parseValidatedEnvelope = validation.parseValidatedEnvelope;

test "issue opened event json contains required envelope fields" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const labels = [_][]const u8{"bug"};
    const assignees = [_][]const u8{"alice"};
    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "Smoke",
        "Body",
        &labels,
        &assignees,
    );
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(event_schema, root.get("$schema").?.string);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("seq").?.integer);
    try std.testing.expectEqualStrings("issue", root.get("object").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("Smoke", root.get("payload").?.object.get("title").?.string);
}

test "issue opened event json passes envelope validation" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "Smoke",
        "",
        &.{},
        &.{},
    );
    defer std.testing.allocator.free(body);

    try validateEventEnvelope(std.testing.allocator, "test-commit", body);
}

test "label order events use priority payload" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildLabelCreatedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "bug",
        "",
        "#d73a4a",
        100,
    );
    defer std.testing.allocator.free(body);

    try validateEventEnvelope(std.testing.allocator, "test-commit", body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try std.testing.expect(payload.get("position") == null);
    try std.testing.expectEqual(@as(i64, 100), payload.get("priority").?.integer);
}

test "label updated validation accepts legacy position payload" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildLabelUpdatedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        .{ .priority = 150 },
    );
    defer std.testing.allocator.free(body);

    const legacy = try std.testing.allocator.dupe(u8, body);
    defer std.testing.allocator.free(legacy);
    const priority_field = "\"priority\":150";
    const position_field = "\"position\":150";
    const offset = std.mem.indexOf(u8, legacy, priority_field).?;
    @memcpy(legacy[offset .. offset + position_field.len], position_field);

    try validateEventEnvelope(std.testing.allocator, "test-commit", legacy);
}

test "pull merged event json records confirmed remote publication" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildPullMergedJsonWithMetadata(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "cccccccccccccccccccccccccccccccccccccccc",
        null,
        .{
            .base_oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .head_oid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .remote = "origin",
            .remote_ref = "refs/heads/main",
        },
    );
    defer std.testing.allocator.free(body);

    try validateEventEnvelope(std.testing.allocator, "test-commit", body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", payload.get("base_oid").?.string);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", payload.get("head_oid").?.string);
    try std.testing.expectEqualStrings("origin", payload.get("remote").?.string);
    try std.testing.expectEqualStrings("refs/heads/main", payload.get("remote_ref").?.string);
}

test "issue updated event json supports milestone and projects" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const projects = [_]IssueProjectPlacement{.{ .project = "Roadmap", .column = "Doing" }};
    const body = try buildIssueUpdatedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        .{ .milestone = "v2.0", .projects = projects[0..] },
    );
    defer std.testing.allocator.free(body);

    var envelope = try parseValidatedEnvelope(std.testing.allocator, body);
    defer envelope.deinit();
    try std.testing.expectEqualStrings("issue.updated", envelope.event_type);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("v2.0", payload.get("milestone").?.string);
    const project = payload.get("projects").?.array.items[0].object;
    try std.testing.expectEqualStrings("Roadmap", project.get("project").?.string);
    try std.testing.expectEqualStrings("Doing", project.get("column").?.string);
}

test "project updated event json supports update health" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildProjectUpdatedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000005",
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "2026-05-13T18:30:59Z",
        .{},
        .{ .update_health = "at_risk", .update_body = "Needs attention" },
    );
    defer std.testing.allocator.free(body);

    var envelope = try parseValidatedEnvelope(std.testing.allocator, body);
    defer envelope.deinit();
    try std.testing.expectEqualStrings("project.updated", envelope.event_type);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("at_risk", payload.get("update_health").?.string);
    try std.testing.expectEqualStrings("Needs attention", payload.get("update_body").?.string);
}

test "validated envelope rejects oversized payload fields and arrays" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const oversized_title = try std.testing.allocator.alloc(u8, git.max_payload_title_bytes + 1);
    defer std.testing.allocator.free(oversized_title);
    @memset(oversized_title, 'a');

    const oversized_body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        oversized_title,
        "",
        &.{},
        &.{},
    );
    defer std.testing.allocator.free(oversized_body);
    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, oversized_body));

    const labels = try std.testing.allocator.alloc([]const u8, git.max_payload_collection_items + 1);
    defer std.testing.allocator.free(labels);
    for (labels) |*label| label.* = "bug";

    const oversized_array_body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "Smoke",
        "",
        labels,
        &.{},
    );
    defer std.testing.allocator.free(oversized_array_body);
    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, oversized_array_body));
}

test "validated envelope rejects known event with missing required payload" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "issue.opened",
        \\  "object": {
        \\    "kind": "issue",
        \\    "id": "018f0000-0000-7000-8000-000000000003"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {}
        \\}
    ;

    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, body));
}

test "acl object id targets principal instead of uuid" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "acl.role_granted",
        \\  "object": {
        \\    "kind": "acl",
        \\    "id": "acl:bob"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {
        \\    "principal": "bob",
        \\    "role": "maintainer"
        \\  }
        \\}
    ;

    var envelope = try parseValidatedEnvelope(std.testing.allocator, body);
    defer envelope.deinit();
    try std.testing.expectEqualStrings("acl:bob", envelope.object_id);
}

test "identity object id must match principal and device payload" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "identity.device_revoked",
        \\  "object": {
        \\    "kind": "identity",
        \\    "id": "identity:bob:phone"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {
        \\    "principal": "bob",
        \\    "device": "laptop"
        \\  }
        \\}
    ;

    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, body));
}

test "validated envelope rejects pull state_set merged" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "pull.state_set",
        \\  "object": {
        \\    "kind": "pull",
        \\    "id": "018f0000-0000-7000-8000-000000000003"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {
        \\    "state": "merged"
        \\  }
        \\}
    ;

    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, body));
}

test "validated envelope rejects pull updated merged" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "pull.updated",
        \\  "object": {
        \\    "kind": "pull",
        \\    "id": "018f0000-0000-7000-8000-000000000003"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {
        \\    "state": "merged"
        \\  }
        \\}
    ;

    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, body));
}
