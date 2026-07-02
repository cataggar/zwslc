//! Small string-marshaling helpers shared by session.zig/container.zig/process.zig.
//!
//! The WSLC C API takes narrow (`PCSTR`) and wide (`PCWSTR`) null-terminated
//! strings; Zig slices aren't null-terminated by default, so every settings
//! builder needs to allocate a sentinel-terminated copy before handing a
//! pointer to the SDK. These helpers centralize that so the three wrapper
//! types don't each reinvent it.

const std = @import("std");
const sys = @import("wslc-sys");

/// Allocates a null-terminated narrow (ANSI/UTF-8) copy of `s`. Caller frees
/// with `allocator.free(result)`.
pub fn narrowZ(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![:0]u8 {
    return allocator.dupeZ(u8, s);
}

/// Allocates a null-terminated UTF-16LE copy of `s`. Caller frees with
/// `allocator.free(result)`.
pub fn wideZ(allocator: std.mem.Allocator, s: []const u8) error{ OutOfMemory, InvalidUtf8 }![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, s);
}

/// Allocates an array of null-terminated narrow copies of `items`, plus a
/// contiguous array of `PCSTR` pointers into them (suitable for
/// `WslcSetProcessSettingsCmdLine`/`...EnvVariables`'s `argv`/`key_value`
/// parameters). Caller frees with `freeCStringArray`.
pub const CStringArray = struct {
    owned: []const [:0]u8,
    ptrs: []sys.PCSTR,

    pub fn deinit(self: *CStringArray, allocator: std.mem.Allocator) void {
        for (self.owned) |s| allocator.free(s);
        allocator.free(self.owned);
        allocator.free(self.ptrs);
        self.* = undefined;
    }
};

pub fn narrowZArray(allocator: std.mem.Allocator, items: []const []const u8) error{OutOfMemory}!CStringArray {
    const owned = try allocator.alloc([:0]u8, items.len);
    errdefer allocator.free(owned);
    var filled: usize = 0;
    errdefer for (owned[0..filled]) |s| allocator.free(s);
    for (items, 0..) |item, i| {
        owned[i] = try allocator.dupeZ(u8, item);
        filled += 1;
    }

    const ptrs = try allocator.alloc(sys.PCSTR, items.len);
    for (owned, 0..) |s, i| ptrs[i] = s.ptr;

    return .{ .owned = owned, .ptrs = ptrs };
}

/// Captures a `CoTaskMemAlloc`'d, possibly-null error message into an owned
/// UTF-8 Zig string (freeing the original), or returns `null` if there was no
/// message (success, or the SDK chose not to populate one) or the UTF-16 ->
/// UTF-8 conversion failed. Caller frees the result with `allocator.free`.
pub fn captureErrorMessage(allocator: std.mem.Allocator, msg: sys.PWSTR) ?[]u8 {
    const p = msg orelse return null;
    defer sys.freeTaskMem(p);
    return std.unicode.utf16LeToUtf8Alloc(allocator, p[0..std.mem.len(p)]) catch null;
}
