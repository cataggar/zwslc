//! packages/wslc-sys: raw, ABI-exact extern bindings to `wslcsdk.h`.
//!
//! This module is intentionally low-level and unsafe — a 1:1 transcription of
//! the C header (verified against the real `wslcsdk.h` shipped in the
//! `Microsoft.WSL.Containers` NuGet package). Consumers that want an
//! idiomatic, memory-safe API should use the `wslc` package instead.
//!
//! Phase 1 status: only `WslcGetVersion` is declared, as a link-smoke test
//! proving the build can fetch the real SDK and link against it. The full
//! 60-function surface (structs, enums, callbacks, error codes, and the
//! `AbiBlob`/`Handle`/`Flags`/`ErrorSet`/`Callback` comptime generators) lands
//! in Phase 2.

const std = @import("std");

pub const HRESULT = i32;

pub const Version = extern struct {
    major: u32,
    minor: u32,
    revision: u32,
};

pub extern "wslcsdk" fn WslcGetVersion(version: *Version) callconv(.winapi) HRESULT;

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// ---- COM initialization -------------------------------------------------
//
// Every Wslc* entry point requires COM to be initialized on the calling
// thread first (confirmed empirically: WslcGetVersion returns
// CO_E_NOTINITIALIZED, 0x800401F0, without it) — this matches Microsoft's
// documented end-to-end C sample, which calls `CoInitializeEx(nullptr,
// COINIT_MULTITHREADED)` as its very first step. `ensureComInitialized` is a
// thread-local, idempotent convenience so higher layers don't have to
// remember to call it (or worry about calling it twice).

const COINIT_MULTITHREADED: u32 = 0x0;

extern "ole32" fn CoInitializeEx(pv_reserved: ?*anyopaque, co_init: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

threadlocal var com_initialized: bool = false;

/// Initializes COM on the calling thread if it hasn't been already. Safe to
/// call repeatedly (idempotent per-thread). `S_OK` and `S_FALSE` (already
/// initialized, possibly with different concurrency semantics) both count as
/// success, matching standard `CoInitializeEx` usage conventions.
pub fn ensureComInitialized() !void {
    if (com_initialized) return;
    const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (hr != 0 and hr != 1) return error.ComInitializeFailed; // not S_OK / S_FALSE
    com_initialized = true;
}

/// Uninitializes COM on the calling thread. Only call this if this thread
/// won't make any more Wslc*/COM calls (e.g. at program exit) — most programs
/// don't need to call this explicitly since the OS cleans up on process exit.
pub fn uninitializeCom() void {
    if (!com_initialized) return;
    CoUninitialize();
    com_initialized = false;
}

test "link smoke test: WslcGetVersion resolves against the real wslcsdk.lib" {
    try ensureComInitialized();
    defer uninitializeCom();
    var v: Version = .{ .major = 0, .minor = 0, .revision = 0 };
    const hr = WslcGetVersion(&v);
    try std.testing.expect(succeeded(hr));
    // Sanity: the SDK version pinned in build.zig is 2.9.3, so major should be 2.
    try std.testing.expect(v.major >= 2);
}
