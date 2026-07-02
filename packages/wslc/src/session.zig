//! Idiomatic wrapper around `WslcSession`/`WslcSessionSettings`.

const std = @import("std");
const sys = @import("wslc-sys");
const strings = @import("strings.zig");
const container_mod = @import("container.zig");

pub const Container = container_mod.Container;
pub const ContainerSettings = container_mod.ContainerSettings;

pub const VhdRequirements = struct {
    /// Session volume name (referenced later via `ContainerSettings`'s
    /// `named_volumes`, or `Session.deleteVhdVolume`).
    name: []const u8,
    size_bytes: u64,
    type: sys.WslcVhdType = .DYNAMIC,
    flags: sys.WslcVhdRequirementsFlags = .NONE,
    uid: u32 = 0,
    gid: u32 = 0,
};

/// Zig-native session settings. `build()` sequences the
/// `WslcInitSessionSettings`/`WslcSetSessionSettings*` calls into a raw
/// `sys.WslcSessionSettings` blob; normally reached via `Session.create`
/// rather than called directly.
pub const SessionSettings = struct {
    name: []const u8,
    storage_path: []const u8,
    cpu_count: ?u32 = null,
    memory_mb: ?u32 = null,
    timeout_ms: ?u32 = null,
    vhd: ?VhdRequirements = null,
    feature_flags: sys.WslcSessionFeatureFlags = .NONE,

    pub fn build(self: SessionSettings, allocator: std.mem.Allocator) sys.Error!sys.WslcSessionSettings {
        const name_w = strings.wideZ(allocator, self.name) catch return error.OutOfMemory;
        defer allocator.free(name_w);
        const storage_w = strings.wideZ(allocator, self.storage_path) catch return error.OutOfMemory;
        defer allocator.free(storage_w);

        var raw: sys.WslcSessionSettings = undefined;
        try sys.ok(sys.WslcInitSessionSettings(name_w.ptr, storage_w.ptr, &raw));

        if (self.cpu_count) |c| try sys.ok(sys.WslcSetSessionSettingsCpuCount(&raw, c));
        if (self.memory_mb) |m| try sys.ok(sys.WslcSetSessionSettingsMemory(&raw, m));
        if (self.timeout_ms) |t| try sys.ok(sys.WslcSetSessionSettingsTimeout(&raw, t));

        if (self.vhd) |vhd| {
            const vhd_name_z = strings.narrowZ(allocator, vhd.name) catch return error.OutOfMemory;
            defer allocator.free(vhd_name_z);
            var raw_vhd: sys.WslcVhdRequirements = .{
                .name = vhd_name_z.ptr,
                .sizeBytes = vhd.size_bytes,
                .@"type" = vhd.type,
                .flags = vhd.flags,
                .uid = vhd.uid,
                .gid = vhd.gid,
            };
            try sys.ok(sys.WslcSetSessionSettingsVhd(&raw, &raw_vhd));
        }

        if (self.feature_flags != .NONE) {
            try sys.ok(sys.WslcSetSessionSettingsFeatureFlags(&raw, self.feature_flags));
        }

        return raw;
    }
};

pub const Session = struct {
    handle: sys.Session,

    pub fn create(allocator: std.mem.Allocator, settings: SessionSettings) sys.Error!Session {
        try sys.ensureComInitialized();
        var raw = try settings.build(allocator);

        var handle: sys.Session = null;
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcCreateSession(&raw, &handle, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
        return .{ .handle = handle };
    }

    /// Terminates and releases the session. Prefer this over calling
    /// `WslcTerminateSession`/`WslcReleaseSession` manually.
    pub fn deinit(self: *Session) void {
        _ = sys.WslcTerminateSession(self.handle);
        _ = sys.WslcReleaseSession(self.handle);
        self.handle = null;
    }

    pub fn terminationEvent(self: Session) sys.Error!sys.HANDLE {
        var h: sys.HANDLE = null;
        try sys.ok(sys.WslcGetSessionTerminationEvent(self.handle, &h));
        return h;
    }

    pub fn terminationReason(self: Session) sys.Error!sys.WslcSessionTerminationReason {
        var v: sys.WslcSessionTerminationReason = .UNKNOWN;
        try sys.ok(sys.WslcGetSessionTerminationReason(self.handle, &v));
        return v;
    }

    pub fn createContainer(self: Session, allocator: std.mem.Allocator, settings: ContainerSettings) sys.Error!Container {
        var raw = try settings.build(allocator);
        var handle: sys.Container = null;
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcCreateContainer(self.handle, &raw, &handle, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
        return .{ .handle = handle };
    }

    pub fn pullImage(self: Session, uri: []const u8, options: struct {
        registry_auth: ?[]const u8 = null,
        progress_callback: sys.WslcContainerImageProgressCallback = null,
        progress_callback_context: ?*anyopaque = null,
    }, allocator: std.mem.Allocator) sys.Error!void {
        const uri_z = strings.narrowZ(allocator, uri) catch return error.OutOfMemory;
        defer allocator.free(uri_z);
        var auth_z: ?[:0]u8 = null;
        defer if (auth_z) |a| allocator.free(a);
        if (options.registry_auth) |a| auth_z = strings.narrowZ(allocator, a) catch return error.OutOfMemory;

        const raw_options: sys.WslcPullImageOptions = .{
            .uri = uri_z.ptr,
            .progressCallback = options.progress_callback,
            .progressCallbackContext = options.progress_callback_context,
            .registryAuth = if (auth_z) |a| a.ptr else null,
        };
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcPullSessionImage(self.handle, &raw_options, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
    }

    pub fn deleteImage(self: Session, name_or_id: []const u8, allocator: std.mem.Allocator) sys.Error!void {
        const z = strings.narrowZ(allocator, name_or_id) catch return error.OutOfMemory;
        defer allocator.free(z);
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcDeleteSessionImage(self.handle, z.ptr, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
    }

    /// Returns an owned slice of images; caller frees with `allocator.free`.
    pub fn listImages(self: Session, allocator: std.mem.Allocator) sys.Error![]sys.WslcImageInfo {
        var raw_images: ?[*]sys.WslcImageInfo = null;
        var count: u32 = 0;
        try sys.ok(sys.WslcListSessionImages(self.handle, &raw_images, &count));
        const p = raw_images orelse return &.{};
        defer sys.freeTaskMem(p);
        return allocator.dupe(sys.WslcImageInfo, p[0..count]) catch return error.OutOfMemory;
    }

    pub fn createVhdVolume(self: Session, req: VhdRequirements, allocator: std.mem.Allocator) sys.Error!void {
        const name_z = strings.narrowZ(allocator, req.name) catch return error.OutOfMemory;
        defer allocator.free(name_z);
        var raw_req: sys.WslcVhdRequirements = .{
            .name = name_z.ptr,
            .sizeBytes = req.size_bytes,
            .@"type" = req.type,
            .flags = req.flags,
            .uid = req.uid,
            .gid = req.gid,
        };
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcCreateSessionVhdVolume(self.handle, &raw_req, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
    }

    pub fn deleteVhdVolume(self: Session, name: []const u8, allocator: std.mem.Allocator) sys.Error!void {
        const name_z = strings.narrowZ(allocator, name) catch return error.OutOfMemory;
        defer allocator.free(name_z);
        var err_msg: sys.PWSTR = null;
        const hr = sys.WslcDeleteSessionVhdVolume(self.handle, name_z.ptr, &err_msg);
        sys.freeTaskMem(err_msg);
        try sys.ok(hr);
    }
};

test "SessionSettings.build sequences Init + optional setters correctly" {
    try sys.ensureComInitialized();
    const settings = SessionSettings{
        .name = "test-session",
        .storage_path = "C:\\wslc-test",
        .cpu_count = 2,
        .memory_mb = 2048,
        .feature_flags = .ENABLE_GPU,
    };
    _ = try settings.build(std.testing.allocator);
}
