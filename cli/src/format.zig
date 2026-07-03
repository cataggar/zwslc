//! Shared output-formatting helpers for the `zwslc` CLI, styled after the
//! real `wslc.exe`'s tabular list output (see `image_cmds.zig`'s `list`,
//! e.g. `wslc images` prints `REPOSITORY TAG IMAGE ID CREATED SIZE` with
//! human-readable size/age, not raw bytes/full sha256/unix timestamps).

const std = @import("std");

/// Formats a byte count using decimal (1000-based) SI units, matching
/// Docker/wslc's convention (e.g. 20_560_000 -> "20.56 MB"). Writes into
/// `buf` (should be at least 32 bytes) and returns the used slice.
pub fn humanSize(buf: []u8, bytes: i64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(@max(0, bytes));
    var unit_index: usize = 0;
    while (value >= 1000.0 and unit_index < units.len - 1) {
        value /= 1000.0;
        unit_index += 1;
    }
    if (unit_index == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ @as(i64, @intFromFloat(value)), units[0] }) catch buf;
    }
    var tmp: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&tmp, "{d:.2}", .{value}) catch return buf;
    const trimmed = trimTrailingZeros(formatted);
    return std.fmt.bufPrint(buf, "{s} {s}", .{ trimmed, units[unit_index] }) catch buf;
}

fn trimTrailingZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// Formats a "time ago" string from elapsed seconds, matching Docker's
/// `units.HumanDuration(...) + " ago"` convention wslc uses (e.g.
/// "1 month ago", "3 hours ago", "Less than a second ago"). Writes into
/// `buf` (should be at least 32 bytes) and returns the used slice.
pub fn humanDurationAgo(buf: []u8, elapsed_seconds: i64) []const u8 {
    const secs = @max(0, elapsed_seconds);
    if (secs < 1) return std.fmt.bufPrint(buf, "Less than a second ago", .{}) catch buf;
    if (secs == 1) return std.fmt.bufPrint(buf, "1 second ago", .{}) catch buf;
    if (secs < 60) return std.fmt.bufPrint(buf, "{d} seconds ago", .{secs}) catch buf;

    const minutes = @divTrunc(secs, 60);
    if (minutes == 1) return std.fmt.bufPrint(buf, "About a minute ago", .{}) catch buf;
    if (minutes < 46) return std.fmt.bufPrint(buf, "{d} minutes ago", .{minutes}) catch buf;

    // Round to the nearest hour (matches Docker's math.Round(d.Hours())).
    const hours = @divTrunc(secs + 1800, 3600);
    if (hours == 1) return std.fmt.bufPrint(buf, "About an hour ago", .{}) catch buf;
    if (hours < 48) return pluralAgo(buf, hours, "hour");
    if (hours < 24 * 14) return pluralAgo(buf, @divTrunc(hours, 24), "day");
    // Docker's original thresholds double the week/month/year bucket sizes
    // (e.g. weeks extend to 60 days) before transitioning, which makes "1
    // month ago" mathematically impossible to ever print (by the time the
    // month bucket activates at >=60 days, hours/24/30 is already >= 2) -
    // confirmed *not* what the real wslc.exe does (it does print "1 month
    // ago"). Transitioning at exactly 30/365 days instead fixes that gap.
    if (hours < 24 * 30) return pluralAgo(buf, @divTrunc(hours, 24 * 7), "week");
    if (hours < 24 * 365) return pluralAgo(buf, @divTrunc(hours, 24 * 30), "month");
    return pluralAgo(buf, @divTrunc(hours, 24 * 365), "year");
}

/// Formats "{count} {singular} ago" or "1 {singular} ago" (no trailing "s")
/// for a count of exactly 1 - unlike Docker's original HumanDuration, which
/// has a well-known quirk of never singularizing day/week/month/year (it
/// says "1 months ago" - confirmed *not* what the real wslc.exe prints,
/// which correctly says "1 month ago").
fn pluralAgo(buf: []u8, count: i64, singular: []const u8) []const u8 {
    if (count == 1) {
        return std.fmt.bufPrint(buf, "1 {s} ago", .{singular}) catch buf;
    }
    return std.fmt.bufPrint(buf, "{d} {s}s ago", .{ count, singular }) catch buf;
}

/// Splits an image reference into (repository, tag) on the last ':',
/// matching Docker/wslc's REPOSITORY/TAG columns (e.g. "alpine:latest" ->
/// ("alpine", "latest")). If there's no ':', the tag is "<none>".
pub fn splitRepoTag(image: []const u8) struct { repo: []const u8, tag: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, image, ':')) |i| {
        return .{ .repo = image[0..i], .tag = image[i + 1 ..] };
    }
    return .{ .repo = image, .tag = "<none>" };
}

/// Prints a left-aligned table with a header row, sizing each column to the
/// widest cell in that column (matching wslc/Docker's tabwriter-style
/// output, which adapts column widths to content) with a 3-space gap
/// between columns and no trailing padding on the last column.
pub fn printTable(comptime num_cols: usize, headers: [num_cols][]const u8, rows: []const [num_cols][]const u8) void {
    var widths: [num_cols]usize = undefined;
    for (headers, 0..) |h, i| widths[i] = h.len;
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (cell.len > widths[i]) widths[i] = cell.len;
        }
    }
    printRow(num_cols, headers, widths);
    for (rows) |row| printRow(num_cols, row, widths);
}

fn printRow(comptime num_cols: usize, cells: [num_cols][]const u8, widths: [num_cols]usize) void {
    for (cells, 0..) |cell, i| {
        if (i == num_cols - 1) {
            std.debug.print("{s}\n", .{cell});
        } else {
            std.debug.print("{s}", .{cell});
            var pad = widths[i] - cell.len + 3;
            while (pad > 0) : (pad -= 1) std.debug.print(" ", .{});
        }
    }
}

test "humanSize matches Docker-style decimal SI units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", humanSize(&buf, 512));
    try std.testing.expectEqualStrings("8 MB", humanSize(&buf, 8_000_000));
    try std.testing.expectEqualStrings("20.56 MB", humanSize(&buf, 20_560_000));
    try std.testing.expectEqualStrings("1.5 GB", humanSize(&buf, 1_500_000_000));
}

test "humanDurationAgo matches Docker's HumanDuration buckets" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Less than a second ago", humanDurationAgo(&buf, 0));
    try std.testing.expectEqualStrings("1 second ago", humanDurationAgo(&buf, 1));
    try std.testing.expectEqualStrings("30 seconds ago", humanDurationAgo(&buf, 30));
    try std.testing.expectEqualStrings("About a minute ago", humanDurationAgo(&buf, 60));
    try std.testing.expectEqualStrings("5 minutes ago", humanDurationAgo(&buf, 5 * 60));
    try std.testing.expectEqualStrings("About an hour ago", humanDurationAgo(&buf, 3600));
    try std.testing.expectEqualStrings("5 hours ago", humanDurationAgo(&buf, 5 * 3600));
    try std.testing.expectEqualStrings("2 days ago", humanDurationAgo(&buf, 2 * 24 * 3600));
    try std.testing.expectEqualStrings("2 weeks ago", humanDurationAgo(&buf, 15 * 24 * 3600));
    try std.testing.expectEqualStrings("1 month ago", humanDurationAgo(&buf, 30 * 24 * 3600));
}

test "splitRepoTag splits on the last colon" {
    const a = splitRepoTag("alpine:latest");
    try std.testing.expectEqualStrings("alpine", a.repo);
    try std.testing.expectEqualStrings("latest", a.tag);

    const b = splitRepoTag("mcr.microsoft.com/azurelinux-beta/distroless/debug:4.0");
    try std.testing.expectEqualStrings("mcr.microsoft.com/azurelinux-beta/distroless/debug", b.repo);
    try std.testing.expectEqualStrings("4.0", b.tag);

    const c = splitRepoTag("noTagHere");
    try std.testing.expectEqualStrings("noTagHere", c.repo);
    try std.testing.expectEqualStrings("<none>", c.tag);
}
