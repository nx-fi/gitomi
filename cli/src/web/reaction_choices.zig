pub const Choice = struct {
    value: []const u8,
    label: []const u8,
    title: []const u8,
};

pub const choices = [_]Choice{
    .{ .value = "\xF0\x9F\x91\x8D", .label = "\xF0\x9F\x91\x8D", .title = "Thumbs up" },
    .{ .value = "\xF0\x9F\x91\x8E", .label = "\xF0\x9F\x91\x8E", .title = "Thumbs down" },
    .{ .value = "\xF0\x9F\x98\x84", .label = "\xF0\x9F\x98\x84", .title = "Laugh" },
    .{ .value = "\xF0\x9F\x8E\x89", .label = "\xF0\x9F\x8E\x89", .title = "Hooray" },
    .{ .value = "\xF0\x9F\x98\x95", .label = "\xF0\x9F\x98\x95", .title = "Confused" },
    .{ .value = "\xE2\x9D\xA4\xEF\xB8\x8F", .label = "\xE2\x9D\xA4\xEF\xB8\x8F", .title = "Heart" },
    .{ .value = "\xF0\x9F\x9A\x80", .label = "\xF0\x9F\x9A\x80", .title = "Rocket" },
    .{ .value = "\xF0\x9F\x91\x80", .label = "\xF0\x9F\x91\x80", .title = "Eyes" },
};
