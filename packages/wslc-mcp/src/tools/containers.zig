//! `run_container`/`create_container`/`start_container`/`container_status`/
//! `stop_container`/`delete_container` MCP tools.
//!
//! `run_container` is a blocking create->start->wait->cleanup, mirroring
//! `cli/src/container_cmds.zig`'s `run` command - like `docker run` without
//! `-d`. The other five are the detached lifecycle: `create_container`
//! registers (but doesn't start) a container in `ctx.registry`, returning a
//! `container_id` that `start_container`/`container_status`/
//! `stop_container`/`delete_container` (and `run_container`, for containers
//! it keeps rather than auto-removes) can use in later, independent tool
//! calls within this same server session - the CLI can't do this at all
//! (see GitHub issue #2's "why this is more than expose the CLI as tools"
//! rationale).
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

    var create_builder = mcp.schema.InputSchemaBuilder.init(ctx.gpa);
    defer create_builder.deinit(ctx.gpa);
    _ = try create_builder.addString(ctx.gpa, "image", "Image reference to run, e.g. 'alpine:latest'.", true);
    _ = try create_builder.addString(ctx.gpa, "name", "Optional container name.", false);
    _ = try create_builder.addBoolean(ctx.gpa, "auto_remove", "Best-effort stop+delete this container if it's still registered when the server exits (default false - detached containers are normally cleaned up explicitly via delete_container).", false);
    _ = try create_builder.addString(ctx.gpa, "hostname", "Optional container hostname.", false);
    _ = try create_builder.addString(ctx.gpa, "domainname", "Optional container domain name.", false);
    const create_schema = try create_builder.toInputSchema(ctx.gpa);

    try server.addTool(.{
        .name = "create_container",
        .description = "Create (but do not start) a detached container, registered for later " ++
            "start_container/container_status/stop_container/delete_container calls in " ++
            "this server session. Extra JSON array arguments beyond the listed " ++
            "properties: 'cmd' (array of strings, argv - defaults to ['/bin/sh']), 'env' " ++
            "(array of 'KEY=VALUE' strings), 'publish' (array of 'HOSTPORT:CONTAINERPORT' " ++
            "strings), 'volumes' (array of 'HOSTPATH:CONTAINERPATH[:ro]' strings). Returns " ++
            "a container_id to pass to the other container tools.",
        .inputSchema = create_schema,
        .handler = createContainer,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = false },
    });

    try server.addTool(.{
        .name = "start_container",
        .description = "Start a container previously created via create_container.",
        .inputSchema = try containerIdSchema(ctx.gpa),
        .handler = startContainer,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = false },
    });

    try server.addTool(.{
        .name = "container_status",
        .description = "Get the current state (CREATED/RUNNING/EXITED/...), name, image, " ++
            "and creation time of a container tracked by this server session.",
        .inputSchema = try containerIdSchema(ctx.gpa),
        .handler = containerStatus,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
    });

    var stop_builder = mcp.schema.InputSchemaBuilder.init(ctx.gpa);
    defer stop_builder.deinit(ctx.gpa);
    _ = try stop_builder.addInteger(ctx.gpa, "container_id", "id returned by create_container/run_container.", true);
    _ = try stop_builder.addEnum(ctx.gpa, "signal", "Signal to send (default SIGTERM).", &.{ "SIGTERM", "SIGKILL", "SIGINT", "SIGHUP", "SIGQUIT" }, false);
    _ = try stop_builder.addInteger(ctx.gpa, "timeout_seconds", "Seconds to wait before forcefully killing (default 10).", false);
    const stop_schema = try stop_builder.toInputSchema(ctx.gpa);

    try server.addTool(.{
        .name = "stop_container",
        .description = "Stop a running container tracked by this server session.",
        .inputSchema = stop_schema,
        .handler = stopContainer,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = true },
    });

    var delete_builder = mcp.schema.InputSchemaBuilder.init(ctx.gpa);
    defer delete_builder.deinit(ctx.gpa);
    _ = try delete_builder.addInteger(ctx.gpa, "container_id", "id returned by create_container/run_container.", true);
    _ = try delete_builder.addBoolean(ctx.gpa, "force", "Force-delete even if still running (default false).", false);
    const delete_schema = try delete_builder.toInputSchema(ctx.gpa);

    try server.addTool(.{
        .name = "delete_container",
        .description = "Delete a container tracked by this server session, removing it from the registry.",
        .inputSchema = delete_schema,
        .handler = deleteContainer,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = true },
    });
}

fn containerIdSchema(gpa: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(gpa);
    defer builder.deinit(gpa);
    _ = try builder.addInteger(gpa, "container_id", "id returned by create_container/run_container.", true);
    return try builder.toInputSchema(gpa);
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

fn createContainer(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const image = tools.getString(args, "image") orelse return tools.ToolError.InvalidArguments;
    const name = tools.getString(args, "name");
    const auto_remove = tools.getBoolean(args, "auto_remove") orelse false;
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

    const id = ctx.registry.register(io, container, name, image, auto_remove) catch {
        container.deinit();
        return tools.ToolError.ExecutionFailed;
    };

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "container_id", .{ .integer = @intCast(id) }) catch return tools.ToolError.OutOfMemory;
    return tools.structuredResult(allocator, .{ .object = obj }) catch tools.ToolError.OutOfMemory;
}

/// Extracts the required `container_id` argument. Returns `null` if absent
/// or negative - callers should treat that as `ToolError.InvalidArguments`.
fn getContainerId(args: ?std.json.Value) ?u64 {
    const raw = tools.getInteger(args, "container_id") orelse return null;
    if (raw < 0) return null;
    return @intCast(raw);
}

fn startContainer(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const id = getContainerId(args) orelse return tools.ToolError.InvalidArguments;

    ctx.registry.lock(io);
    defer ctx.registry.unlock(io);
    const entry = ctx.registry.getAssumeLocked(id) orelse return tools.ToolError.ResourceNotFound;
    entry.container.start(.NONE) catch return tools.ToolError.ExecutionFailed;

    return tools.textResult(allocator, "started") catch tools.ToolError.OutOfMemory;
}

fn containerStatus(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const id = getContainerId(args) orelse return tools.ToolError.InvalidArguments;

    ctx.registry.lock(io);
    defer ctx.registry.unlock(io);
    const entry = ctx.registry.getAssumeLocked(id) orelse return tools.ToolError.ResourceNotFound;
    const state = entry.container.state() catch return tools.ToolError.ExecutionFailed;

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "container_id", .{ .integer = @intCast(id) }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "state", .{ .string = @tagName(state) }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "image", .{ .string = entry.image }) catch return tools.ToolError.OutOfMemory;
    if (entry.name) |n| obj.put(allocator, "name", .{ .string = n }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "auto_remove", .{ .bool = entry.auto_remove }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "created_at_ms", .{ .integer = entry.created_at_ms }) catch return tools.ToolError.OutOfMemory;
    return tools.structuredResult(allocator, .{ .object = obj }) catch tools.ToolError.OutOfMemory;
}

fn stopContainer(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const id = getContainerId(args) orelse return tools.ToolError.InvalidArguments;
    const sig: wslc.sys.WslcSignal = if (tools.getString(args, "signal")) |s|
        (parseSignal(s) orelse return tools.ToolError.InvalidArguments)
    else
        .SIGTERM;
    const raw_timeout = tools.getInteger(args, "timeout_seconds") orelse 10;
    if (raw_timeout < 0) return tools.ToolError.InvalidArguments;
    const timeout_seconds: u32 = @intCast(raw_timeout);

    ctx.registry.lock(io);
    defer ctx.registry.unlock(io);
    const entry = ctx.registry.getAssumeLocked(id) orelse return tools.ToolError.ResourceNotFound;
    entry.container.stop(sig, timeout_seconds) catch return tools.ToolError.ExecutionFailed;

    return tools.textResult(allocator, "stopped") catch tools.ToolError.OutOfMemory;
}

fn deleteContainer(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const id = getContainerId(args) orelse return tools.ToolError.InvalidArguments;
    const force = tools.getBoolean(args, "force") orelse false;

    var entry = ctx.registry.remove(io, id) orelse return tools.ToolError.ResourceNotFound;
    // Best-effort: even if the SDK delete call fails, still release our
    // local handle/bookkeeping below - the registry no longer tracks this
    // id either way, so there's nothing left for a later tool call to act
    // on.
    entry.container.delete(if (force) .FORCE else .NONE) catch {};
    entry.container.deinit();
    ctx.registry.allocator.free(entry.image);
    if (entry.name) |n| ctx.registry.allocator.free(n);

    return tools.textResult(allocator, "deleted") catch tools.ToolError.OutOfMemory;
}

fn parseSignal(s: []const u8) ?wslc.sys.WslcSignal {
    if (std.mem.eql(u8, s, "SIGTERM")) return .SIGTERM;
    if (std.mem.eql(u8, s, "SIGKILL")) return .SIGKILL;
    if (std.mem.eql(u8, s, "SIGINT")) return .SIGINT;
    if (std.mem.eql(u8, s, "SIGHUP")) return .SIGHUP;
    if (std.mem.eql(u8, s, "SIGQUIT")) return .SIGQUIT;
    return null;
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
