const std = @import("std");
const index = @import("../../index.zig");
const shared = @import("../shared.zig");
const zwf = @import("../../zwf.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const appendTemplate = shared.appendTemplate;

const ReactionChoice = struct {
    value: []const u8,
    label: []const u8,
    title: []const u8,
};

const ReactionSummary = struct {
    emoji: []u8,
    count: i64,
    reacted: bool,

    fn deinit(self: *ReactionSummary, allocator: Allocator) void {
        allocator.free(self.emoji);
    }
};

const reaction_choices = [_]ReactionChoice{
    .{ .value = "\xF0\x9F\x91\x8D", .label = "\xF0\x9F\x91\x8D", .title = "Thumbs up" },
    .{ .value = "\xF0\x9F\x91\x8E", .label = "\xF0\x9F\x91\x8E", .title = "Thumbs down" },
    .{ .value = "\xF0\x9F\x98\x84", .label = "\xF0\x9F\x98\x84", .title = "Laugh" },
    .{ .value = "\xF0\x9F\x8E\x89", .label = "\xF0\x9F\x8E\x89", .title = "Hooray" },
    .{ .value = "\xF0\x9F\x98\x95", .label = "\xF0\x9F\x98\x95", .title = "Confused" },
    .{ .value = "\xE2\x9D\xA4\xEF\xB8\x8F", .label = "\xE2\x9D\xA4\xEF\xB8\x8F", .title = "Heart" },
    .{ .value = "\xF0\x9F\x9A\x80", .label = "\xF0\x9F\x9A\x80", .title = "Rocket" },
    .{ .value = "\xF0\x9F\x91\x80", .label = "\xF0\x9F\x91\x80", .title = "Eyes" },
};

pub fn appendBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    raw_issue_ref: []const u8,
    target_ref: []const u8,
    current_actor: ?[]const u8,
    csrf_token: []const u8,
) !void {
    var reactions: std.ArrayList(ReactionSummary) = .empty;
    defer {
        for (reactions.items) |*item| item.deinit(allocator);
        reactions.deinit(allocator);
    }

    try buf.appendSlice(allocator, "<div class=\"reaction-bar\">");
    var stmt = try db.prepare(
        \\SELECT emoji, COUNT(DISTINCT actor_principal),
        \\       SUM(CASE WHEN actor_principal = ? THEN 1 ELSE 0 END)
        \\FROM reactions
        \\WHERE object_kind = ? AND object_id = ?
        \\GROUP BY emoji
        \\ORDER BY MIN(created_at), emoji
    );
    defer stmt.deinit();
    try stmt.bindText(1, current_actor orelse "");
    try stmt.bindText(2, object_kind);
    try stmt.bindText(3, object_id);

    while (try stmt.step()) {
        const emoji = try stmt.columnTextDup(allocator, 0);
        const count = stmt.columnInt64(1);
        const reacted = current_actor != null and stmt.columnInt64(2) > 0;
        errdefer allocator.free(emoji);
        try reactions.append(allocator, .{
            .emoji = emoji,
            .count = count,
            .reacted = reacted,
        });
    }

    try appendPicker(buf, allocator, raw_issue_ref, object_kind, target_ref, reactions.items, csrf_token);
    for (reactions.items) |item| {
        try appendButton(buf, allocator, raw_issue_ref, object_kind, target_ref, item.emoji, item.emoji, item.count, item.reacted, csrf_token);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    reactions: []const ReactionSummary,
    csrf_token: []const u8,
) !void {
    try buf.appendSlice(allocator,
        \\<details class="reaction-picker" data-popover-menu>
        \\  <summary class="reaction-add-button" aria-label="Add reaction" title="Add reaction"><span class="reaction-add-icon" aria-hidden="true"></span></summary>
        \\  <div class="reaction-popover" role="menu" aria-label="Add reaction">
    );
    for (reaction_choices) |choice| {
        try appendChoiceButton(buf, allocator, raw_issue_ref, object_kind, target_ref, choice, reactionWasSelected(reactions, choice.value), csrf_token);
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendChoiceButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    choice: ReactionChoice,
    reacted: bool,
    csrf_token: []const u8,
) !void {
    try appendFormOpen(buf, allocator, raw_issue_ref, "reaction-choice-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, choice.value, csrf_token);
    try appendTemplate(buf, allocator,
        \\<button{class_attr} type="submit" role="menuitem" aria-pressed="{pressed}" title="{title}"><span class="reaction-emoji">
    , .{
        .class_attr = shared.classAttr("reaction-choice-button", &.{
            shared.class("selected", reacted),
            shared.class("is-selected", reacted),
        }),
        .pressed = reacted,
        .title = if (reacted) "Remove your reaction" else choice.title,
    });
    try shared.appendHtml(buf, allocator, choice.label);
    try buf.appendSlice(allocator, "</span></button></form>");
}

fn appendButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
    emoji_label: []const u8,
    count: i64,
    reacted: bool,
    csrf_token: []const u8,
) !void {
    try appendFormOpen(buf, allocator, raw_issue_ref, "reaction-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, emoji_value, csrf_token);
    try appendTemplate(buf, allocator,
        \\<button{class_attr} type="submit" aria-pressed="{pressed}" title="{title}"><span class="reaction-emoji">
    , .{
        .class_attr = shared.classAttr("reaction-button", &.{
            shared.class("selected", reacted),
            shared.class("is-selected", reacted),
        }),
        .pressed = reacted,
        .title = if (reacted) "Remove your reaction" else "Add reaction",
    });
    try shared.appendHtml(buf, allocator, emoji_label);
    try appendTemplate(buf, allocator, "</span><span class=\"reaction-count\">{count}</span></button></form>", .{ .count = count });
}

fn appendFormOpen(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_issue_ref: []const u8,
    form_class: []const u8,
    action: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
    csrf_token: []const u8,
) !void {
    try appendTemplate(buf, allocator, "<form class=\"{form_class}\" method=\"post\" action=\"/issues/", .{ .form_class = form_class });
    try shared.appendUrlEncoded(buf, allocator, raw_issue_ref);
    try appendTemplate(buf, allocator,
        \\/comments"><input type="hidden" name="{csrf_field}" value="{csrf_token}"><input type="hidden" name="action" value="{action}"><input type="hidden" name="target_kind" value="{object_kind}">
    , .{
        .csrf_field = zwf.csrf.field_name,
        .csrf_token = csrf_token,
        .action = action,
        .object_kind = object_kind,
    });
    if (target_ref.len != 0) {
        try appendTemplate(buf, allocator,
            \\<input type="hidden" name="target_ref" value="{target_ref}">
        , .{ .target_ref = target_ref });
    }
    try appendTemplate(buf, allocator,
        \\<input type="hidden" name="emoji" value="{emoji_value}">
    , .{ .emoji_value = emoji_value });
}

fn reactionWasSelected(reactions: []const ReactionSummary, emoji: []const u8) bool {
    for (reactions) |item| {
        if (std.mem.eql(u8, item.emoji, emoji)) return item.reacted;
    }
    return false;
}
