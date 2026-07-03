//! zwslc: a CLI reproducing the shape of the real `wslc.exe`, built on the
//! `wslc` package.
//!
//! Scope (see the project plan's command-coverage table for the full
//! rationale): every command here is backed 1:1 by the public WSLC C API.
//! `container run` is a foreground create->start->wait->cleanup flow (the
//! SDK has no "list all containers"/"reopen by ID" call, so there's no way
//! to `stop`/`rm`/`ps` a container created by a *previous* invocation of this
//! CLI). Images, by contrast, are durably stored under a fixed per-machine
//! storage path, so `image list/pull/tag/push/rm` *do* work across separate
//! invocations, even though each invocation creates a fresh `WslcSession`
//! under the hood.

const std = @import("std");
const wslc = @import("wslc");
const build_options = @import("build_options");
const container_cmds = @import("container_cmds.zig");
const image_cmds = @import("image_cmds.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    const exit_code = run(gpa, arena, init.environ_map, argv[1..]) catch |err| {
        std.debug.print("zwslc: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

/// Resolves the fixed, per-machine session storage directory
/// (`%LOCALAPPDATA%\zwslc\storage`) and creates a `wslc.Session` against it.
/// Since WSLC images are durably stored under this path, `image` commands
/// see the same images across separate CLI invocations even though a new
/// `WslcSession` is created every time.
pub fn defaultSession(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !wslc.Session {
    const local_app_data = environ.get("LOCALAPPDATA") orelse return error.LocalAppDataNotSet;
    const storage_path = try std.fmt.allocPrint(arena, "{s}\\zwslc\\storage", .{local_app_data});
    try createDirectoryRecursive(arena, storage_path);

    return wslc.Session.create(gpa, .{
        .name = "zwslc-default",
        .storage_path = storage_path,
    }) catch |err| {
        std.debug.print("zwslc: failed to create session (storage_path={s}): {s}\n", .{ storage_path, @errorName(err) });
        return err;
    };
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

fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    if (args.len == 0) {
        printUsage();
        return 1;
    }
    const cmd = args[0];
    const rest = args[1..];

    if (eq(cmd, "version")) return cmdVersion();

    if (eq(cmd, "run")) return container_cmds.run(gpa, arena, environ, rest);
    if (eq(cmd, "pull")) return image_cmds.pull(gpa, arena, environ, rest);
    if (eq(cmd, "images")) return image_cmds.list(gpa, arena, environ, rest);
    if (eq(cmd, "rmi")) return image_cmds.remove(gpa, arena, environ, rest);
    if (eq(cmd, "tag")) return image_cmds.tag(gpa, arena, environ, rest);
    if (eq(cmd, "push")) return image_cmds.push(gpa, arena, environ, rest);

    if (eq(cmd, "container")) {
        if (rest.len == 0) {
            std.debug.print("zwslc: 'container' requires a subcommand (run/ls/ps/prune/...)\n", .{});
            return 1;
        }
        const sub = rest[0];
        const sub_rest = rest[1..];
        if (eq(sub, "run")) return container_cmds.run(gpa, arena, environ, sub_rest);
        if (eq(sub, "ls") or eq(sub, "ps") or eq(sub, "list")) return container_cmds.list();
        return unsupported("container", sub);
    }

    if (eq(cmd, "image")) {
        if (rest.len == 0) {
            std.debug.print("zwslc: 'image' requires a subcommand (pull/list/tag/push/rm/...)\n", .{});
            return 1;
        }
        const sub = rest[0];
        const sub_rest = rest[1..];
        if (eq(sub, "pull")) return image_cmds.pull(gpa, arena, environ, sub_rest);
        if (eq(sub, "list") or eq(sub, "ls") or eq(sub, "images")) return image_cmds.list(gpa, arena, environ, sub_rest);
        if (eq(sub, "tag")) return image_cmds.tag(gpa, arena, environ, sub_rest);
        if (eq(sub, "push")) return image_cmds.push(gpa, arena, environ, sub_rest);
        if (eq(sub, "rm") or eq(sub, "rmi") or eq(sub, "delete")) return image_cmds.remove(gpa, arena, environ, sub_rest);
        return unsupported("image", sub);
    }

    // Backed by no C API at all (see the plan's command-coverage table).
    if (eq(cmd, "build") or eq(cmd, "network") or eq(cmd, "settings")) {
        std.debug.print(
            "zwslc: '{s}' is not supported by the public WSL container SDK (no corresponding wslcsdk.h API)\n",
            .{cmd},
        );
        return 1;
    }

    printUsage();
    return 1;
}

fn unsupported(group: []const u8, sub: []const u8) u8 {
    std.debug.print("zwslc: '{s} {s}' is not implemented\n", .{ group, sub });
    return 1;
}

fn cmdVersion() !u8 {
    const v = wslc.getVersion() catch |err| {
        std.debug.print("zwslc: failed to query WSL container SDK version: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("zwslc {s} (wslcsdk {d}.{d}.{d})\n", .{ build_options.version, v.major, v.minor, v.revision });
    return 0;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zwslc <command> [args]
        \\
        \\Commands:
        \\  version                 Print the WSLC SDK version
        \\  run IMAGE [CMD...]       Create, start, and wait for a container (alias: container run)
        \\  pull IMAGE               Pull a container image (alias: image pull)
        \\  images                   List pulled images (alias: image list)
        \\  tag IMAGE REPO:TAG        Tag an image (alias: image tag)
        \\  push IMAGE                Push an image (alias: image push)
        \\  rmi IMAGE                 Remove an image (alias: image rm)
        \\  container <run|ls|ps>     Container management
        \\  image <pull|list|tag|push|rm>   Image management
        \\
    , .{});
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
