//! Idiomatic wrapper around `WslcContainer`/`WslcContainerSettings`.

const std = @import("std");
const sys = @import("wslc-sys");
const strings = @import("strings.zig");
const process_mod = @import("process.zig");

pub const ProcessSettings = process_mod.ProcessSettings;
pub const Process = process_mod.Process;

pub const PortMapping = struct {
    windows_port: u16,
    container_port: u16,
    protocol: sys.WslcPortProtocol = .TCP,
};

pub const Volume = struct {
    windows_path: []const u8,
    container_path: []const u8,
    read_only: bool = false,
};

pub const NamedVolume = struct {
    /// Name of a session volume previously created via
    /// `Session.createVhdVolume`.
    name: []const u8,
    container_path: []const u8,
    read_only: bool = false,
};

/// Zig-native container settings. `build()` sequences the
/// `WslcInitContainerSettings`/`WslcSetContainerSettings*` calls into a raw
/// `sys.WslcContainerSettings` blob; normally reached via
/// `Session.createContainer` rather than called directly.
pub const ContainerSettings = struct {
    image_name: []const u8,
    name: ?[]const u8 = null,
    init_process: ?ProcessSettings = null,
    networking_mode: ?sys.WslcContainerNetworkingMode = null,
    host_name: ?[]const u8 = null,
    domain_name: ?[]const u8 = null,
    flags: sys.WslcContainerFlags = .NONE,
    port_mappings: []const PortMapping = &.{},
    volumes: []const Volume = &.{},
    named_volumes: []const NamedVolume = &.{},

    /// See `SessionSettings.build`'s doc comment in `session.zig`: the WSLC
    /// SDK retains string/array pointers rather than copying them at
    /// Init/Set time, so `allocator` must keep everything alive at least
    /// until the caller's subsequent `WslcCreateContainer` call completes —
    /// pass an arena and `deinit()` it only *after* that call, as
    /// `Session.createContainer` does. Nothing here is freed by `build()`
    /// itself.
    pub fn build(self: ContainerSettings, allocator: std.mem.Allocator, out: *sys.WslcContainerSettings) sys.Error!void {
        const image_name_z = strings.narrowZ(allocator, self.image_name) catch return error.OutOfMemory;

        // Built directly into `out` throughout (see the comment in
        // session.zig's SessionSettings.build for why we don't build in a
        // temporary and copy/return by value).
        try sys.ok(sys.WslcInitContainerSettings(image_name_z.ptr, out));

        if (self.name) |n| {
            const n_z = strings.narrowZ(allocator, n) catch return error.OutOfMemory;
            try sys.ok(sys.WslcSetContainerSettingsName(out, n_z.ptr));
        }

        if (self.init_process) |init_proc| {
            const raw_init_proc = allocator.create(sys.WslcProcessSettings) catch return error.OutOfMemory;
            try init_proc.build(allocator, raw_init_proc);
            try sys.ok(sys.WslcSetContainerSettingsInitProcess(out, raw_init_proc));
        }

        if (self.networking_mode) |mode| {
            try sys.ok(sys.WslcSetContainerSettingsNetworkingMode(out, mode));
        }

        if (self.host_name) |h| {
            const h_z = strings.narrowZ(allocator, h) catch return error.OutOfMemory;
            try sys.ok(sys.WslcSetContainerSettingsHostName(out, h_z.ptr));
        }

        if (self.domain_name) |d| {
            const d_z = strings.narrowZ(allocator, d) catch return error.OutOfMemory;
            try sys.ok(sys.WslcSetContainerSettingsDomainName(out, d_z.ptr));
        }

        if (self.flags != .NONE) {
            try sys.ok(sys.WslcSetContainerSettingsFlags(out, self.flags));
        }

        if (self.port_mappings.len != 0) {
            const raw_mappings = allocator.alloc(sys.WslcContainerPortMapping, self.port_mappings.len) catch return error.OutOfMemory;
            for (self.port_mappings, 0..) |m, i| {
                raw_mappings[i] = .{
                    .windowsPort = m.windows_port,
                    .containerPort = m.container_port,
                    .protocol = m.protocol,
                    .windowsAddress = null,
                };
            }
            try sys.ok(sys.WslcSetContainerSettingsPortMappings(out, raw_mappings.ptr, @intCast(raw_mappings.len)));
        }

        if (self.volumes.len != 0) {
            const raw_volumes = allocator.alloc(sys.WslcContainerVolume, self.volumes.len) catch return error.OutOfMemory;
            for (self.volumes, 0..) |v, i| {
                const wp = strings.wideZ(allocator, v.windows_path) catch return error.OutOfMemory;
                const cp = strings.narrowZ(allocator, v.container_path) catch return error.OutOfMemory;
                raw_volumes[i] = .{
                    .windowsPath = wp.ptr,
                    .containerPath = cp.ptr,
                    .readOnly = sys.boolToWin32(v.read_only),
                };
            }
            try sys.ok(sys.WslcSetContainerSettingsVolumes(out, raw_volumes.ptr, @intCast(raw_volumes.len)));
        }

        if (self.named_volumes.len != 0) {
            const raw_named = allocator.alloc(sys.WslcContainerNamedVolume, self.named_volumes.len) catch return error.OutOfMemory;
            for (self.named_volumes, 0..) |v, i| {
                const n = strings.narrowZ(allocator, v.name) catch return error.OutOfMemory;
                const cp = strings.narrowZ(allocator, v.container_path) catch return error.OutOfMemory;
                raw_named[i] = .{
                    .name = n.ptr,
                    .containerPath = cp.ptr,
                    .readOnly = sys.boolToWin32(v.read_only),
                };
            }
            try sys.ok(sys.WslcSetContainerSettingsNamedVolumes(out, raw_named.ptr, @intCast(raw_named.len)));
        }
    }
};

pub const Container = struct {
    handle: sys.Container,
    /// Owns the arena backing this container's `init_process` settings
    /// (including any registered callbacks) — see `Session.createContainer`.
    /// Must outlive the container, not just its creation, since WSLC appears
    /// to retain the callbacks pointer for the process's whole lifetime, not
    /// just through `WslcCreateContainer`. `null` for `Process`/`Container`
    /// wrappers around an already-existing handle (e.g. from `initProcess()`)
    /// that don't own any settings memory themselves.
    settings_arena: ?*std.heap.ArenaAllocator = null,

    pub fn start(self: Container, flags: sys.WslcContainerStartFlags) sys.Error!void {
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcStartContainer(self.handle, flags, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
    }

    pub fn stop(self: Container, sig: sys.WslcSignal, timeout_seconds: u32) sys.Error!void {
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcStopContainer(self.handle, sig, timeout_seconds, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
    }

    pub fn delete(self: Container, flags: sys.WslcDeleteContainerFlags) sys.Error!void {
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcDeleteContainer(self.handle, flags, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
    }

    pub fn state(self: Container) sys.Error!sys.WslcContainerState {
        var v: sys.WslcContainerState = .INVALID;
        try sys.ok(sys.WslcGetContainerState(self.handle, &v));
        return v;
    }

    /// Returns the container ID as an owned string; caller frees.
    pub fn id(self: Container, allocator: std.mem.Allocator) sys.Error![]u8 {
        var buf: [sys.WSLC_CONTAINER_ID_BUFFER_SIZE]u8 = undefined;
        try sys.ok(sys.WslcGetContainerID(self.handle, &buf));
        const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
        return allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }

    /// Returns the raw JSON inspection payload as an owned string; caller frees.
    pub fn inspect(self: Container, allocator: std.mem.Allocator) sys.Error![]u8 {
        var data: sys.PSTR = null;
        try sys.ok(sys.WslcInspectContainer(self.handle, &data));
        defer sys.freeTaskMem(data);
        const p = data orelse return allocator.dupe(u8, "") catch error.OutOfMemory;
        return allocator.dupe(u8, p[0..std.mem.len(p)]) catch return error.OutOfMemory;
    }

    /// Only valid if `ContainerSettings.init_process` was set.
    pub fn initProcess(self: Container) sys.Error!Process {
        var h: sys.Process = null;
        try sys.ok(sys.WslcGetContainerInitProcess(self.handle, &h));
        return .{ .handle = h };
    }

    pub fn createProcess(self: Container, allocator: std.mem.Allocator, settings: ProcessSettings) sys.Error!Process {
        // See `settings_arena`'s doc comment: this arena must outlive the
        // *process*, not just this function, so we hand it off to the
        // returned `Process` rather than deinit-ing it here.
        const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        var raw: sys.WslcProcessSettings = undefined;
        try settings.build(arena.allocator(), &raw);
        var h: sys.Process = null;
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcCreateContainerProcess(self.handle, &raw, &h, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
        return .{ .handle = h, .settings_arena = arena };
    }

    /// Releases the local reference to this container (and, if this
    /// `Container` owns one, its settings arena — see `settings_arena`).
    /// Does not stop/delete the container itself.
    pub fn deinit(self: *Container) void {
        _ = sys.WslcReleaseContainer(self.handle);
        self.handle = null;
        if (self.settings_arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
            self.settings_arena = null;
        }
    }
};

test "ContainerSettings.build sequences Init + optional setters correctly" {
    try sys.ensureComInitialized();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = ContainerSettings{
        .image_name = "alpine:latest",
        .name = "test-container",
        .init_process = .{ .cmd_line = &.{ "/bin/echo", "hi" } },
        .flags = sys.WslcContainerFlags.merge(.AUTO_REMOVE, .ENABLE_GPU),
        .volumes = &.{.{ .windows_path = "C:\\data", .container_path = "/mnt/data" }},
        .named_volumes = &.{.{ .name = "cache", .container_path = "/cache" }},
        .port_mappings = &.{.{ .windows_port = 8080, .container_port = 80 }},
    };
    var raw: sys.WslcContainerSettings = undefined;
    try settings.build(arena.allocator(), &raw);
}
