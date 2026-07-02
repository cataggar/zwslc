//! Idiomatic wrapper around `WslcProcess`/`WslcProcessSettings`.
//!
//! The callback trampoline generators (`stdioCallback`/`exitCallback`) are
//! the main "why comptime" demonstration in this package: the C API wants a
//! plain `callconv(.winapi)` function pointer plus an opaque `PVOID context`
//! (it has no notion of a Zig closure), so a *runtime* value can't carry
//! per-instance behavior the way a closure would. Instead, each generator
//! takes the context type and handler function as `comptime` parameters and
//! synthesizes a fresh, ABI-correct trampoline function per (Ctx, handler)
//! pair at compile time — the caller only ever deals with plain typed
//! functions and a `*Ctx` pointer, never raw `anyopaque`/`callconv(.winapi)`
//! plumbing.

const std = @import("std");
const sys = @import("wslc-sys");
const strings = @import("strings.zig");

pub const Process = struct {
    handle: sys.Process,

    pub fn pid(self: Process) sys.Error!u32 {
        var v: u32 = 0;
        try sys.ok(sys.WslcGetProcessPid(self.handle, &v));
        return v;
    }

    pub fn state(self: Process) sys.Error!sys.WslcProcessState {
        var v: sys.WslcProcessState = .UNKNOWN;
        try sys.ok(sys.WslcGetProcessState(self.handle, &v));
        return v;
    }

    pub fn exitCode(self: Process) sys.Error!i32 {
        var v: i32 = 0;
        try sys.ok(sys.WslcGetProcessExitCode(self.handle, &v));
        return v;
    }

    /// Returns the process's exit `HANDLE`, signaled when it exits. Pass to
    /// `WaitForSingleObject`/`WaitForMultipleObjects` (or use `waitForExit`).
    pub fn exitEvent(self: Process) sys.Error!sys.HANDLE {
        var h: sys.HANDLE = null;
        try sys.ok(sys.WslcGetProcessExitEvent(self.handle, &h));
        return h;
    }

    /// Convenience: blocks (up to `timeout_ms`, or `null` for `INFINITE`)
    /// until the process exits, then returns its exit code.
    pub fn waitForExit(self: Process, timeout_ms: ?u32) sys.Error!i32 {
        const h = try self.exitEvent();
        _ = WaitForSingleObject(h, timeout_ms orelse INFINITE);
        return self.exitCode();
    }

    pub fn signal(self: Process, sig: sys.WslcSignal) sys.Error!void {
        try sys.ok(sys.WslcSignalProcess(self.handle, sig));
    }

    pub fn ioHandle(self: Process, which: sys.WslcProcessIOHandle) sys.Error!sys.HANDLE {
        var h: sys.HANDLE = null;
        try sys.ok(sys.WslcGetProcessIOHandle(self.handle, which, &h));
        return h;
    }

    /// Releases the local reference to this process. Does not stop it.
    pub fn deinit(self: *Process) void {
        _ = sys.WslcReleaseProcess(self.handle);
        self.handle = null;
    }
};

extern "kernel32" fn WaitForSingleObject(handle: sys.HANDLE, milliseconds: u32) callconv(.winapi) u32;
const INFINITE: u32 = 0xFFFFFFFF;

/// Zig-native process settings. `build()` sequences the
/// `WslcInitProcessSettings`/`WslcSetProcessSettings*` calls into a raw
/// `sys.WslcProcessSettings` blob; callers normally go through
/// `Session.createContainer`/`Container.createProcess` instead of calling
/// this directly.
pub const ProcessSettings = struct {
    working_directory: ?[]const u8 = null,
    /// argv[0] is the program to execute.
    cmd_line: []const []const u8,
    /// "KEY=VALUE" strings; if empty, the container's default environment is used.
    env_variables: []const []const u8 = &.{},
    callbacks: ?sys.WslcProcessCallbacks = null,
    callbacks_context: ?*anyopaque = null,

    /// Owns temporary allocations (null-terminated string copies) needed to
    /// call the raw `Wslc*` builder functions; freed before returning.
    pub fn build(self: ProcessSettings, allocator: std.mem.Allocator) sys.Error!sys.WslcProcessSettings {
        var raw: sys.WslcProcessSettings = undefined;
        try sys.ok(sys.WslcInitProcessSettings(&raw));

        if (self.working_directory) |wd| {
            const wd_z = strings.narrowZ(allocator, wd) catch return error.OutOfMemory;
            defer allocator.free(wd_z);
            try sys.ok(sys.WslcSetProcessSettingsWorkingDirectory(&raw, wd_z.ptr));
        }

        {
            var argv = strings.narrowZArray(allocator, self.cmd_line) catch return error.OutOfMemory;
            defer argv.deinit(allocator);
            try sys.ok(sys.WslcSetProcessSettingsCmdLine(&raw, argv.ptrs.ptr, argv.ptrs.len));
        }

        if (self.env_variables.len != 0) {
            var envs = strings.narrowZArray(allocator, self.env_variables) catch return error.OutOfMemory;
            defer envs.deinit(allocator);
            try sys.ok(sys.WslcSetProcessSettingsEnvVariables(&raw, envs.ptrs.ptr, envs.ptrs.len));
        }

        if (self.callbacks) |*cbs| {
            try sys.ok(sys.WslcSetProcessSettingsCallbacks(&raw, cbs, self.callbacks_context));
        }

        return raw;
    }
};

/// Generates a `WslcStdIOCallback` trampoline that casts the opaque context
/// back to `*Ctx` and forwards to `handler`. `handler` receives the raw bytes
/// slice directly (not null-terminated, per the header's documented
/// semantics — see `WslcStdIOCallback` in `wslc-sys`).
pub fn stdioCallback(
    comptime Ctx: type,
    comptime handler: fn (ctx: *Ctx, io_handle: sys.WslcProcessIOHandle, data: []const u8) void,
) sys.WslcStdIOCallback {
    return struct {
        fn trampoline(io_handle: sys.WslcProcessIOHandle, data: [*]const u8, data_bytes: u32, context: ?*anyopaque) callconv(.winapi) void {
            const ctx: *Ctx = @ptrCast(@alignCast(context.?));
            handler(ctx, io_handle, data[0..data_bytes]);
        }
    }.trampoline;
}

/// Generates a `WslcProcessExitCallback` trampoline analogous to `stdioCallback`.
pub fn exitCallback(
    comptime Ctx: type,
    comptime handler: fn (ctx: *Ctx, exit_code: i32) void,
) sys.WslcProcessExitCallback {
    return struct {
        fn trampoline(exit_code: i32, context: ?*anyopaque) callconv(.winapi) void {
            const ctx: *Ctx = @ptrCast(@alignCast(context.?));
            handler(ctx, exit_code);
        }
    }.trampoline;
}

test "ProcessSettings.build sequences Init + CmdLine correctly" {
    try sys.ensureComInitialized();
    const settings = ProcessSettings{ .cmd_line = &.{ "/bin/echo", "hi" } };
    _ = try settings.build(std.testing.allocator);
}

test "stdioCallback/exitCallback trampolines forward to the typed handler" {
    const Ctx = struct {
        buf: std.ArrayList(u8),
        exit_code: ?i32 = null,

        fn onData(ctx: *@This(), io_handle: sys.WslcProcessIOHandle, data: []const u8) void {
            _ = io_handle;
            ctx.buf.appendSlice(std.testing.allocator, data) catch {};
        }
        fn onExit(ctx: *@This(), code: i32) void {
            ctx.exit_code = code;
        }
    };

    var ctx: Ctx = .{ .buf = .empty };
    defer ctx.buf.deinit(std.testing.allocator);

    const on_stdout = stdioCallback(Ctx, Ctx.onData);
    const on_exit = exitCallback(Ctx, Ctx.onExit);

    on_stdout.?(.STDOUT, "hello".ptr, 5, &ctx);
    try std.testing.expectEqualStrings("hello", ctx.buf.items);

    on_exit.?(42, &ctx);
    try std.testing.expectEqual(@as(?i32, 42), ctx.exit_code);
}
