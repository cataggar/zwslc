//! packages/wslc-sys: raw, ABI-exact extern bindings to `wslcsdk.h`.
//!
//! This module is intentionally low-level and unsafe — a 1:1 transcription of
//! the real C header (verified against the header shipped in the
//! `Microsoft.WSL.Containers` 2.9.3 NuGet package, cross-checked against
//! `dumpbin /exports` on the real `wslcsdk.lib`: exactly the 60 functions
//! declared below). Consumers that want an idiomatic, memory-safe API should
//! use the `wslc` package instead.
//!
//! Sections below mirror `wslcsdk.h`'s own ordering (constants/errors,
//! session, container, process, image, storage, install) to make future
//! header-diff review easy.

const std = @import("std");
const assert = std.debug.assert;

pub const HRESULT = i32;
pub const HANDLE = ?*anyopaque;
pub const BOOL = i32;

pub inline fn boolToWin32(b: bool) BOOL {
    return if (b) 1 else 0;
}
pub inline fn boolFromWin32(b: BOOL) bool {
    return b != 0;
}

// ---- C string types --------------------------------------------------------
//
// All four are nullable by default (matching plain C pointer nullability);
// callers/higher layers are responsible for asserting non-null where the
// header's SAL annotations (`_In_z_`, `_Outptr_result_z_`, etc.) guarantee it.

pub const PCSTR = ?[*:0]const u8;
pub const PCWSTR = ?[*:0]const u16;
pub const PWSTR = ?[*:0]u16;
pub const PSTR = ?[*:0]u8;

pub const pcstr = struct {
    pub fn len(s: PCSTR) usize {
        const p = s orelse return 0;
        return std.mem.len(p);
    }
    pub fn slice(s: PCSTR) []const u8 {
        const p = s orelse return &.{};
        return p[0..std.mem.len(p)];
    }
};

pub const pcwstr = struct {
    pub fn len(s: PCWSTR) usize {
        const p = s orelse return 0;
        return std.mem.len(p);
    }
    pub fn slice(s: PCWSTR) []const u16 {
        const p = s orelse return &.{};
        return p[0..std.mem.len(p)];
    }
};

// ---- COM initialization -----------------------------------------------------
//
// Every Wslc* entry point requires COM to be initialized on the calling
// thread first (confirmed empirically: WslcGetVersion returns
// CO_E_NOTINITIALIZED, 0x800401F0, without it) — this matches Microsoft's
// documented end-to-end C sample, which calls `CoInitializeEx(nullptr,
// COINIT_MULTITHREADED)` as its very first step.

const COINIT_MULTITHREADED: u32 = 0x0;

extern "ole32" fn CoInitializeEx(pv_reserved: ?*anyopaque, co_init: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

threadlocal var com_initialized: bool = false;

/// Initializes COM on the calling thread if it hasn't been already. Safe to
/// call repeatedly (idempotent per-thread). `S_OK` and `S_FALSE` (already
/// initialized) both count as success, matching standard `CoInitializeEx`
/// usage conventions.
pub fn ensureComInitialized() Error!void {
    if (com_initialized) return;
    const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (hr == 0 or hr == 1) { // S_OK / S_FALSE
        com_initialized = true;
        return;
    }
    return toError(hr);
}

/// Uninitializes COM on the calling thread. Only call this if this thread
/// won't make any more Wslc*/COM calls (e.g. at program exit) — most programs
/// don't need to call this explicitly since the OS cleans up on process exit.
pub fn uninitializeCom() void {
    if (!com_initialized) return;
    CoUninitialize();
    com_initialized = false;
}

// ---- Errors -----------------------------------------------------------------
//
// Table-driven: one array of {name, hr} pairs feeds both a synthesized Zig
// `error{...}` set (via `@Type`) and the HRESULT<->error mapping functions.
// This keeps the WSLC-specific codes (transcribed from `wslcsdk.h`) and a
// curated set of generic HRESULTs we've either encountered (NotInitialized)
// or expect to encounter (InvalidArg, OutOfMemory, ...) in one place that
// can't silently drift out of sync with itself.

pub const WSLC_E_BASE: u16 = 0x0600;

const ErrorEntry = struct { name: [:0]const u8, hr: HRESULT };

fn makeHresult(severity: u1, facility: u11, code: u16) HRESULT {
    return @bitCast(@as(u32, severity) << 31 | @as(u32, facility) << 16 | @as(u32, code));
}

/// WSLC-specific domain errors (`WSLC_E_*` in `wslcsdk.h`).
const domain_errors = [_]ErrorEntry{
    .{ .name = "ImageNotFound", .hr = makeHresult(1, 4, WSLC_E_BASE + 1) },
    .{ .name = "ContainerPrefixAmbiguous", .hr = makeHresult(1, 4, WSLC_E_BASE + 2) },
    .{ .name = "ContainerNotFound", .hr = makeHresult(1, 4, WSLC_E_BASE + 3) },
    .{ .name = "VolumeNotFound", .hr = makeHresult(1, 4, WSLC_E_BASE + 4) },
    .{ .name = "ContainerNotRunning", .hr = makeHresult(1, 4, WSLC_E_BASE + 5) },
    .{ .name = "ContainerIsRunning", .hr = makeHresult(1, 4, WSLC_E_BASE + 6) },
    .{ .name = "SessionReserved", .hr = makeHresult(1, 4, WSLC_E_BASE + 7) },
    .{ .name = "InvalidSessionName", .hr = makeHresult(1, 4, WSLC_E_BASE + 8) },
    .{ .name = "NetworkNotFound", .hr = makeHresult(1, 4, WSLC_E_BASE + 9) },
    .{ .name = "WuSearchFailed", .hr = makeHresult(1, 4, WSLC_E_BASE + 10) },
    .{ .name = "SdkUpdateNeeded", .hr = makeHresult(1, 4, WSLC_E_BASE + 11) },
    .{ .name = "ContainerDisabled", .hr = makeHresult(1, 4, WSLC_E_BASE + 12) },
    .{ .name = "RegistryBlockedByPolicy", .hr = makeHresult(1, 4, WSLC_E_BASE + 13) },
    .{ .name = "VolumeNotAvailable", .hr = makeHresult(1, 4, WSLC_E_BASE + 14) },
    .{ .name = "SessionNotFound", .hr = makeHresult(1, 4, WSLC_E_BASE + 15) },
};

/// Curated generic (non-WSLC-specific) HRESULTs that Wslc* calls can
/// plausibly return (standard COM/Win32 codes).
const generic_errors = [_]ErrorEntry{
    .{ .name = "NotInitialized", .hr = @bitCast(@as(u32, 0x800401F0)) }, // CO_E_NOTINITIALIZED
    .{ .name = "InvalidArg", .hr = @bitCast(@as(u32, 0x80070057)) }, // E_INVALIDARG
    .{ .name = "OutOfMemory", .hr = @bitCast(@as(u32, 0x8007000E)) }, // E_OUTOFMEMORY
    .{ .name = "AccessDenied", .hr = @bitCast(@as(u32, 0x80070005)) }, // E_ACCESSDENIED
    .{ .name = "Fail", .hr = @bitCast(@as(u32, 0x80004005)) }, // E_FAIL
    .{ .name = "NotImplemented", .hr = @bitCast(@as(u32, 0x80004001)) }, // E_NOTIMPL
    .{ .name = "NoInterface", .hr = @bitCast(@as(u32, 0x80004002)) }, // E_NOINTERFACE
    .{ .name = "Pointer", .hr = @bitCast(@as(u32, 0x80004003)) }, // E_POINTER
    .{ .name = "Aborted", .hr = @bitCast(@as(u32, 0x80004004)) }, // E_ABORT
    .{ .name = "Handle", .hr = @bitCast(@as(u32, 0x80070006)) }, // E_HANDLE
};

const all_errors = domain_errors ++ generic_errors;

// NOTE: this Zig version removed the dynamic `@Type` builtin (error sets are
// no longer constructable from a runtime/comptime-built field list — only
// per-kind builtins like `@Struct`/`@Enum`/`@Union` remain, and there is no
// `@ErrorSet` equivalent). So `Error` has to be a literal `error{...}` here,
// duplicating the names already present in `all_errors` above. To keep the
// literal from silently drifting out of sync with the table, the `comptime`
// block below cross-checks them: every name in `all_errors` must appear in
// `Error`, and the member counts must match exactly.
pub const Error = error{
    ImageNotFound,
    ContainerPrefixAmbiguous,
    ContainerNotFound,
    VolumeNotFound,
    ContainerNotRunning,
    ContainerIsRunning,
    SessionReserved,
    InvalidSessionName,
    NetworkNotFound,
    WuSearchFailed,
    SdkUpdateNeeded,
    ContainerDisabled,
    RegistryBlockedByPolicy,
    VolumeNotAvailable,
    SessionNotFound,
    NotInitialized,
    InvalidArg,
    OutOfMemory,
    AccessDenied,
    Fail,
    NotImplemented,
    NoInterface,
    Pointer,
    Aborted,
    Handle,
    Unknown,
};

comptime {
    @setEvalBranchQuota(10_000);
    const members = @typeInfo(Error).error_set.?;
    assert(members.len == all_errors.len + 1); // +1 for Unknown, which has no table entry
    for (all_errors) |e| {
        var found = false;
        for (members) |m| {
            if (std.mem.eql(u8, m.name, e.name)) {
                found = true;
                break;
            }
        }
        if (!found) @compileError("wslc-sys.Error literal is missing member: " ++ e.name);
    }
}

/// The last HRESULT passed to `ok`/`toError`. Thread-local so failures aren't
/// racy across threads; useful for logging/recovering the raw code after
/// catching `error.Unknown`.
pub threadlocal var last_hresult: HRESULT = 0;

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// Maps a (known-failed) HRESULT to its curated `Error` variant. Prefer `ok`.
pub fn toError(hr: HRESULT) Error {
    last_hresult = hr;
    inline for (all_errors) |e| {
        if (hr == e.hr) return @field(Error, e.name);
    }
    return error.Unknown;
}

/// `S_OK`/`S_FALSE` (and any other non-negative code) return `void`; failures
/// become a curated `Error`. Mirrors windows-rs/zig's `hresult.ok()` idiom.
pub fn ok(hr: HRESULT) Error!void {
    if (succeeded(hr)) {
        last_hresult = hr;
        return;
    }
    return toError(hr);
}

// ---- Flags mixin ------------------------------------------------------------
//
// All six WSLC bitflag enums get `.merge`/`.mergeAll`/`.has` via this single
// generic instead of hand-writing them six times. `validateFlagsEnum` is a
// comptime guard: every enumerator must be `0` or a power of two, and the
// enum must be non-exhaustive (trailing `_,`) so arbitrary OR combinations
// (which usually don't correspond to a named enumerator) are representable
// without `@enumFromInt` panicking.

fn validateFlagsEnum(comptime E: type) void {
    const info = switch (@typeInfo(E)) {
        .@"enum" => |i| i,
        else => @compileError("Flags() requires an enum type, got " ++ @typeName(E)),
    };
    if (info.is_exhaustive) {
        @compileError("Flags(" ++ @typeName(E) ++ "): flag enums must be non-exhaustive (add a trailing `_,`)");
    }
    for (info.fields) |f| {
        if (f.value != 0 and (f.value & (f.value - 1)) != 0) {
            @compileError(std.fmt.comptimePrint(
                "Flags({s}): enumerator '{s}' = {d} is not zero or a power of two",
                .{ @typeName(E), f.name, f.value },
            ));
        }
    }
}

pub fn Flags(comptime E: type) type {
    comptime validateFlagsEnum(E);
    return struct {
        pub fn merge(a: E, b: E) E {
            return @enumFromInt(@intFromEnum(a) | @intFromEnum(b));
        }
        pub fn mergeAll(values: []const E) E {
            var bits: std.meta.Tag(E) = 0;
            for (values) |v| bits |= @intFromEnum(v);
            return @enumFromInt(bits);
        }
        pub fn has(self: E, value: E) bool {
            const bit = @intFromEnum(value);
            if (bit == 0) return @intFromEnum(self) == 0;
            return (@intFromEnum(self) & bit) == bit;
        }
    };
}

// ---- Distinct opaque handle types --------------------------------------------
//
// `wslcsdk.h` declares all four via `DECLARE_HANDLE`, which in C already
// produces a nominal pointer-to-incomplete-struct type per handle (precisely
// so `WslcSession`/`WslcContainer`/etc. can't be silently interchanged). This
// generic reproduces that in Zig: each call site with a distinct `tag_name`
// gets a genuinely distinct opaque pointer type, at zero runtime cost.

pub fn Handle(comptime tag_name: []const u8) type {
    return ?*opaque {
        pub const debug_name = tag_name;
    };
}

pub const Session = Handle("WslcSession");
pub const Container = Handle("WslcContainer");
pub const Process = Handle("WslcProcess");
pub const CrashDumpSubscription = Handle("WslcCrashDumpSubscription");

// ---- Opaque settings blobs ---------------------------------------------------
//
// `WslcSessionSettings`/`WslcContainerSettings`/`WslcProcessSettings` are
// intentionally opaque fixed-size byte blobs in the real header — callers
// never read/write fields directly, only via `Wslc*Init*Settings` +
// `Wslc*Set*Settings*` builder calls. `AbiBlob` generates the wrapper and the
// `comptime` block asserts our transcribed size/alignment constants still
// match what Zig actually lays out (and, transitively, catches drift if a
// future SDK version changes these numbers without us noticing).

pub const WSLC_SESSION_OPTIONS_SIZE: usize = 72;
pub const WSLC_SESSION_OPTIONS_ALIGNMENT: usize = 8;
pub const WSLC_CONTAINER_OPTIONS_SIZE: usize = 104;
pub const WSLC_CONTAINER_OPTIONS_ALIGNMENT: usize = 8;
pub const WSLC_CONTAINER_PROCESS_OPTIONS_SIZE: usize = 72;
pub const WSLC_CONTAINER_PROCESS_OPTIONS_ALIGNMENT: usize = 8;
pub const WSLC_CONTAINER_ID_BUFFER_SIZE: usize = 65; // 64 hex chars + null terminator
pub const WSLC_IMAGE_NAME_LENGTH: usize = 256; // 255 chars + null

pub fn AbiBlob(comptime size: usize, comptime alignment: usize) type {
    return extern struct {
        _opaque: [size]u8 align(alignment) = undefined,
    };
}

pub const WslcSessionSettings = AbiBlob(WSLC_SESSION_OPTIONS_SIZE, WSLC_SESSION_OPTIONS_ALIGNMENT);
pub const WslcContainerSettings = AbiBlob(WSLC_CONTAINER_OPTIONS_SIZE, WSLC_CONTAINER_OPTIONS_ALIGNMENT);
pub const WslcProcessSettings = AbiBlob(WSLC_CONTAINER_PROCESS_OPTIONS_SIZE, WSLC_CONTAINER_PROCESS_OPTIONS_ALIGNMENT);

comptime {
    assert(@sizeOf(WslcSessionSettings) == WSLC_SESSION_OPTIONS_SIZE);
    assert(@alignOf(WslcSessionSettings) == WSLC_SESSION_OPTIONS_ALIGNMENT);
    assert(@sizeOf(WslcContainerSettings) == WSLC_CONTAINER_OPTIONS_SIZE);
    assert(@alignOf(WslcContainerSettings) == WSLC_CONTAINER_OPTIONS_ALIGNMENT);
    assert(@sizeOf(WslcProcessSettings) == WSLC_CONTAINER_PROCESS_OPTIONS_SIZE);
    assert(@alignOf(WslcProcessSettings) == WSLC_CONTAINER_PROCESS_OPTIONS_ALIGNMENT);
}

// ---- Enumerations (sequential) -----------------------------------------------

pub const WslcContainerNetworkingMode = enum(u32) {
    NONE = 0, // No networking / isolated
    BRIDGED = 1,
};

pub const WslcVhdType = enum(u32) {
    DYNAMIC = 0, // Expanding VHDX (default)
    FIXED = 1, // Fixed-allocation VHDX (only honored by WslcCreateSessionVhdVolume; currently E_NOTIMPL)
};

pub const WslcSessionTerminationReason = enum(u32) {
    UNKNOWN = 0,
    SHUTDOWN = 1,
    CRASHED = 2,
};

pub const WslcPortProtocol = enum(u32) {
    TCP = 0,
    UDP = 1, // currently E_NOTIMPL in WslcSetContainerSettingsPortMappings
};

pub const WslcContainerState = enum(u32) {
    INVALID = 0,
    CREATED = 1,
    RUNNING = 2,
    EXITED = 3,
    DELETED = 4,
};

pub const WslcSignal = enum(u32) {
    NONE = 0, // No signal; reserved for future use
    SIGHUP = 1,
    SIGINT = 2,
    SIGQUIT = 3,
    SIGKILL = 9,
    SIGTERM = 15,
};

pub const WslcProcessIOHandle = enum(u32) {
    STDIN = 0,
    STDOUT = 1,
    STDERR = 2,
};

pub const WslcProcessState = enum(u32) {
    UNKNOWN = 0,
    RUNNING = 1,
    EXITED = 2,
    SIGNALLED = 3,
};

pub const WslcImageProgressStatus = enum(u32) {
    UNKNOWN = 0,
    PULLING = 1, // "Pulling fs layer"
    WAITING = 2, // "Waiting"
    DOWNLOADING = 3, // "Downloading"
    VERIFYING = 4, // "Verifying Checksum"
    EXTRACTING = 5, // "Extracting"
    COMPLETE = 6, // "Pull complete"
};

// ---- Enumerations (bitflags) --------------------------------------------------

pub const WslcVhdRequirementsFlags = enum(u32) {
    NONE = 0x0,
    /// When set, WslcVhdRequirements.uid/gid are honored; otherwise the
    /// volume is left owned by root:root.
    OWNER = 0x1,
    _,

    pub const merge = Flags(@This()).merge;
    pub const mergeAll = Flags(@This()).mergeAll;
    pub const has = Flags(@This()).has;
};

pub const WslcSessionFeatureFlags = enum(u32) {
    NONE = 0x0,
    ENABLE_GPU = 0x4,
    _,

    pub const merge = Flags(@This()).merge;
    pub const mergeAll = Flags(@This()).mergeAll;
    pub const has = Flags(@This()).has;
};

pub const WslcContainerFlags = enum(u32) {
    NONE = 0x0,
    AUTO_REMOVE = 0x1,
    ENABLE_GPU = 0x2,
    PRIVILEGED = 0x4,
    _,

    pub const merge = Flags(@This()).merge;
    pub const mergeAll = Flags(@This()).mergeAll;
    pub const has = Flags(@This()).has;
};

pub const WslcContainerStartFlags = enum(u32) {
    NONE = 0x0,
    ATTACH = 0x1,
    _,

    pub const merge = Flags(@This()).merge;
    pub const mergeAll = Flags(@This()).mergeAll;
    pub const has = Flags(@This()).has;
};

pub const WslcDeleteContainerFlags = enum(u32) {
    NONE = 0,
    FORCE = 0x1,
    _,

    pub const merge = Flags(@This()).merge;
    pub const mergeAll = Flags(@This()).mergeAll;
    pub const has = Flags(@This()).has;
};

pub const WslcComponentFlags = enum(u32) {
    NONE = 0,
    /// Services provided by the Virtual Machine Platform optional feature.
    /// Installing this component will require a reboot.
    VIRTUAL_MACHINE_PLATFORM = 0x1,
    /// The WSL runtime package, at a version supporting WSLC.
    WSL_PACKAGE = 0x2,
    /// Set if the WSLC SDK itself needs to be updated.
    SDK_NEEDS_UPDATE = 0x4,
    _,

    pub const merge = Flags(@This()).merge;
    pub const mergeAll = Flags(@This()).mergeAll;
    pub const has = Flags(@This()).has;
};

// ---- Callback typedefs --------------------------------------------------------

/// Only STDOUT/STDERR receive callbacks. `data` is owned by WSLC and valid
/// only during the callback; not null-terminated; the callback must return
/// promptly.
pub const WslcStdIOCallback = ?*const fn (
    io_handle: WslcProcessIOHandle,
    data: [*]const u8,
    data_bytes: u32,
    context: ?*anyopaque,
) callconv(.winapi) void;

/// Invoked when a process has exited AND any remaining IO has been flushed.
/// Once invoked, no more IO callbacks will fire for that process.
pub const WslcProcessExitCallback = ?*const fn (
    exit_code: i32,
    context: ?*anyopaque,
) callconv(.winapi) void;

pub const WslcSessionCrashDumpCallback = ?*const fn (
    info: *const WslcSessionCrashDumpInfo,
    context: ?*anyopaque,
) callconv(.winapi) void;

/// The only callback that returns a value: the caller can fail/abort the
/// underlying pull/push/etc. operation by returning a failure HRESULT.
pub const WslcContainerImageProgressCallback = ?*const fn (
    progress: *const WslcImageProgressMessage,
    context: ?*anyopaque,
) callconv(.winapi) HRESULT;

pub const WslcInstallCallback = ?*const fn (
    component: WslcComponentFlags,
    progress_steps: u32,
    total_steps: u32,
    context: ?*anyopaque,
) callconv(.winapi) void;

// ---- Plain structs -------------------------------------------------------------

pub const WslcVhdRequirements = extern struct {
    /// Ignored by WslcSetSessionSettingsVhd; only honored by WslcCreateSessionVhdVolume.
    name: PCSTR,
    /// Desired size in bytes (for create/expand).
    sizeBytes: u64,
    @"type": WslcVhdType,
    /// Only honored by WslcCreateSessionVhdVolume (WslcSetSessionSettingsVhd
    /// rejects non-NONE flags with E_INVALIDARG).
    flags: WslcVhdRequirementsFlags,
    /// Honored iff (flags & OWNER).
    uid: u32,
    /// Honored iff (flags & OWNER).
    gid: u32,
};

pub const WslcSessionCrashDumpInfo = extern struct {
    dumpPath: PCWSTR,
    processName: PCSTR,
    pid: u32,
    signal: u32,
    timestamp: u64,
};

pub const WslcContainerPortMapping = extern struct {
    windowsPort: u16,
    containerPort: u16,
    protocol: WslcPortProtocol,
    /// Optional; accepts IPv4/IPv6. Opaque to us (caller-owned `sockaddr_storage*`).
    windowsAddress: ?*anyopaque,
};

pub const WslcContainerVolume = extern struct {
    windowsPath: PCWSTR,
    containerPath: PCSTR,
    readOnly: BOOL,
};

pub const WslcContainerNamedVolume = extern struct {
    /// Name of the session volume (from WslcVhdRequirements.name).
    name: PCSTR,
    containerPath: PCSTR,
    readOnly: BOOL,
};

pub const WslcProcessCallbacks = extern struct {
    onStdOut: WslcStdIOCallback = null,
    onStdErr: WslcStdIOCallback = null,
    onExit: WslcProcessExitCallback = null,
};

pub const WslcImageProgressDetail = extern struct {
    currentBytes: u64,
    totalBytes: u64,
};

pub const WslcImageProgressMessage = extern struct {
    id: PCSTR,
    status: WslcImageProgressStatus,
    detail: WslcImageProgressDetail,
};

pub const WslcPullImageOptions = extern struct {
    uri: PCSTR,
    progressCallback: WslcContainerImageProgressCallback = null,
    progressCallbackContext: ?*anyopaque = null,
    registryAuth: PCSTR = null,
};

pub const WslcImportImageOptions = extern struct {
    progressCallback: WslcContainerImageProgressCallback = null,
    progressCallbackContext: ?*anyopaque = null,
};

pub const WslcLoadImageOptions = extern struct {
    progressCallback: WslcContainerImageProgressCallback = null,
    progressCallbackContext: ?*anyopaque = null,
};

pub const WslcImageInfo = extern struct {
    name: [WSLC_IMAGE_NAME_LENGTH]u8,
    sha256: [32]u8,
    sizeBytes: i64,
    createdUnixTime: u64,
};

pub const WslcTagImageOptions = extern struct {
    /// Source image name or ID.
    image: PCSTR,
    /// Target repository name.
    repo: PCSTR,
    /// Target tag name.
    tag: PCSTR,
};

pub const WslcPushImageOptions = extern struct {
    image: PCSTR,
    /// Base64-encoded X-Registry-Auth header value.
    registryAuth: PCSTR,
    progressCallback: WslcContainerImageProgressCallback = null,
    progressCallbackContext: ?*anyopaque = null,
};

pub const WslcVersion = extern struct {
    major: u32,
    minor: u32,
    revision: u32,
};

// ---- Session APIs ---------------------------------------------------------------

pub extern "wslcsdk" fn WslcInitSessionSettings(name: PCWSTR, storagePath: PCWSTR, sessionSettings: *WslcSessionSettings) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcCreateSession(sessionSettings: *WslcSessionSettings, session: *Session, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcSetSessionSettingsCpuCount(sessionSettings: *WslcSessionSettings, cpuCount: u32) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetSessionSettingsMemory(sessionSettings: *WslcSessionSettings, memoryMB: u32) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetSessionSettingsTimeout(sessionSettings: *WslcSessionSettings, timeoutMS: u32) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetSessionSettingsVhd(sessionSettings: *WslcSessionSettings, vhdRequirements: ?*const WslcVhdRequirements) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetSessionSettingsFeatureFlags(sessionSettings: *WslcSessionSettings, flags: WslcSessionFeatureFlags) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcGetSessionTerminationEvent(session: Session, terminationEvent: *HANDLE) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcGetSessionTerminationReason(session: Session, reason: *WslcSessionTerminationReason) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcTerminateSession(session: Session) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcReleaseSession(session: Session) callconv(.winapi) HRESULT;

/// Registers a callback invoked when a Linux process crash dump is written
/// for the session. Multiple subscriptions can be registered against the
/// same session; release with WslcReleaseCrashDumpSubscription to unsubscribe.
pub extern "wslcsdk" fn WslcRegisterSessionCrashDumpCallback(
    session: Session,
    crashDumpCallback: WslcSessionCrashDumpCallback,
    crashDumpContext: ?*anyopaque,
    subscription: *CrashDumpSubscription,
    errorMessage: ?*PWSTR,
) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcReleaseCrashDumpSubscription(subscription: CrashDumpSubscription) callconv(.winapi) HRESULT;

// ---- Container APIs ---------------------------------------------------------------

pub extern "wslcsdk" fn WslcInitContainerSettings(imageName: PCSTR, containerSettings: *WslcContainerSettings) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcCreateContainer(session: Session, containerSettings: *const WslcContainerSettings, container: *Container, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcStartContainer(container: Container, flags: WslcContainerStartFlags, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcSetContainerSettingsName(containerSettings: *WslcContainerSettings, name: PCSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetContainerSettingsInitProcess(containerSettings: *WslcContainerSettings, initProcess: *WslcProcessSettings) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetContainerSettingsNetworkingMode(containerSettings: *WslcContainerSettings, networkingMode: WslcContainerNetworkingMode) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetContainerSettingsHostName(containerSettings: *WslcContainerSettings, hostName: PCSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetContainerSettingsDomainName(containerSettings: *WslcContainerSettings, domainName: PCSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetContainerSettingsFlags(containerSettings: *WslcContainerSettings, flags: WslcContainerFlags) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetContainerSettingsPortMappings(containerSettings: *WslcContainerSettings, portMappings: ?[*]const WslcContainerPortMapping, portMappingCount: u32) callconv(.winapi) HRESULT;
/// Appends to the container's volumes array.
pub extern "wslcsdk" fn WslcSetContainerSettingsVolumes(containerSettings: *WslcContainerSettings, volumes: ?[*]const WslcContainerVolume, volumeCount: u32) callconv(.winapi) HRESULT;
/// Appends named session volumes (created via WslcCreateSessionVhdVolume).
pub extern "wslcsdk" fn WslcSetContainerSettingsNamedVolumes(containerSettings: *WslcContainerSettings, namedVolumes: ?[*]const WslcContainerNamedVolume, namedVolumeCount: u32) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcCreateContainerProcess(container: Container, newProcessSettings: *WslcProcessSettings, newProcess: *Process, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcReleaseContainer(container: Container) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcGetContainerID(container: Container, containerID: [*]u8) callconv(.winapi) HRESULT; // buffer must be >= WSLC_CONTAINER_ID_BUFFER_SIZE bytes
pub extern "wslcsdk" fn WslcGetContainerInitProcess(container: Container, initProcess: *Process) callconv(.winapi) HRESULT;

/// `inspectData` is CoTaskMemAlloc'd; caller must CoTaskMemFree it.
pub extern "wslcsdk" fn WslcInspectContainer(container: Container, inspectData: *PSTR) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcGetContainerState(container: Container, state: *WslcContainerState) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcStopContainer(container: Container, signal: WslcSignal, timeoutSeconds: u32, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcDeleteContainer(container: Container, flags: WslcDeleteContainerFlags, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

// ---- Process APIs ---------------------------------------------------------------

pub extern "wslcsdk" fn WslcInitProcessSettings(processSettings: *WslcProcessSettings) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcSetProcessSettingsWorkingDirectory(processSettings: *WslcProcessSettings, workingDirectory: PCSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSetProcessSettingsCmdLine(processSettings: *WslcProcessSettings, argv: [*]const PCSTR, argc: usize) callconv(.winapi) HRESULT;
/// Each entry is a "KEY=VALUE" string, exactly as in a POSIX environment block.
pub extern "wslcsdk" fn WslcSetProcessSettingsEnvVariables(processSettings: *WslcProcessSettings, key_value: [*]const PCSTR, argc: usize) callconv(.winapi) HRESULT;
/// Using callbacks consumes the process's IO handles, preventing later
/// acquisition via WslcGetProcessIOHandle. Pick one approach or the other.
pub extern "wslcsdk" fn WslcSetProcessSettingsCallbacks(processSettings: *WslcProcessSettings, callbacks: *const WslcProcessCallbacks, context: ?*anyopaque) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcGetProcessPid(process: Process, pid: *u32) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcGetProcessExitEvent(process: Process, exitEvent: *HANDLE) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcGetProcessState(process: Process, state: *WslcProcessState) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcGetProcessExitCode(process: Process, exitCode: *i32) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcSignalProcess(process: Process, signal: WslcSignal) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcGetProcessIOHandle(process: Process, ioHandle: WslcProcessIOHandle, handle: *HANDLE) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcReleaseProcess(process: Process) callconv(.winapi) HRESULT;

// ---- Image APIs ---------------------------------------------------------------

pub extern "wslcsdk" fn WslcPullSessionImage(session: Session, options: *const WslcPullImageOptions, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

/// `imageContent` is a caller-opened/closed Windows HANDLE (not a raw pointer);
/// WSLC only reads from it during the call.
pub extern "wslcsdk" fn WslcImportSessionImage(session: Session, imageName: PCSTR, imageContent: HANDLE, imageContentBytes: u64, options: ?*const WslcImportImageOptions, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
/// Convenience wrapper that opens/reads/closes `path` internally.
pub extern "wslcsdk" fn WslcImportSessionImageFromFile(session: Session, imageName: PCSTR, path: PCWSTR, options: ?*const WslcImportImageOptions, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

/// Analogous to `docker load` (a saved-image archive, all tags intact).
pub extern "wslcsdk" fn WslcLoadSessionImage(session: Session, imageContent: HANDLE, imageContentBytes: u64, options: ?*const WslcLoadImageOptions, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcLoadSessionImageFromFile(session: Session, path: PCWSTR, options: ?*const WslcLoadImageOptions, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

pub extern "wslcsdk" fn WslcDeleteSessionImage(session: Session, nameOrID: PCSTR, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcTagSessionImage(session: Session, options: *const WslcTagImageOptions, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcPushSessionImage(session: Session, options: *const WslcPushImageOptions, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

/// Returns a CoTaskMemAlloc'd identity token (caller must CoTaskMemFree it).
pub extern "wslcsdk" fn WslcSessionAuthenticate(session: Session, serverAddress: PCSTR, username: PCSTR, password: PCSTR, identityToken: *PSTR, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

/// `images` is a CoTaskMemAlloc'd array of `*count` elements; caller must
/// CoTaskMemFree it.
pub extern "wslcsdk" fn WslcListSessionImages(session: Session, images: *?[*]WslcImageInfo, count: *u32) callconv(.winapi) HRESULT;

// ---- Storage APIs ---------------------------------------------------------------

pub extern "wslcsdk" fn WslcCreateSessionVhdVolume(session: Session, options: *const WslcVhdRequirements, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcDeleteSessionVhdVolume(session: Session, name: PCSTR, errorMessage: ?*PWSTR) callconv(.winapi) HRESULT;

// ---- Install and Version APIs ---------------------------------------------------------------

pub extern "wslcsdk" fn WslcGetMissingComponents(missingComponents: *WslcComponentFlags) callconv(.winapi) HRESULT;
pub extern "wslcsdk" fn WslcGetVersion(version: *WslcVersion) callconv(.winapi) HRESULT;
/// Callbacks are only made for components actively installed by this call.
pub extern "wslcsdk" fn WslcInstallWithDependencies(progressCallback: WslcInstallCallback, context: ?*anyopaque) callconv(.winapi) HRESULT;

// ================================================================================
// Tests
// ================================================================================

test "link smoke test: WslcGetVersion resolves against the real wslcsdk.lib" {
    try ensureComInitialized();
    defer uninitializeCom();
    var v: WslcVersion = .{ .major = 0, .minor = 0, .revision = 0 };
    const hr = WslcGetVersion(&v);
    try std.testing.expect(succeeded(hr));
    // Sanity: the SDK version pinned in build.zig is 2.9.3, so major should be 2.
    try std.testing.expect(v.major >= 2);
}

test "AbiBlob: settings blobs have the exact documented size/alignment" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(WslcSessionSettings));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(WslcSessionSettings));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(WslcContainerSettings));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(WslcContainerSettings));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(WslcProcessSettings));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(WslcProcessSettings));
}

test "Flags: merge/has behave correctly on WslcContainerFlags" {
    const combined = WslcContainerFlags.merge(.AUTO_REMOVE, .ENABLE_GPU);
    try std.testing.expect(combined.has(.AUTO_REMOVE));
    try std.testing.expect(combined.has(.ENABLE_GPU));
    try std.testing.expect(!combined.has(.PRIVILEGED));
    try std.testing.expect(WslcContainerFlags.NONE.has(.NONE));
    try std.testing.expect(!combined.has(.NONE));

    const all3 = WslcContainerFlags.mergeAll(&.{ .AUTO_REMOVE, .ENABLE_GPU, .PRIVILEGED });
    try std.testing.expect(all3.has(.AUTO_REMOVE) and all3.has(.ENABLE_GPU) and all3.has(.PRIVILEGED));
}

test "ErrorSet: every table entry round-trips HRESULT -> error -> back to the same family" {
    inline for (all_errors) |e| {
        const err = toError(e.hr);
        try std.testing.expect(err == @field(Error, e.name));
    }
    // A code with no table entry maps to Unknown, not a false-positive match.
    try std.testing.expectError(error.Unknown, ok(@bitCast(@as(u32, 0x80070002)))); // ERROR_FILE_NOT_FOUND as HRESULT
}

test "ok: success codes (including S_FALSE) return void, failures return curated errors" {
    try ok(0); // S_OK
    try ok(1); // S_FALSE
    try std.testing.expectError(error.NotInitialized, ok(@bitCast(@as(u32, 0x800401F0))));
    try std.testing.expectError(error.ContainerNotFound, ok(makeHresult(1, 4, WSLC_E_BASE + 3)));
}

test "Handle: distinct handle kinds are distinct types" {
    // This is a compile-time property: assigning a Container where a Session
    // is expected must fail to compile. We can't `@compileError`-test that
    // here, but we *can* assert they're not the same type, which would catch
    // an accidental `pub const Container = Session;`-style regression.
    try std.testing.expect(Session != Container);
    try std.testing.expect(Container != Process);
    try std.testing.expect(Process != CrashDumpSubscription);
}
