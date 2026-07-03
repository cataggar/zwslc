//! `run_container` MCP tool: blocking create->start->wait->cleanup, mirroring
//! `cli/src/container_cmds.zig`'s `run` command - like `docker run` without
//! `-d`. Unlike the CLI (stateless, so a container it doesn't auto-remove is
//! immediately orphaned - no way to reattach from a later invocation), this
//! MCP server registers non-auto-removed containers in `ctx.registry` so a
//! later `container_status`/`stop_container`/`delete_container` tool call
//! (see GitHub issue #2) can still manage them within this same server
//! session.
//!
//! Container stdout/stderr forwarding is intentionally not wired up here,
//! for the same reason noted in `cli/src/container_cmds.zig`: registering
//! *any* callback (even a bare onExit-only one) on a container's *init*
//! process currently makes `WslcStartContainer` fail with `E_INVALIDARG` on
//! this preview SDK build. A later `container_logs` tool sidesteps this by
//! using a *secondary* process via `Container.createProcess` instead - see
//! issue #2's non-goals.

const std = @import("std");
const mcp = @import("mcp");
const wslc = @import("wslc");
const context = @import("../context.zig");

const tools = mcp.tools;

pub fn register(server: *mcp.Server, ctx: *context.AppContext) !void {
    var builder = mcp.schema.InputSchemaBuilder.init(ctx.gpa);
    defer builder.deinit(ctx.gpa);
    _ = try builder.addString(ctx.gpa, "image", "Image reference to run, e.g. 'alpine:latest'.", true);
    _ = try builder.addString(ctx.gpa, "name", "Optional container name.", false);
    _ = try builder.addBoolean(ctx.gpa, "auto_remove", "Stop+delete the container after it exits (default true, like 'docker run --rm').", false);
    _ = try builder.addString(ctx.gpa, "hostname", "Optional container hostname.", false);
    _ = try builder.addString(ctx.gpa, "domainname", "Optional container domain name.", false);
    const input_schema = try builder.toInputSchema(ctx.gpa);

    try server.addTool(.{
        .name = "run_container",
        .description = "Create, start, and wait (blocking) for a container to exit - like " ++
            "'docker run' without '-d'. Extra JSON array arguments beyond the listed " ++
            "properties: 'cmd' (array of strings, argv - defaults to ['/bin/sh']), 'env' " ++
            "(array of 'KEY=VALUE' strings), 'publish' (array of 'HOSTPORT:CONTAINERPORT' " ++
            "strings), 'volumes' (array of 'HOSTPATH:CONTAINERPATH[:ro]' strings). If " ++
            "auto_remove is false, the container is kept (registered for later " ++
            "container_status/stop_container/delete_container calls) and its id is " ++
            "returned. Container stdout/stderr are not forwarded (known SDK preview " ++
            "limitation).",
        .inputSchema = input_schema,
        .handler = runContainer,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = false },
    });
}

fn runContainer(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const image = tools.getString(args, "image") orelse return tools.ToolError.InvalidArguments;
    const name = tools.getString(args, "name");
    const auto_remove = tools.getBoolean(args, "auto_remove") orelse true;
    const hostname = tools.getString(args, "hostname");
    const domainname = tools.getString(args, "domainname");

    const cmd = stringArrayArg(allocator, args, "cmd") orelse return tools.ToolError.InvalidArguments;
    const env = stringArrayArg(allocator, args, "env") orelse return tools.ToolError.InvalidArguments;
    const publish = portMappingsArg(allocator, args, "publish") orelse return tools.ToolError.InvalidArguments;
    const volumes = volumesArg(allocator, args, "volumes") orelse return tools.ToolError.InvalidArguments;

    const session = ctx.getSession(io) catch return tools.ToolError.ExecutionFailed;

    var container = session.createContainer(allocator, .{
        .image_name = image,
        .name = name,
        .init_process = .{
            .cmd_line = if (cmd.len != 0) cmd else &.{"/bin/sh"},
            .env_variables = env,
        },
        .host_name = hostname,
        .domain_name = domainname,
        .port_mappings = publish,
        .volumes = volumes,
    }) catch return tools.ToolError.ExecutionFailed;
    // Skipped (set true) once ownership transfers to `ctx.registry` below -
    // otherwise this releases the local handle on every return path,
    // mirroring `cli/src/container_cmds.zig`'s `defer container.deinit();`.
    var container_registered = false;
    defer if (!container_registered) container.deinit();

    container.start(.NONE) catch {
        container.delete(.FORCE) catch {};
        return tools.ToolError.ExecutionFailed;
    };

    var exit_code: i64 = 0;
    if (container.initProcess()) |proc| {
        exit_code = proc.waitForExit(null) catch -1;
    } else |_| {
        exit_code = -1;
    }

    var container_id: ?u64 = null;
    var auto_removed = false;
    if (auto_remove) {
        if (container.state()) |st| {
            if (st == .RUNNING) container.stop(.SIGTERM, 10) catch {};
        } else |_| {}
        container.delete(.NONE) catch {};
        auto_removed = true;
    } else if (ctx.registry.register(io, container, name, image, auto_remove)) |id| {
        container_registered = true;
        container_id = id;
    } else |_| {
        // Registration failed (e.g. OOM): the container itself is left
        // running, untracked - a rare orphan case (see Registry.deinit's
        // doc comment for the analogous crash caveat).
    }

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "exit_code", .{ .integer = exit_code }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "auto_removed", .{ .bool = auto_removed }) catch return tools.ToolError.OutOfMemory;
    if (container_id) |id| {
        obj.put(allocator, "container_id", .{ .integer = @intCast(id) }) catch return tools.ToolError.OutOfMemory;
    }
    return tools.structuredResult(allocator, .{ .object = obj }) catch tools.ToolError.OutOfMemory;
}

/// Extracts a JSON array-of-strings argument. Returns an empty slice if the
/// key is absent, or `null` if present but malformed (not an array of
/// strings) - callers should treat `null` as `ToolError.InvalidArguments`.
fn stringArrayArg(allocator: std.mem.Allocator, args: ?std.json.Value, key: []const u8) ?[]const []const u8 {
    const arr = tools.getArray(args, key) orelse return &.{};
    const out = allocator.alloc([]const u8, arr.items.len) catch return null;
    for (arr.items, 0..) |item, i| {
        if (item != .string) return null;
        out[i] = item.string;
    }
    return out;
}

fn portMappingsArg(allocator: std.mem.Allocator, args: ?std.json.Value, key: []const u8) ?[]const wslc.PortMapping {
    const arr = tools.getArray(args, key) orelse return &.{};
    const out = allocator.alloc(wslc.PortMapping, arr.items.len) catch return null;
    for (arr.items, 0..) |item, i| {
        if (item != .string) return null;
        out[i] = parsePortMapping(item.string) orelse return null;
    }
    return out;
}

fn volumesArg(allocator: std.mem.Allocator, args: ?std.json.Value, key: []const u8) ?[]const wslc.Volume {
    const arr = tools.getArray(args, key) orelse return &.{};
    const out = allocator.alloc(wslc.Volume, arr.items.len) catch return null;
    for (arr.items, 0..) |item, i| {
        if (item != .string) return null;
        out[i] = parseVolume(item.string) orelse return null;
    }
    return out;
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
