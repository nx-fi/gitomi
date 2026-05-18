const std = @import("std");
const avatars = @import("avatars.zig");
const html = @import("html.zig");
const index = @import("../../index.zig");
const response = @import("response.zig");
const web_shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;

pub const TargetKind = enum {
    issue,
    pull,
};

pub const FormContext = struct {
    target: TargetKind,
    raw_ref: []const u8,
    csrf_field: []const u8,
    csrf_token: []const u8,
};

pub fn appendSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try html.appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2></div>
    , .{ .title = title });
}

pub fn appendEditableSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8) !void {
    try html.appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2><details class="issue-sidebar-menu" data-popover-menu data-issue-sidebar-menu><summary aria-label="{menu_label}" title="{menu_label}"><span class="issue-sidebar-menu-icon" aria-hidden="true"></span></summary><div class="issue-sidebar-popover" role="dialog" aria-label="{menu_label}"><div class="issue-sidebar-popover-title">{menu_label}</div>
    , .{
        .title = title,
        .menu_label = menu_label,
    });
}

pub fn appendEditableSectionBodyStart(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div></details></div>");
}

pub fn appendSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

pub fn appendEmptyText(buf: *std.ArrayList(u8), allocator: Allocator, text: []const u8) !void {
    try html.appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{text}</p>", .{ .text = text });
}

pub fn appendMenuFilter(buf: *std.ArrayList(u8), allocator: Allocator, placeholder: []const u8) !void {
    try html.appendTemplate(buf, allocator,
        \\<label class="issue-sidebar-menu-input issue-sidebar-menu-filter"><span aria-hidden="true"></span><input placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter></label>
    , .{ .placeholder = placeholder });
}

pub fn appendMenuGroupStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try html.appendTemplate(buf, allocator,
        \\<div class="issue-sidebar-menu-group"><div class="issue-sidebar-menu-group-title">{title}</div>
    , .{ .title = title });
}

pub fn appendMenuGroupEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</div>");
}

pub fn appendMenuEmpty(buf: *std.ArrayList(u8), allocator: Allocator, message: []const u8) !void {
    try html.appendTemplate(buf, allocator,
        \\<p class="issue-sidebar-menu-empty" data-sidebar-filter-text="">{message}</p>
    , .{ .message = message });
}

pub fn appendAction(buf: *std.ArrayList(u8), allocator: Allocator, context: FormContext) !void {
    try buf.appendSlice(allocator, switch (context.target) {
        .issue => "/issues/",
        .pull => "/pulls/",
    });
    try html.appendUrlEncoded(buf, allocator, context.raw_ref);
    try buf.appendSlice(allocator, "/sidebar");
}

pub fn appendCsrfInput(buf: *std.ArrayList(u8), allocator: Allocator, context: FormContext) !void {
    try html.appendTemplate(buf, allocator,
        \\<input type="hidden" name="{csrf_field}" value="{csrf_token}">
    , .{
        .csrf_field = context.csrf_field,
        .csrf_token = context.csrf_token,
    });
}

pub fn appendHiddenInput(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: []const u8) !void {
    try html.appendTemplate(buf, allocator,
        \\<input type="hidden" name="{name}" value="{value}">
    , .{
        .name = name,
        .value = value,
    });
}

pub fn appendSingleInputForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    context: FormContext,
    action: []const u8,
    input_name: []const u8,
    button_label: []const u8,
    placeholder: []const u8,
) !void {
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-add-form issue-sidebar-menu-form\" method=\"post\" action=\"");
    try appendAction(buf, allocator, context);
    try buf.appendSlice(allocator, "\">");
    try appendCsrfInput(buf, allocator, context);
    try html.appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><label class="issue-sidebar-menu-input"><span aria-hidden="true"></span><input name="{input_name}" placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter></label><button type="submit">{button_label}</button></form>
    , .{
        .action = action,
        .input_name = input_name,
        .placeholder = placeholder,
        .button_label = button_label,
    });
}

pub fn appendValueActionFormStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    context: FormContext,
    action: []const u8,
    input_name: []const u8,
    value: []const u8,
    filter_text: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try buf.appendSlice(allocator, "<form class=\"issue-sidebar-picker-form\" method=\"post\" action=\"");
    try appendAction(buf, allocator, context);
    try buf.appendSlice(allocator, "\">");
    try appendCsrfInput(buf, allocator, context);
    try html.appendTemplate(buf, allocator,
        \\<input type="hidden" name="action" value="{action}"><input type="hidden" name="{input_name}" value="{value}"><button class="issue-sidebar-picker-row{state_class}" type="submit" data-sidebar-filter-text="{filter_text}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span>
    , .{
        .action = action,
        .input_name = input_name,
        .value = value,
        .filter_text = filter_text,
        .state_class = state_class,
    });
}

pub fn appendPersonActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    context: FormContext,
    action: []const u8,
    person: []const u8,
    selected: bool,
) !void {
    try appendValueActionFormStart(buf, allocator, context, action, "value", person, person, selected);
    try appendAvatar(buf, allocator, person, "");
    try html.appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-primary\">{person}</span></button></form>", .{
        .person = person,
    });
}

pub fn appendLabelActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    context: FormContext,
    action: []const u8,
    label: []const u8,
    color: []const u8,
    selected: bool,
) !void {
    try appendValueActionFormStart(buf, allocator, context, action, "value", label, label, selected);
    try appendLabel(buf, allocator, label, color);
    try buf.appendSlice(allocator, "</button></form>");
}

pub fn appendLabelTokenActionRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    context: FormContext,
    action: []const u8,
    label: []const u8,
    color: []const u8,
    selected: bool,
) !void {
    try appendValueActionFormStart(buf, allocator, context, action, "value", label, label, selected);
    try appendLabelToken(buf, allocator, label, color);
    try buf.appendSlice(allocator, "</button></form>");
}

pub fn appendPeopleBody(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    comptime sql_text: []const u8,
    object_id: []const u8,
    empty_text: []const u8,
) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    var shown = false;
    while (try stmt.step()) {
        const person = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendPerson(buf, allocator, person);
        shown = true;
    }
    if (!shown) try appendEmptyText(buf, allocator, empty_text);
}

pub fn appendLabelsBody(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    comptime sql_text: []const u8,
    object_id: []const u8,
    empty_text: []const u8,
) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, object_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const color = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(color);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"issue-sidebar-labels\">");
            shown = true;
        }
        try appendLabelToken(buf, allocator, label, color);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try appendEmptyText(buf, allocator, empty_text);
    }
}

pub fn appendPerson(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person\">");
    try appendAvatar(buf, allocator, name, "");
    try html.appendTemplate(buf, allocator, "<span>{name}</span></div>", .{ .name = name });
}

pub fn appendLabelToken(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, color: []const u8) !void {
    try buf.appendSlice(allocator, "<span class=\"issue-sidebar-token\">");
    try appendLabel(buf, allocator, label, color);
    try buf.appendSlice(allocator, "</span>");
}

pub fn appendLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, color: []const u8) !void {
    if (validHexColor(color)) {
        try html.appendTemplate(buf, allocator,
            \\<span class="issue-label label-custom" style="--label-color: {color}">{label}</span>
        , .{
            .color = color,
            .label = label,
        });
        return;
    }

    try html.appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = labelKind(label),
        .label = label,
    });
}

pub fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try avatars.appendAvatar(buf, allocator, name, extra_class);
}

pub fn validHexColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn requiredValue(allocator: Allocator, stream: std.net.Stream, form_body: []const u8, name: []const u8, message: []const u8) !?[]u8 {
    const owned = (try web_shared.formValueOwned(allocator, form_body, name)) orelse {
        try response.sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    };
    errdefer allocator.free(owned);
    const value = std.mem.trim(u8, owned, " \t\r\n");
    if (value.len == 0) {
        allocator.free(owned);
        try response.sendPlainResponse(allocator, stream, 422, "Unprocessable Entity", message);
        return null;
    }
    if (value.ptr == owned.ptr and value.len == owned.len) return owned;
    const result = try allocator.dupe(u8, value);
    allocator.free(owned);
    return result;
}

fn labelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}
