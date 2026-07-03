//! Shared application state handed to MCP tool handlers via `Tool.user_data`.
//!
//! Unlike the stateless `zwslc` CLI (which creates a fresh `wslc.Session`
//! per invocation - cheap, since WSLC images are durably stored under a
//! fixed storage path regardless of which session lists them), this MCP
//! server creates **one** session and shares it across every tool call for
//! its whole process lifetime. That's required (not just an optimization)
//! for container tools: a container's validity is tied to the session that
//! created it, so a detached container created via `create_container` must
//! be created against a session that stays alive for later
//! `container_status`/`stop_container`/`delete_container` calls in the same
//! server session.
//!
//! The session is created **lazily**, on first use by a tool that actually
//! needs one (`list_images` and friends) rather than eagerly at server
//! startup - so `get_version`/`get_missing_components` keep working even
//! before the WSL container feature is installed, matching how the SDK
//! itself expects those two calls to be usable as a prerequisite check
//! before anything else (see `wslc.getMissingComponents`'s doc comment).

const std = @import("std");
const wslc = @import("wslc");
const registry_mod = @import("registry.zig");

pub const Registry = registry_mod.Registry;

pub const AppContext = struct {
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    registry: Registry,
    session_mutex: std.Io.Mutex = .init,
    session: ?wslc.Session = null,

    pub fn init(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) AppContext {
        return .{
            .gpa = gpa,
            .environ = environ,
            .registry = Registry.init(gpa),
        };
    }

    pub fn deinit(self: *AppContext) void {
        self.registry.deinit();
        if (self.session) |*s| s.deinit();
    }

    /// Returns the shared session, creating it on first call. `io` is
    /// required by `std.Io.Mutex` (Zig 0.16) — pass the same `Io` your tool
    /// handler was called with.
    pub fn getSession(self: *AppContext, io: std.Io) !*wslc.Session {
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        if (self.session == null) {
            self.session = try defaultSession(self.gpa, self.environ);
        }
        return &self.session.?;
    }
};

/// Resolves the **same** session storage directory the real `wslc.exe` CLI
/// uses for its default session
/// (`%LOCALAPPDATA%\wslc\sessions\wslc-cli-<username>` - confirmed by
/// inspecting that directory after running the real `wslc.exe images`;
/// mirrors the identical change in `cli/src/main.zig`'s `defaultSession`)
/// and creates a `wslc.Session` against it, so the MCP server's image/
/// container tools see and share the exact same images as the real tool
/// (and zwslc's own CLI) instead of maintaining a third, disconnected image
/// store.
fn defaultSession(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !wslc.Session {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const local_app_data = environ.get("LOCALAPPDATA") orelse return error.LocalAppDataNotSet;
    const username = environ.get("USERNAME") orelse return error.UsernameNotSet;
    const storage_path = try std.fmt.allocPrint(arena, "{s}\\wslc\\sessions\\wslc-cli-{s}", .{ local_app_data, username });
    try createDirectoryRecursive(arena, storage_path);

    return wslc.Session.create(gpa, .{
        .name = "zwslc-mcp",
        .storage_path = storage_path,
    });
}

extern "kernel32" fn CreateDirectoryW(path: ?[*:0]const u16, security_attributes: ?*anyopaque) callconv(.winapi) i32;

fn createDirectoryRecursive(arena: std.mem.Allocator, path: []const u8) !void {
    // Create each path component from the root down (CreateDirectoryW isn't
    // recursive); ignore failures (already-exists is the common case, and
    // any real problem will surface clearly when the session create fails).
    var end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, end, '\\')) |sep| {
        end = sep + 1;
        try createOne(arena, path[0..sep]);
    }
    try createOne(arena, path);
}

fn createOne(arena: std.mem.Allocator, path: []const u8) !void {
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, path);
    _ = CreateDirectoryW(path_w.ptr, null);
}
