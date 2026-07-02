//! `zwslc container run`/`container ls` command implementations.
//!
//! `run` is a synchronous, foreground create->start->wait->cleanup flow
//! (like `docker run` without `-d`): the SDK gives us no way to detach and
//! later reattach/stop/rm a container created by a *different* process
//! invocation (no "list all containers"/"reopen by ID" API), so that's the
//! only faithful shape available without reimplementing a background
//! session-tracking daemon (explicitly out of scope for this project).

const std = @import("std");
const wslc = @import("wslc");
const main = @import("main.zig");

// NOTE: stdout/stderr forwarding for the running container's init process
// (via `wslc.stdioCallback`'s comptime trampoline generator - see
// packages/wslc/src/process.zig, already exercised by its own unit tests) is
// not wired in here yet: registering *any* callback (even a bare
// onExit-only one) on a container's init process currently makes
// WslcStartContainer fail with E_INVALIDARG on this preview build of the
// SDK, with no error message text to diagnose further. Root cause not yet
// isolated - possibly specific to init processes vs. secondary ones created
// via Container.createProcess. Left as a follow-up; container output is not
// forwarded to the console for now.

const RunOptions = struct {
    name: ?[]const u8 = null,
    auto_remove: bool = true, // --rm defaults to true here (unlike Docker) since we can't list/clean up later anyway
    cpu_count: ?u32 = null,
    memory_mb: ?u32 = null,
    hostname: ?[]const u8 = null,
    domainname: ?[]const u8 = null,
    env: std.array_list.Managed([]const u8),
    publish: std.array_list.Managed(wslc.PortMapping),
    volumes: std.array_list.Managed(wslc.Volume),
    image: ?[]const u8 = null,
    cmd: []const []const u8 = &.{},
};

pub fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    var opts = RunOptions{
        .env = std.array_list.Managed([]const u8).init(arena),
        .publish = std.array_list.Managed(wslc.PortMapping).init(arena),
        .volumes = std.array_list.Managed(wslc.Volume).init(arena),
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--name") and i + 1 < args.len) {
            i += 1;
            opts.name = args[i];
        } else if (eq(a, "--rm")) {
            opts.auto_remove = true;
        } else if (eq(a, "--cpus") and i + 1 < args.len) {
            i += 1;
            opts.cpu_count = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (eq(a, "--memory") or eq(a, "-m")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.memory_mb = parseMemoryMb(args[i]);
            }
        } else if ((eq(a, "--env") or eq(a, "-e")) and i + 1 < args.len) {
            i += 1;
            opts.env.append(args[i]) catch return error.OutOfMemory;
        } else if (eq(a, "--hostname") or eq(a, "-h")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.hostname = args[i];
            }
        } else if (eq(a, "--domainname") and i + 1 < args.len) {
            i += 1;
            opts.domainname = args[i];
        } else if ((eq(a, "--publish") or eq(a, "-p")) and i + 1 < args.len) {
            i += 1;
            const pm = parsePortMapping(args[i]) orelse {
                std.debug.print("zwslc: invalid --publish value '{s}' (expected HOSTPORT:CONTAINERPORT)\n", .{args[i]});
                return 1;
            };
            opts.publish.append(pm) catch return error.OutOfMemory;
        } else if ((eq(a, "--volume") or eq(a, "-v")) and i + 1 < args.len) {
            i += 1;
            const vol = parseVolume(args[i]) orelse {
                std.debug.print("zwslc: invalid --volume value '{s}' (expected HOSTPATH:CONTAINERPATH[:ro])\n", .{args[i]});
                return 1;
            };
            opts.volumes.append(vol) catch return error.OutOfMemory;
        } else if (eq(a, "--detach") or eq(a, "-d") or eq(a, "--interactive") or eq(a, "-i") or eq(a, "--tty") or eq(a, "-t")) {
            // Accepted for CLI-shape parity but a no-op: this CLI always runs
            // in the foreground and doesn't wire up a real interactive TTY.
        } else if (opts.image == null) {
            opts.image = a;
        } else {
            opts.cmd = args[i..];
            break;
        }
    }

    const image = opts.image orelse {
        std.debug.print("usage: zwslc run [flags] IMAGE [COMMAND [ARGS...]]\n", .{});
        return 1;
    };

    var session = main.defaultSession(gpa, arena, environ) catch return 1;
    defer session.deinit();

    if (opts.cpu_count) |c| {
        // Best-effort: CPU/memory are session-level in the SDK, not
        // container-level, and only take effect on the session's first VM
        // boot for a given storage path — a no-op if a VM is already
        // running from a previous invocation against the same storage.
        _ = c;
    }
    _ = opts.memory_mb;

    // NOTE: registering stdio/exit callbacks on a container's *init process*
    // (via ProcessSettings.callbacks) currently makes WslcStartContainer
    // fail with E_INVALIDARG (no error message text) on this build of the
    // SDK, even with a bare onExit-only callback and no lifetime issues
    // (verified: the same callbacks work fine as pure trampolines in
    // packages/wslc/src/process.zig's unit tests). Root cause not yet
    // isolated - possibly a preview-SDK constraint specific to init
    // processes vs. secondary ones created via Container.createProcess.
    // Left disabled here (container output is not forwarded to the console)
    // pending further investigation; see docs/comptime-design.md.
    var init_process: wslc.ProcessSettings = .{
        .cmd_line = if (opts.cmd.len != 0) opts.cmd else &.{"/bin/sh"},
        .env_variables = opts.env.items,
    };

    var container = session.createContainer(gpa, .{
        .image_name = image,
        .name = opts.name,
        .init_process = init_process,
        .host_name = opts.hostname,
        .domain_name = opts.domainname,
        .port_mappings = opts.publish.items,
        .volumes = opts.volumes.items,
    }) catch |err| {
        std.debug.print("zwslc: container creation failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer container.deinit();
    _ = &init_process;

    container.start(.NONE) catch |err| {
        std.debug.print("zwslc: start failed: {s}\n", .{@errorName(err)});
        container.delete(.FORCE) catch {};
        return 1;
    };

    var exit_code: u8 = 0;
    if (container.initProcess()) |proc| {
        const code = proc.waitForExit(null) catch -1;
        exit_code = if (code >= 0 and code < 256) @intCast(code) else 1;
    } else |err| {
        std.debug.print("zwslc: failed to get init process: {s}\n", .{@errorName(err)});
        exit_code = 1;
    }

    if (opts.auto_remove) {
        if (container.state()) |state| {
            if (state == .RUNNING) container.stop(.SIGTERM, 10) catch {};
        } else |_| {}
        container.delete(.NONE) catch |err| {
            std.debug.print("zwslc: cleanup delete failed: {s}\n", .{@errorName(err)});
        };
    }

    return exit_code;
}

pub fn list() !u8 {
    std.debug.print(
        "zwslc: container list/ps is only meaningful within a single 'zwslc run' invocation - " ++
            "the WSL container SDK has no API to enumerate or reopen containers created by a previous process.\n",
        .{},
    );
    return 0;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseMemoryMb(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    const last = s[s.len - 1];
    const multiplier: u32, const digits = switch (last) {
        'g', 'G' => .{ 1024, s[0 .. s.len - 1] },
        'm', 'M' => .{ 1, s[0 .. s.len - 1] },
        else => .{ 1, s },
    };
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    return n * multiplier;
}

fn parsePortMapping(s: []const u8) ?wslc.PortMapping {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const host_port = std.fmt.parseInt(u16, s[0..colon], 10) catch return null;
    const container_port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
    return .{ .windows_port = host_port, .container_port = container_port };
}

fn parseVolume(s: []const u8) ?wslc.Volume {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    var container_path = s[colon + 1 ..];
    var read_only = false;
    if (std.mem.endsWith(u8, container_path, ":ro")) {
        read_only = true;
        container_path = container_path[0 .. container_path.len - 3];
    }
    return .{ .windows_path = s[0..colon], .container_path = container_path, .read_only = read_only };
}
