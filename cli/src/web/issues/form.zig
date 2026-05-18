const std = @import("std");
const index = @import("../../index.zig");
const issue = @import("../../issue.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const util = @import("../../util.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const ensureIndex = index.ensureIndex;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;

pub const LabelOption = struct {
    name: []u8,
    color: []u8,

    pub fn deinit(self: *LabelOption, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.color);
    }
};

pub const AssigneeOption = struct {
    name: []u8,

    pub fn deinit(self: *AssigneeOption, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const IssueFormPickerOptions = struct {
    labels: std.ArrayList(LabelOption) = .empty,
    assignees: std.ArrayList(AssigneeOption) = .empty,

    pub fn deinit(self: *IssueFormPickerOptions, allocator: Allocator) void {
        for (self.labels.items) |*label| label.deinit(allocator);
        self.labels.deinit(allocator);
        for (self.assignees.items) |*assignee| assignee.deinit(allocator);
        self.assignees.deinit(allocator);
    }
};

pub fn renderIssueForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
    labels_value: []const u8,
    assignees_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var picker_options = loadIssueFormPickerOptions(allocator, repo) catch IssueFormPickerOptions{};
    defer picker_options.deinit(allocator);

    var selected_labels = try splitCommaFields(allocator, labels_value);
    defer selected_labels.deinit(allocator);
    var selected_assignees = try splitCommaFields(allocator, assignees_value);
    defer selected_assignees.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "New Issue", "issues");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Issues", "New Issue", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash error">{message}</div>
        , .{ .message = message });
    }
    try appendTemplate(&buf, allocator,
        \\  <form method="post" action="/issues" class="issue-form">
        \\    <label>Title<input name="title" value="{title_value}" autofocus required></label>
        \\    <label>Body</label>
    , .{
        .title_value = title_value,
    });
    try shared.appendMarkdownEditor(&buf, allocator, .{
        .rows = 8,
        .placeholder = "Describe the issue",
        .value = body_value,
        .required = false,
    });
    try appendTemplate(&buf, allocator,
        \\    <div class="grid two">
    , .{});
    try appendIssueFormLabelsPicker(&buf, allocator, picker_options.labels.items, selected_labels.items, labels_value);
    try appendIssueFormAssigneesPicker(&buf, allocator, picker_options.assignees.items, selected_assignees.items, assignees_value);
    try buf.appendSlice(allocator,
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/issues">Cancel</a>
        \\      <button class="button primary" type="submit">Create issue</button>
        \\    </div>
        \\  </form>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn loadIssueFormPickerOptions(allocator: Allocator, repo: Repo) !IssueFormPickerOptions {
    try ensureIndex(allocator, repo);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    return loadIssueFormPickerOptionsFromDb(allocator, &db);
}

pub fn loadIssueFormPickerOptionsFromDb(allocator: Allocator, db: *SqliteDb) !IssueFormPickerOptions {
    var options: IssueFormPickerOptions = .{};
    errdefer options.deinit(allocator);

    try loadLabelOptions(allocator, db, &options.labels);
    try loadAssigneeOptions(allocator, db, &options.assignees);
    return options;
}

fn loadLabelOptions(allocator: Allocator, db: *SqliteDb, labels: *std.ArrayList(LabelOption)) !void {
    var stmt = try db.prepare(
        \\WITH label_names AS (
        \\  SELECT name AS label FROM label_definitions
        \\  UNION
        \\  SELECT label FROM issue_labels
        \\  UNION
        \\  SELECT label FROM pull_labels
        \\)
        \\SELECT label_names.label, COALESCE(ld.color, '')
        \\FROM label_names
        \\LEFT JOIN label_definitions ld ON ld.name = label_names.label
        \\WHERE label_names.label <> ''
        \\ORDER BY CASE WHEN ld.id IS NULL THEN 1 ELSE 0 END,
        \\         ld.position,
        \\         lower(label_names.label),
        \\         label_names.label
        \\LIMIT 80
    );
    defer stmt.deinit();

    while (try stmt.step()) {
        const name = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(name);
        const color = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(color);
        try labels.append(allocator, .{
            .name = name,
            .color = color,
        });
    }
}

fn loadAssigneeOptions(allocator: Allocator, db: *SqliteDb, assignees: *std.ArrayList(AssigneeOption)) !void {
    var stmt = try db.prepare(
        \\SELECT DISTINCT assignee
        \\FROM (
        \\  SELECT assignee AS assignee FROM issue_assignees
        \\  UNION
        \\  SELECT assignee FROM pull_assignees
        \\  UNION
        \\  SELECT COALESCE(NULLIF(si.display_name, ''), NULLIF(m.source_author, ''), i.author_principal) AS assignee
        \\  FROM issues i
        \\  LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\  LEFT JOIN identities si ON si.id = m.source_identity
        \\  UNION
        \\  SELECT COALESCE(NULLIF(display_name, ''), NULLIF(email, ''), id) AS assignee FROM identities
        \\)
        \\WHERE assignee <> ''
        \\ORDER BY lower(assignee), assignee
        \\LIMIT 80
    );
    defer stmt.deinit();

    while (try stmt.step()) {
        const name = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(name);
        try assignees.append(allocator, .{
            .name = name,
        });
    }
}

pub fn appendIssueFormLabelsPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    labels: []const LabelOption,
    selected: []const []const u8,
    hidden_value: []const u8,
) !void {
    try appendIssueFormPickerStart(buf, allocator, "Labels", "Select labels", "labels", hidden_value, "No labels selected");
    try appendIssueFormSelectedLabels(buf, allocator, labels, selected);
    try appendIssueFormPickerMenuStart(buf, allocator, "Select labels", "Filter labels", "Add label", "label");
    try appendIssueFormPickerGroupStart(buf, allocator, "Selected labels");
    var shown = false;
    for (selected) |label| {
        if (label.len == 0) continue;
        try appendIssueFormLabelOption(buf, allocator, label, labelColorFor(labels, label), true);
        shown = true;
    }
    if (!shown) try appendIssueFormPickerEmpty(buf, allocator, "No labels selected.");
    try appendIssueFormPickerGroupEnd(buf, allocator);

    try appendIssueFormPickerGroupStart(buf, allocator, "Available labels");
    shown = false;
    for (labels) |label| {
        if (containsText(selected, label.name)) continue;
        try appendIssueFormLabelOption(buf, allocator, label.name, label.color, false);
        shown = true;
    }
    if (!shown) try appendIssueFormPickerEmpty(buf, allocator, "No saved labels.");
    try appendIssueFormPickerGroupEnd(buf, allocator);
    try appendIssueFormPickerEnd(buf, allocator);
}

pub fn appendIssueFormAssigneesPicker(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    assignees: []const AssigneeOption,
    selected: []const []const u8,
    hidden_value: []const u8,
) !void {
    try appendIssueFormPickerStart(buf, allocator, "Assignees", "Select assignees", "assignees", hidden_value, "No assignees selected");
    try appendIssueFormSelectedAssignees(buf, allocator, selected);
    try appendIssueFormPickerMenuStart(buf, allocator, "Select assignees", "Filter assignees", "Add assignee", "assignee");
    try appendIssueFormPickerGroupStart(buf, allocator, "Assigned");
    var shown = false;
    for (selected) |assignee| {
        if (assignee.len == 0) continue;
        try appendIssueFormAssigneeOption(buf, allocator, assignee, true);
        shown = true;
    }
    if (!shown) try appendIssueFormPickerEmpty(buf, allocator, "No assignees selected.");
    try appendIssueFormPickerGroupEnd(buf, allocator);

    try appendIssueFormPickerGroupStart(buf, allocator, "Suggestions");
    shown = false;
    for (assignees) |assignee| {
        if (containsText(selected, assignee.name)) continue;
        try appendIssueFormAssigneeOption(buf, allocator, assignee.name, false);
        shown = true;
    }
    if (!shown) try appendIssueFormPickerEmpty(buf, allocator, "No assignee suggestions.");
    try appendIssueFormPickerGroupEnd(buf, allocator);
    try appendIssueFormPickerEnd(buf, allocator);
}

fn appendIssueFormPickerStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    menu_label: []const u8,
    field_name: []const u8,
    hidden_value: []const u8,
    empty_label: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\      <div class="issue-form-field issue-form-picker" data-issue-form-picker data-issue-form-picker-kind="{field_name}" data-issue-form-picker-empty="{empty_label}">
        \\        <div class="issue-form-field-label">{label}</div>
        \\        <input type="hidden" name="{field_name}" value="{hidden_value}" data-issue-form-picker-value>
        \\        <details class="issue-sidebar-menu issue-form-picker-menu" data-popover-menu data-issue-sidebar-menu>
        \\          <summary class="issue-form-picker-control" aria-label="{menu_label}" title="{menu_label}">
        \\            <span class="issue-form-picker-selected" data-issue-form-picker-selected>
    , .{
        .label = label,
        .field_name = field_name,
        .hidden_value = hidden_value,
        .empty_label = empty_label,
        .menu_label = menu_label,
    });
}

fn appendIssueFormPickerMenuStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    menu_label: []const u8,
    placeholder: []const u8,
    button_label: []const u8,
    add_label: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\            </span>
        \\            <span class="issue-form-picker-caret" aria-hidden="true"></span>
        \\          </summary>
        \\          <div class="issue-sidebar-popover issue-form-picker-popover" role="dialog" aria-label="{menu_label}">
        \\            <div class="issue-sidebar-popover-title">{menu_label}</div>
        \\            <div class="issue-sidebar-add-form issue-sidebar-menu-form issue-form-picker-add">
        \\              <label class="issue-sidebar-menu-input"><span aria-hidden="true"></span><input placeholder="{placeholder}" aria-label="{placeholder}" autocomplete="off" data-issue-sidebar-filter data-issue-form-picker-entry></label>
        \\              <button type="button" data-issue-form-picker-add aria-label="{button_label}">{button_label}</button>
        \\            </div>
        \\            <div class="issue-form-picker-custom" data-issue-form-picker-custom-options hidden aria-label="Custom {add_label} selections"></div>
    , .{
        .menu_label = menu_label,
        .placeholder = placeholder,
        .button_label = button_label,
        .add_label = add_label,
    });
}

fn appendIssueFormPickerEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\          </div>
        \\        </details>
        \\      </div>
    );
}

fn appendIssueFormPickerGroupStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\            <div class="issue-sidebar-menu-group"><div class="issue-sidebar-menu-group-title">{title}</div>
    , .{ .title = title });
}

fn appendIssueFormPickerGroupEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "            </div>\n");
}

fn appendIssueFormPickerEmpty(buf: *std.ArrayList(u8), allocator: Allocator, message: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\              <p class="issue-sidebar-menu-empty" data-sidebar-filter-text="">{message}</p>
    , .{ .message = message });
}

fn appendIssueFormSelectedLabels(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    labels: []const LabelOption,
    selected: []const []const u8,
) !void {
    var shown = false;
    for (selected) |label| {
        if (label.len == 0) continue;
        try buf.appendSlice(allocator, "<span class=\"issue-form-selected-item\">");
        try appendIssueLabel(buf, allocator, label, labelColorFor(labels, label));
        try buf.appendSlice(allocator, "</span>");
        shown = true;
    }
    if (!shown) try appendIssueFormPickerPlaceholder(buf, allocator, "No labels selected");
}

fn appendIssueFormSelectedAssignees(buf: *std.ArrayList(u8), allocator: Allocator, selected: []const []const u8) !void {
    var shown = false;
    for (selected) |assignee| {
        if (assignee.len == 0) continue;
        try buf.appendSlice(allocator, "<span class=\"issue-form-selected-item issue-form-selected-person\">");
        try shared.appendAvatar(buf, allocator, assignee, "");
        try appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-primary\">{assignee}</span></span>", .{
            .assignee = assignee,
        });
        shown = true;
    }
    if (!shown) try appendIssueFormPickerPlaceholder(buf, allocator, "No assignees selected");
}

fn appendIssueFormPickerPlaceholder(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator, "<span class=\"issue-form-picker-placeholder\">{label}</span>", .{ .label = label });
}

fn appendIssueFormLabelOption(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    color: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try appendTemplate(buf, allocator,
        \\              <button class="issue-sidebar-picker-row issue-form-picker-option{state_class}" type="button" data-issue-form-picker-option data-sidebar-filter-text="{label}" data-value="{label}" aria-pressed="{pressed}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-form-picker-option-content" data-issue-form-picker-content>
    , .{
        .state_class = state_class,
        .pressed = if (selected) "true" else "false",
        .label = label,
    });
    try appendIssueLabel(buf, allocator, label, color);
    try buf.appendSlice(allocator, "</span></button>");
}

fn appendIssueFormAssigneeOption(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    assignee: []const u8,
    selected: bool,
) !void {
    const state_class: []const u8 = if (selected) " is-selected" else "";
    try appendTemplate(buf, allocator,
        \\              <button class="issue-sidebar-picker-row issue-form-picker-option{state_class}" type="button" data-issue-form-picker-option data-sidebar-filter-text="{assignee}" data-value="{assignee}" aria-pressed="{pressed}"><span class="issue-sidebar-picker-check" aria-hidden="true"></span><span class="issue-form-picker-option-content" data-issue-form-picker-content>
    , .{
        .state_class = state_class,
        .pressed = if (selected) "true" else "false",
        .assignee = assignee,
    });
    try shared.appendAvatar(buf, allocator, assignee, "");
    try appendTemplate(buf, allocator, "<span class=\"issue-sidebar-picker-primary\">{assignee}</span></span></button>", .{
        .assignee = assignee,
    });
}

fn labelColorFor(labels: []const LabelOption, label: []const u8) []const u8 {
    for (labels) |option| {
        if (std.mem.eql(u8, option.name, label)) return option.color;
    }
    return "";
}

fn containsText(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn appendIssueLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, color: []const u8) !void {
    if (validHexColor(color)) {
        try appendTemplate(buf, allocator,
            \\<span class="issue-label label-custom" style="--label-color: {color}">{label}</span>
        , .{
            .color = color,
            .label = label,
        });
        return;
    }

    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
}

fn validHexColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn issueLabelKind(label: []const u8) []const u8 {
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

pub fn renderIssueFormFromTarget(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const title = try queryValueOwned(allocator, target, "title");
    defer if (title) |value| allocator.free(value);
    const body = try queryValueOwned(allocator, target, "body");
    defer if (body) |value| allocator.free(value);
    const labels = try queryValueOwned(allocator, target, "labels");
    defer if (labels) |value| allocator.free(value);
    const assignees = try queryValueOwned(allocator, target, "assignees");
    defer if (assignees) |value| allocator.free(value);

    return renderIssueForm(
        allocator,
        repo,
        null,
        title orelse "",
        body orelse "",
        labels orelse "",
        assignees orelse "",
    );
}

pub fn handleIssuePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const labels_owned = (try formValueOwned(allocator, form_body, "labels")) orelse try allocator.dupe(u8, "");
    defer allocator.free(labels_owned);
    const assignees_owned = (try formValueOwned(allocator, form_body, "assignees")) orelse try allocator.dupe(u8, "");
    defer allocator.free(assignees_owned);

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const body = try renderIssueForm(allocator, repo, "Title is required.", title_owned, body_owned, labels_owned, assignees_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    var labels = try splitCommaFields(allocator, labels_owned);
    defer labels.deinit(allocator);
    var assignees = try splitCommaFields(allocator, assignees_owned);
    defer assignees.deinit(allocator);

    createIssueOpenedEvent(allocator, title, body_owned, labels.items, assignees.items) catch |err| {
        const message = shared.writeFailureMessage(err, "Could not create the issue. Check that Gitomi is initialized and Git commit signing is configured.");
        const body = try renderIssueForm(
            allocator,
            repo,
            message,
            title_owned,
            body_owned,
            labels_owned,
            assignees_owned,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/issues");
}

pub fn issueTitleFromSubject(subject: []const u8) []const u8 {
    const marker = " #";
    const marker_index = std.mem.indexOf(u8, subject, marker) orelse return subject;
    const after_marker = subject[marker_index + marker.len ..];
    const title_index = std.mem.indexOfScalar(u8, after_marker, ' ') orelse return subject;
    const title = std.mem.trim(u8, after_marker[title_index + 1 ..], " \t\r\n");
    return if (title.len == 0) subject else title;
}

pub fn formValueOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !?[]u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

pub fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

pub fn percentDecodeForm(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '+' => try buf.append(allocator, ' '),
            '%' => {
                if (i + 2 >= value.len) return error.InvalidFormEncoding;
                const hi = hexValue(value[i + 1]) orelse return error.InvalidFormEncoding;
                const lo = hexValue(value[i + 2]) orelse return error.InvalidFormEncoding;
                try buf.append(allocator, (hi << 4) | lo);
                i += 2;
            },
            else => |c| try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

pub fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "web form decoding handles spaces and escapes" {
    const decoded = try percentDecodeForm(std.testing.allocator, "hello+local%2Fworld%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello local/world!", decoded);

    const value = (try formValueOwned(std.testing.allocator, "title=First+issue&labels=bug%2Cdocs", "labels")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("bug,docs", value);
}

test "web issue titles come from issue opened subjects" {
    try std.testing.expectEqualStrings("Indexed issue", issueTitleFromSubject("issue.opened #018f000 Indexed issue"));
    try std.testing.expectEqualStrings("custom subject", issueTitleFromSubject("custom subject"));
}
