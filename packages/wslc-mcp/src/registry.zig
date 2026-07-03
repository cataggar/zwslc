//! In-memory registry of containers created via MCP tool calls, keyed by an
//! opaque `ContainerId` handed back to the calling agent.
//!
//! This is the core reason an MCP server (long-lived) can do things the
//! stateless `zwslc` CLI can't: `container_status`/`container_logs`/
//! `stop_container`/etc. can look a container back up by id across separate
//! tool calls within the same server session. The WSLC SDK itself has no
//! list/reopen-by-ID API — this registry, not the SDK, is what provides
//! that continuity, and only within this one server process (see GitHub
//! issue #2's "why this is more than expose the CLI as tools" rationale,
//! and the registry-lifetime caveat in docs/mcp-server.md).

const std = @import("std");
const wslc = @import("wslc");

pub const ContainerId = u64;

/// A container tracked by this MCP server session, along with enough
/// bookkeeping to answer `container_status`/`container_logs` without the
/// SDK's help.
pub const Entry = struct {
    container: wslc.Container,
    name: ?[]u8,
    image: []u8,
    auto_remove: bool,
    created_at_ms: i64,
};

/// Mutex-guarded map from `ContainerId` to `Entry`. Guards concurrent MCP
/// tool calls (issue #2's concurrency question) with a single
/// coarse-grained `std.Io.Mutex` (Zig 0.16's replacement for
/// `std.Thread.Mutex`, requiring an `io: std.Io` argument on lock/unlock —
/// pass the same `Io` your tool handler was called with) — simple and
/// sufficient at the scale of "containers a human/agent is actively
/// juggling in one session".
///
/// `getAssumeLocked` returns a pointer that is only valid while
/// `self.mutex` is held. Callers that need to look up an entry *and* act on
/// it (e.g. `stop_container` calling `.state()` then `.stop()`) should
/// `lock()`/`defer unlock()` around the whole operation rather than
/// releasing the lock between the lookup and the action.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    next_id: ContainerId = 1,
    entries: std.AutoHashMapUnmanaged(ContainerId, Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// Best-effort cleanup for anything still registered when the server
    /// exits: stops + deletes `auto_remove` containers (matching `docker
    /// run --rm` semantics), and always releases the local handle either
    /// way. Containers registered with `auto_remove = false` are
    /// intentionally left running — same as exiting a shell that started a
    /// detached `docker run` container without `--rm` — see
    /// docs/mcp-server.md. A hard crash (not a clean `deinit`) can still
    /// orphan containers; that's a documented limitation, not a bug this
    /// registry tries to fully solve.
    ///
    /// Not locked: called once at shutdown, after `server.run()` has
    /// returned and no concurrent tool calls remain in flight.
    pub fn deinit(self: *Registry) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (entry.auto_remove) {
                if (entry.container.state()) |st| {
                    if (st == .RUNNING) entry.container.stop(.SIGTERM, 10) catch {};
                } else |_| {}
                entry.container.delete(.NONE) catch {};
            }
            entry.container.deinit();
            self.allocator.free(entry.image);
            if (entry.name) |n| self.allocator.free(n);
        }
        self.entries.deinit(self.allocator);
    }

    /// `io` is required by `std.Io.Mutex` (Zig 0.16) — pass the same `Io`
    /// your tool handler was called with (or `std.testing.io` in tests).
    pub fn lock(self: *Registry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
    }

    pub fn unlock(self: *Registry, io: std.Io) void {
        self.mutex.unlock(io);
    }

    /// Registers `container` (the registry takes ownership: it will call
    /// `.deinit()` on it when removed via `remove()` or on server exit) and
    /// returns the opaque id to hand back to the calling agent. `name`/
    /// `image` are copied. Thread-safe.
    pub fn register(self: *Registry, io: std.Io, container: wslc.Container, name: ?[]const u8, image: []const u8, auto_remove: bool) !ContainerId {
        const owned_image = try self.allocator.dupe(u8, image);
        errdefer self.allocator.free(owned_image);
        const owned_name = if (name) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (owned_name) |n| self.allocator.free(n);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const id = self.next_id;
        self.next_id += 1;
        try self.entries.put(self.allocator, id, .{
            .container = container,
            .name = owned_name,
            .image = owned_image,
            .auto_remove = auto_remove,
            .created_at_ms = std.Io.Clock.real.now(io).toMilliseconds(),
        });
        return id;
    }

    /// Returns a pointer to the entry for `id`, or `null` if not
    /// registered (e.g. already removed, or never existed). Only valid
    /// while `self.mutex` is held — call `lock()` first (see the type doc
    /// comment).
    pub fn getAssumeLocked(self: *Registry, id: ContainerId) ?*Entry {
        return self.entries.getPtr(id);
    }

    /// Removes `id` from the registry and returns ownership of its `Entry`
    /// to the caller, who becomes responsible for calling
    /// `.container.deinit()` and freeing `.name`/`.image` via
    /// `self.allocator`. Thread-safe.
    pub fn remove(self: *Registry, io: std.Io, id: ContainerId) ?Entry {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const kv = self.entries.fetchRemove(id) orelse return null;
        return kv.value;
    }

    /// Number of currently-registered containers. Thread-safe.
    pub fn count(self: *Registry, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.entries.count();
    }
};

test "Registry: register/get/remove/count round-trip (no real SDK calls)" {
    // Uses bare `.{ .handle = null }` containers: this test only exercises
    // the registry's own bookkeeping (register/get/remove/count), never
    // `Entry.container`'s methods, so it needs no real wslcsdk.dll / COM
    // init, unlike `Registry.deinit()`'s cleanup path.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var registry = Registry.init(allocator);

    const fake: wslc.Container = .{ .handle = null };
    const id1 = try registry.register(io, fake, "web", "alpine:latest", true);
    const id2 = try registry.register(io, fake, null, "busybox:latest", false);

    try std.testing.expect(id1 != id2);
    try std.testing.expectEqual(@as(usize, 2), registry.count(io));

    {
        registry.lock(io);
        defer registry.unlock(io);
        const entry1 = registry.getAssumeLocked(id1).?;
        try std.testing.expectEqualStrings("web", entry1.name.?);
        try std.testing.expectEqualStrings("alpine:latest", entry1.image);
        try std.testing.expect(entry1.auto_remove);

        const entry2 = registry.getAssumeLocked(id2).?;
        try std.testing.expect(entry2.name == null);
        try std.testing.expectEqualStrings("busybox:latest", entry2.image);
        try std.testing.expect(!entry2.auto_remove);

        try std.testing.expect(registry.getAssumeLocked(999) == null);
    }

    // Remove (and free) both before `registry.deinit()`, so its cleanup
    // path finds an empty map and never touches our fake handles.
    if (registry.remove(io, id1)) |e| {
        allocator.free(e.image);
        if (e.name) |n| allocator.free(n);
    }
    if (registry.remove(io, id2)) |e| {
        allocator.free(e.image);
        if (e.name) |n| allocator.free(n);
    }
    try std.testing.expectEqual(@as(usize, 0), registry.count(io));
    try std.testing.expect(registry.remove(io, id1) == null);

    registry.deinit();
}
