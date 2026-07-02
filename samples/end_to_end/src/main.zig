//! Zig port of Microsoft's documented C end-to-end example
//! (https://wsl.dev/api-reference/c/end-to-end-example/): check prerequisites,
//! create a session, pull an image, configure + create + start a container,
//! wait for its init process to exit, inspect it, then tear everything down.
//!
//! Requires the WSL container preview feature to actually be installed
//! (`WslcGetMissingComponents() == .NONE`) to get past the first check; on a
//! machine without it, this prints guidance and exits cleanly instead of
//! failing loudly, exactly like Microsoft's sample does.

const std = @import("std");
const wslc = @import("wslc");

extern "kernel32" fn CreateDirectoryW(path: ?[*:0]const u16, security_attributes: ?*anyopaque) callconv(.winapi) i32;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    // 0. Check prerequisites.
    const missing = wslc.getMissingComponents() catch |err| {
        std.debug.print("Failed to query WSL components: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (missing != .NONE) {
        std.debug.print("WSL components are missing. Run: wsl --install\n", .{});
        return;
    }

    const version = try wslc.getVersion();
    std.debug.print("WSL version: {d}.{d}.{d}\n", .{ version.major, version.minor, version.revision });

    // 1. Initialize and create a session.
    const temp_dir = init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse "C:\\Temp";
    const storage_path = try std.fmt.allocPrint(arena, "{s}\\zwslc-end-to-end-sample", .{temp_dir});
    {
        const storage_path_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, storage_path);
        _ = CreateDirectoryW(storage_path_w.ptr, null); // ignore result: fine if it already exists
    }
    std.debug.print("storage_path = {s}\n", .{storage_path});

    var session = wslc.Session.create(gpa, .{
        .name = "zwslc-end-to-end-sample",
        .storage_path = storage_path,
        .cpu_count = 4,
        .memory_mb = 4096,
    }) catch |err| {
        std.debug.print("Session creation failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    // 2. Pull an image.
    session.pullImage("docker.io/library/alpine:latest", .{}, gpa) catch |err| {
        std.debug.print("Pull failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // 3-4. Configure an init process + container, then create it.
    var container = session.createContainer(gpa, .{
        .image_name = "alpine:latest",
        .name = "zwslc-hello-container",
        .init_process = .{ .cmd_line = &.{ "/bin/echo", "Hello from WSL Container!" } },
    }) catch |err| {
        std.debug.print("Container creation failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer container.deinit();

    // 5. Start the container.
    container.start(.NONE) catch |err| {
        std.debug.print("Start failed: {s}\n", .{@errorName(err)});
        container.delete(.FORCE) catch {};
        std.process.exit(1);
    };

    // 6. Wait for the init process to exit.
    if (container.initProcess()) |init_proc| {
        const exit_code = init_proc.waitForExit(30_000) catch |err| blk: {
            std.debug.print("Failed waiting for init process: {s}\n", .{@errorName(err)});
            break :blk -1;
        };
        std.debug.print("Process exited with code: {d}\n", .{exit_code});
    } else |err| {
        std.debug.print("Failed to get init process: {s}\n", .{@errorName(err)});
    }

    // 7. Clean up.
    if (container.state()) |state| {
        if (state == .RUNNING) {
            container.stop(.SIGTERM, 10) catch {};
        }
    } else |_| {}
    container.delete(.NONE) catch |err| {
        std.debug.print("Delete failed: {s}\n", .{@errorName(err)});
    };
}
