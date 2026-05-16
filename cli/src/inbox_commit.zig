const std = @import("std");

pub const log_format = "--format=%H%x00%T%x00%P%x00%s%x00%b%x1e";

pub const Record = struct {
    commit: []const u8,
    tree: []const u8,
    parents: []const u8,
    subject: []const u8,
    body: []const u8,
};

pub fn parseRecord(record_raw: []const u8) ?Record {
    const record = std.mem.trim(u8, record_raw, "\r\n");
    if (record.len == 0) return null;

    const first = std.mem.indexOfScalar(u8, record, 0) orelse return null;
    const second_rel = std.mem.indexOfScalar(u8, record[first + 1 ..], 0) orelse return null;
    const second = first + 1 + second_rel;
    const third_rel = std.mem.indexOfScalar(u8, record[second + 1 ..], 0) orelse return null;
    const third = second + 1 + third_rel;
    const fourth_rel = std.mem.indexOfScalar(u8, record[third + 1 ..], 0) orelse return null;
    const fourth = third + 1 + fourth_rel;

    return .{
        .commit = std.mem.trim(u8, record[0..first], " \t\r\n"),
        .tree = std.mem.trim(u8, record[first + 1 .. second], " \t\r\n"),
        .parents = std.mem.trim(u8, record[second + 1 .. third], " \t\r\n"),
        .subject = std.mem.trim(u8, record[third + 1 .. fourth], " \t\r\n"),
        .body = std.mem.trim(u8, record[fourth + 1 ..], " \t\r\n"),
    };
}

pub fn isBlankRawRecord(record_raw: []const u8) bool {
    return std.mem.trim(u8, record_raw, " \t\r\n").len == 0;
}

test "inbox commit records parse git log fields" {
    const record = parseRecord(" commit \x00 tree \x00 parent1 parent2 \x00 subject \x00 body\n") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("commit", record.commit);
    try std.testing.expectEqualStrings("tree", record.tree);
    try std.testing.expectEqualStrings("parent1 parent2", record.parents);
    try std.testing.expectEqualStrings("subject", record.subject);
    try std.testing.expectEqualStrings("body", record.body);

    try std.testing.expect(parseRecord("commit\x00tree\x00parents") == null);
}
