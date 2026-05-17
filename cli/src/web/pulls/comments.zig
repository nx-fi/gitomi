const std = @import("std");
const index = @import("../../index.zig");
const util = @import("../../util.zig");
const work_items = @import("../../work_items.zig");
const issues_page = @import("../issues.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const appendRelativeTime = shared.appendRelativeTime;
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

pub fn appendComments(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    raw_ref: []const u8,
    pull_id: []const u8,
    current_actor: ?[]const u8,
) !void {
    var stmt = try work_items.prepareCommentsStmt(db, "pull", pull_id);
    defer stmt.deinit();
    while (try stmt.step()) {
        const row = try work_items.commentRowFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        const anchor = try std.fmt.allocPrint(allocator, "comment-{s}", .{row.id[0..@min(row.id.len, 7)]});
        defer allocator.free(anchor);
        var comment_ref_buf: [util.short_object_ref_len]u8 = undefined;
        const comment_ref = util.shortObjectRef(&comment_ref_buf, row.id);
        const comment_ref_value = try std.fmt.allocPrint(allocator, "comment:{s}", .{comment_ref});
        defer allocator.free(comment_ref_value);

        try appendTemplate(buf, allocator,
            \\<div class="{classes}" id="{anchor}"><div class="issue-timeline-avatar">
        , .{
            .classes = shared.classes("issue-timeline-item", &.{shared.class("is-reply", row.isReply())}),
            .anchor = anchor,
        });
        try shared.appendAvatarWithUrl(buf, allocator, row.display_author, row.source_avatar_url, "issue-detail-avatar");
        try appendTemplate(buf, allocator,
            \\</div><article class="issue-comment-box comment-card"><header class="issue-comment-head"><div><strong>{author}</strong><span>commented
        , .{
            .author = row.display_author,
        });
        try buf.append(allocator, ' ');
        try appendRelativeTime(buf, allocator, row.created_at);
        try buf.appendSlice(allocator, "</span></div>");
        try issues_page.appendIssueActionMenu(buf, allocator, anchor, comment_ref_value, row.body, !row.redacted and row.body.len != 0, "");
        try buf.appendSlice(allocator, "</header>");
        if (row.isReply()) {
            try buf.appendSlice(allocator, "<p class=\"reply-note\">Reply to ");
            if (row.reply_parent_id.len != 0) {
                var reply_ref_buf: [util.short_object_ref_len]u8 = undefined;
                const reply_ref = util.shortObjectRef(&reply_ref_buf, row.reply_parent_id);
                try appendTemplate(buf, allocator, "comment:{reply_ref}", .{ .reply_ref = reply_ref });
            } else {
                try appendTemplate(buf, allocator, "{reply_parent_hash}", .{ .reply_parent_hash = row.reply_parent_hash[0..@min(row.reply_parent_hash.len, 12)] });
            }
            try buf.appendSlice(allocator, "</p>");
        }
        try buf.appendSlice(allocator, "<div class=\"markdown-body\">");
        if (row.redacted) {
            try buf.appendSlice(allocator, "<p class=\"muted\">Comment redacted.</p>");
        } else {
            try shared.appendMarkdownSource(buf, allocator, row.body, .{});
        }
        try buf.appendSlice(allocator, "</div>");
        try appendReactionBar(buf, allocator, db, "comment", row.id, raw_ref, comment_ref_value, current_actor);
        try buf.appendSlice(allocator, "</article></div>");
    }
}

pub fn appendReactionBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    raw_pull_ref: []const u8,
    target_ref: []const u8,
    current_actor: ?[]const u8,
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

    try appendReactionPicker(buf, allocator, raw_pull_ref, object_kind, target_ref, reactions.items);
    for (reactions.items) |item| {
        try appendReactionButton(buf, allocator, raw_pull_ref, object_kind, target_ref, item.emoji, item.emoji, item.count, item.reacted);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendReactionPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    reactions: []const ReactionSummary,
) !void {
    try buf.appendSlice(allocator,
        \\<details class="reaction-picker" data-popover-menu>
        \\  <summary class="reaction-add-button" aria-label="Add reaction" title="Add reaction"><span class="reaction-add-icon" aria-hidden="true"></span></summary>
        \\  <div class="reaction-popover" role="menu" aria-label="Add reaction">
    );
    for (reaction_choices) |choice| {
        try appendReactionChoiceButton(buf, allocator, raw_pull_ref, object_kind, target_ref, choice, reactionWasSelected(reactions, choice.value));
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendReactionChoiceButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    choice: ReactionChoice,
    reacted: bool,
) !void {
    try appendReactionFormOpen(buf, allocator, raw_pull_ref, "reaction-choice-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, choice.value);
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

fn appendReactionButton(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
    emoji_label: []const u8,
    count: i64,
    reacted: bool,
) !void {
    try appendReactionFormOpen(buf, allocator, raw_pull_ref, "reaction-form", if (reacted) "remove-reaction" else "add-reaction", object_kind, target_ref, emoji_value);
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

fn appendReactionFormOpen(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw_pull_ref: []const u8,
    form_class: []const u8,
    action: []const u8,
    object_kind: []const u8,
    target_ref: []const u8,
    emoji_value: []const u8,
) !void {
    try appendTemplate(buf, allocator, "<form class=\"{form_class}\" method=\"post\" action=\"/pulls/", .{ .form_class = form_class });
    try shared.appendUrlEncoded(buf, allocator, raw_pull_ref);
    try appendTemplate(buf, allocator,
        \\/comments"><input type="hidden" name="action" value="{action}"><input type="hidden" name="target_kind" value="{object_kind}">
    , .{
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

pub fn appendCommentForm(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, current_actor: ?[]const u8) !void {
    try buf.appendSlice(allocator,
        \\<div class="issue-timeline-item issue-comment-form-item">
        \\  <div class="issue-timeline-avatar">
    );
    try shared.appendAvatar(buf, allocator, current_actor orelse "Current user", "issue-detail-avatar issue-comment-form-avatar");
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <form class="issue-comment-box issue-comment-form" method="post" action="/pulls/
    );
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator,
        \\/comments">
        \\  <input type="hidden" name="reply_parent_ref" value="" data-reply-parent-ref>
    );
    try shared.appendMarkdownEditor(buf, allocator, .{});
    try buf.appendSlice(allocator,
        \\  <div class="issue-comment-form-actions">
        \\    <button class="button primary" type="submit">Comment</button>
        \\  </div>
        \\</form>
        \\</div>
    );
}
