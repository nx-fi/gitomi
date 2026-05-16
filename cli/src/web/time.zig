const std = @import("std");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;

pub fn appendRelativeTime(buf: *std.ArrayList(u8), allocator: Allocator, timestamp: []const u8) !void {
    const label = try relativeTimeLabelOwned(allocator, timestamp);
    defer allocator.free(label);
    try html.appendTemplate(buf, allocator,
        \\<time datetime="{timestamp}" data-relative-time>{label}</time>
    , .{
        .timestamp = timestamp,
        .label = label,
    });
}

fn relativeTimeLabelOwned(allocator: Allocator, timestamp: []const u8) ![]u8 {
    const parsed = parseRfc3339Timestamp(timestamp) orelse return allocator.dupe(u8, timestamp);
    return relativeDurationOwned(allocator, std.time.timestamp() - parsed);
}

fn relativeDurationOwned(allocator: Allocator, delta_seconds: i64) ![]u8 {
    const future = delta_seconds < -30;
    const seconds = if (delta_seconds < 0) -delta_seconds else delta_seconds;
    if (seconds < 60) return allocator.dupe(u8, if (future) "in less than a minute" else "just now");

    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;
    const week = 7 * day;
    const month = 30 * day;
    const year = 365 * day;

    if (seconds >= year) return relativeUnitOwned(allocator, future, @divFloor(seconds, year), "year");
    if (seconds >= month) return relativeUnitOwned(allocator, future, @divFloor(seconds, month), "month");
    if (seconds >= week) return relativeUnitOwned(allocator, future, @divFloor(seconds, week), "week");
    if (seconds >= day) return relativeUnitOwned(allocator, future, @divFloor(seconds, day), "day");
    if (seconds >= hour) return relativeUnitOwned(allocator, future, @divFloor(seconds, hour), "hour");
    return relativeUnitOwned(allocator, future, @divFloor(seconds, minute), "minute");
}

fn relativeUnitOwned(allocator: Allocator, future: bool, value: i64, unit: []const u8) ![]u8 {
    if (future) {
        return std.fmt.allocPrint(allocator, "in {d} {s}{s}", .{ value, unit, if (value == 1) "" else "s" });
    }
    return std.fmt.allocPrint(allocator, "{d} {s}{s} ago", .{ value, unit, if (value == 1) "" else "s" });
}

fn parseRfc3339Timestamp(value: []const u8) ?i64 {
    if (value.len < "0000-00-00T00:00:00Z".len) return null;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return null;

    const year = parseFixedInt(value[0..4]) orelse return null;
    const month = parseFixedInt(value[5..7]) orelse return null;
    const day = parseFixedInt(value[8..10]) orelse return null;
    const hour = parseFixedInt(value[11..13]) orelse return null;
    const minute = parseFixedInt(value[14..16]) orelse return null;
    const second = parseFixedInt(value[17..19]) orelse return null;

    if (year < 1970 or year > 9999) return null;
    if (month < 1 or month > 12) return null;
    const epoch_month: std.time.epoch.Month = @enumFromInt(@as(u4, @intCast(month)));
    const days_in_month: i64 = std.time.epoch.getDaysInMonth(@as(std.time.epoch.Year, @intCast(year)), epoch_month);
    if (day < 1 or day > days_in_month) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var cursor: usize = 19;
    if (cursor < value.len and value[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < value.len and std.ascii.isDigit(value[cursor])) cursor += 1;
        if (cursor == fraction_start) return null;
    }

    const offset_seconds = parseRfc3339Offset(value[cursor..]) orelse return null;
    const local_seconds = daysFromCivil(year, month, day) * @as(i64, std.time.epoch.secs_per_day) + hour * 3600 + minute * 60 + second;
    return local_seconds - offset_seconds;
}

fn parseFixedInt(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn parseRfc3339Offset(value: []const u8) ?i64 {
    if (std.mem.eql(u8, value, "Z")) return 0;
    if (value.len != 6 or value[3] != ':') return null;
    const sign: i64 = switch (value[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const hours = parseFixedInt(value[1..3]) orelse return null;
    const minutes = parseFixedInt(value[4..6]) orelse return null;
    if (hours > 23 or minutes > 59) return null;
    return sign * (hours * 3600 + minutes * 60);
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var adjusted_year = year;
    if (month <= 2) adjusted_year -= 1;
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_prime = month + if (month > 2) @as(i64, -3) else @as(i64, 9);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}
