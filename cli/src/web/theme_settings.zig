const std = @import("std");

const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;

const ThemeChoice = struct {
    id: []const u8,
    label: []const u8,
    note: []const u8,
    swatch_class: []const u8,
};

const theme_choices = [_]ThemeChoice{
    .{ .id = "gitomi", .label = "Gitomi", .note = "Default", .swatch_class = "theme-swatch-gitomi" },
    .{ .id = "terminal", .label = "Terminal", .note = "Capucine CLI", .swatch_class = "theme-swatch-terminal" },
    .{ .id = "modern", .label = "Modern", .note = "Paper / Glass", .swatch_class = "theme-swatch-modern" },
};

pub fn renderThemePage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Theme", "theme");
    try shared.appendSettingsLayoutStart(&buf, allocator, "theme");
    try buf.appendSlice(allocator, "<section class=\"panel settings-panel theme-panel\" data-theme-settings>");
    try appendSectionHead(&buf, allocator, "Settings", "Theme", null);
    try appendThemeChoices(&buf, allocator);
    try appendCustomThemeEditor(&buf, allocator);
    try buf.appendSlice(allocator, "</section>");
    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendThemeChoices(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<div class="theme-choice-grid" role="radiogroup" aria-label="Theme">
    );
    for (theme_choices) |choice| {
        try appendTemplate(buf, allocator,
            \\  <label class="theme-choice" data-theme-option="{id}">
            \\    <input type="radio" name="gitomi_theme" value="{id}" data-theme-choice>
            \\    <span class="theme-swatch {swatch_class}" aria-hidden="true"><span></span><span></span><span></span></span>
            \\    <span class="theme-choice-copy"><strong>{label}</strong><small>{note}</small></span>
            \\  </label>
        , .{
            .id = choice.id,
            .swatch_class = choice.swatch_class,
            .label = choice.label,
            .note = choice.note,
        });
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendCustomThemeEditor(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<section class="theme-custom-card">
        \\  <div class="theme-custom-head">
        \\    <div>
        \\      <h2>Token Overrides</h2>
        \\    </div>
        \\  </div>
        \\  <label class="theme-custom-css-label" for="theme-custom-css">Semantic token CSS</label>
        \\  <textarea id="theme-custom-css" data-theme-custom-css spellcheck="false" rows="14" placeholder=":root[data-theme=&quot;gitomi&quot;][data-theme-mode=&quot;light&quot;] {
        \\  --surface-page: #101418;
        \\  --surface-panel: #151b20;
        \\  --text-default: #eef5f3;
        \\  --interactive-primary: #76e4d4;
        \\  --font-ui: var(--mono);
        \\  --radius-md: 0px;
        \\}"></textarea>
        \\  <div class="theme-custom-actions">
        \\    <button class="button primary" type="button" data-theme-save-custom>Save overrides</button>
        \\    <button class="button secondary" type="button" data-theme-reset-custom>Reset overrides</button>
        \\  </div>
        \\</section>
    );
}
