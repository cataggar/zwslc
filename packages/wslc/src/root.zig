//! packages/wslc: safe, idiomatic wrapper around `wslc-sys`.
//!
//! Phase 1 status: placeholder that just re-exports `wslc-sys` and proves the
//! module graph (`wslc` -> `wslc-sys` -> real `wslcsdk.lib`) links and runs.
//! `Session`/`Container`/`Process`/`Image` land in Phase 3.

const std = @import("std");
pub const sys = @import("wslc-sys");

/// Returns the installed WSL container SDK version, or an error if the call
/// fails. Doesn't require an active session — mirrors the first step of
/// Microsoft's documented end-to-end example. Ensures COM is initialized on
/// the calling thread first.
pub fn getVersion() !sys.Version {
    try sys.ensureComInitialized();
    var v: sys.Version = .{ .major = 0, .minor = 0, .revision = 0 };
    const hr = sys.WslcGetVersion(&v);
    if (!sys.succeeded(hr)) return error.WslcGetVersionFailed;
    return v;
}

test "wslc.getVersion links through to the real SDK" {
    const v = try getVersion();
    try std.testing.expect(v.major >= 2);
}
