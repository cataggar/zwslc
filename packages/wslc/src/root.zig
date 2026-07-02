//! packages/wslc: safe, idiomatic wrapper around `wslc-sys`.
//!
//! Phase 2 status: `getVersion()` now uses the `wslc-sys` `ok()`/`Error`
//! machinery instead of a bespoke error. `Session`/`Container`/`Process`/
//! `Image` land in Phase 3.

const std = @import("std");
pub const sys = @import("wslc-sys");

/// Returns the installed WSL container SDK version, or an error if the call
/// fails. Doesn't require an active session — mirrors the first step of
/// Microsoft's documented end-to-end example. Ensures COM is initialized on
/// the calling thread first.
pub fn getVersion() sys.Error!sys.WslcVersion {
    try sys.ensureComInitialized();
    var v: sys.WslcVersion = .{ .major = 0, .minor = 0, .revision = 0 };
    try sys.ok(sys.WslcGetVersion(&v));
    return v;
}

test "wslc.getVersion links through to the real SDK" {
    const v = try getVersion();
    try std.testing.expect(v.major >= 2);
}

