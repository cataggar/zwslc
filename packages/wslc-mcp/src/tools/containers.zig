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

    var exec_builder = mcp.schema.InputSchemaBuilder.init(ctx.gpa);
    defer exec_builder.deinit(ctx.gpa);
    _ = try exec_builder.addInteger(ctx.gpa, "container_id", "id returned by create_container/run_container. The container must already be RUNNING.", true);
    _ = try exec_builder.addString(ctx.gpa, "working_directory", "Optional working directory for the new process.", false);
    const exec_schema = try exec_builder.toInputSchema(ctx.gpa);

    try server.addTool(.{
        .name = "exec_in_container",
        .description = "Run a command (blocking) as a new secondary process inside an already-" ++
            "running container, and return its exit_code/stdout/stderr. Extra JSON array " ++
            "arguments beyond the listed properties: 'cmd' (required array of strings, " ++
            "argv), 'env' (array of 'KEY=VALUE' strings). The transcript is also appended " ++
            "to the container's accumulated log, retrievable later via container_logs. " ++
            "This is real code-execution capability inside the container - treat it with " ++
            "the same care as run_container.",
        .inputSchema = exec_schema,
        .handler = execInContainer,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = false },
    });

    try server.addTool(.{
        .name = "container_logs",
        .description = "Get the accumulated stdout/stderr transcript from all exec_in_container " ++
            "calls made against a container in this server session. Does not include the " ++
            "container's own init-process output (not forwarded - see run_container's " ++
            "description).",
        .inputSchema = try containerIdSchema(ctx.gpa),
        .handler = containerLogs,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
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
    entry.log.deinit(ctx.registry.allocator);

    return tools.textResult(allocator, "deleted") catch tools.ToolError.OutOfMemory;
}

fn execInContainer(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const id = getContainerId(args) orelse return tools.ToolError.InvalidArguments;
    const cmd = stringArrayArg(allocator, args, "cmd") orelse return tools.ToolError.InvalidArguments;
    if (cmd.len == 0) return tools.ToolError.InvalidArguments;
    const env = stringArrayArg(allocator, args, "env") orelse return tools.ToolError.InvalidArguments;
    const working_directory = tools.getString(args, "working_directory");

    // Look up (and copy - `wslc.Container` is just a handle + optional
    // arena pointer) the container without holding the registry lock for
    // the whole (possibly slow) blocking exec below; only the lookup
    // itself needs the lock.
    const container = blk: {
        ctx.registry.lock(io);
        defer ctx.registry.unlock(io);
        const entry = ctx.registry.getAssumeLocked(id) orelse return tools.ToolError.ResourceNotFound;
        break :blk entry.container;
    };

    // A manual-reset Win32 event, set by `ExecCtx.onExit` below. Waiting on
    // *this* (rather than `proc.waitForExit()`, which waits on the SDK's
    // own exit *event* and can observe it before all stdio callbacks have
    // fired) is required for correctness: `WslcProcessExitCallback`'s doc
    // comment guarantees it only fires "when a process has exited AND any
    // remaining IO has been flushed" - only that guarantee makes it safe to
    // read `exec_ctx.stdout`/`stderr` below as complete.
    const exited_event = CreateEventW(null, 1, 0, null) orelse return tools.ToolError.ExecutionFailed;
    defer _ = CloseHandle(exited_event);

    // `exec_ctx` is stack-local and outlives every point where WSLC could
    // invoke its callbacks (from `createProcess` through the
    // `WaitForSingleObject` below returning, all within this same
    // synchronous call) - see this file's module doc comment for why a
    // *secondary* process (unlike the container's init process) can safely
    // use callbacks here.
    var exec_ctx = ExecCtx{ .allocator = allocator, .exited = exited_event };
    defer exec_ctx.stdout.deinit(allocator);
    defer exec_ctx.stderr.deinit(allocator);
    const on_stdio = wslc.stdioCallback(ExecCtx, ExecCtx.onData);
    const on_exit = wslc.exitCallback(ExecCtx, ExecCtx.onExit);

    var proc = container.createProcess(allocator, .{
        .working_directory = working_directory,
        .cmd_line = cmd,
        .env_variables = env,
        .callbacks = .{ .onStdOut = on_stdio, .onStdErr = on_stdio, .onExit = on_exit },
        .callbacks_context = &exec_ctx,
    }) catch return tools.ToolError.ExecutionFailed;
    defer proc.deinit();

    _ = WaitForSingleObject(exited_event, INFINITE);
    const exit_code: i64 = exec_ctx.exit_code;

    // Append this exec's transcript to the container's accumulated log
    // (see container_logs) before exec_ctx's buffers are freed below.
    if (exec_ctx.stdout.items.len != 0) {
        if (std.fmt.allocPrint(allocator, "[stdout] {s}\n", .{exec_ctx.stdout.items})) |tagged| {
            defer allocator.free(tagged);
            ctx.registry.appendLog(io, id, tagged);
        } else |_| {}
    }
    if (exec_ctx.stderr.items.len != 0) {
        if (std.fmt.allocPrint(allocator, "[stderr] {s}\n", .{exec_ctx.stderr.items})) |tagged| {
            defer allocator.free(tagged);
            ctx.registry.appendLog(io, id, tagged);
        } else |_| {}
    }

    // Independent copies (not slices into `exec_ctx`'s buffers, which the
    // `defer`s above free as this function returns).
    const stdout_copy = allocator.dupe(u8, exec_ctx.stdout.items) catch return tools.ToolError.OutOfMemory;
    const stderr_copy = allocator.dupe(u8, exec_ctx.stderr.items) catch return tools.ToolError.OutOfMemory;

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "exit_code", .{ .integer = exit_code }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "stdout", .{ .string = stdout_copy }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "stderr", .{ .string = stderr_copy }) catch return tools.ToolError.OutOfMemory;
    return tools.structuredResult(allocator, .{ .object = obj }) catch tools.ToolError.OutOfMemory;
}

fn containerLogs(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const id = getContainerId(args) orelse return tools.ToolError.InvalidArguments;

    ctx.registry.lock(io);
    defer ctx.registry.unlock(io);
    const entry = ctx.registry.getAssumeLocked(id) orelse return tools.ToolError.ResourceNotFound;
    // `textResult` dupes `entry.log.items` into `allocator` before we
    // unlock, so the returned text is independent of the registry's buffer.
    return tools.textResult(allocator, entry.log.items) catch tools.ToolError.OutOfMemory;
}

/// Accumulates stdout/stderr from a single `exec_in_container` call, and
/// signals `exited` (a Win32 event, set by `onExit`) once WSLC guarantees
/// all IO has been flushed - see `execInContainer`'s comment on why this
/// (not `Process.waitForExit`) is what's actually safe to wait on here.
/// Passed as the `WslcProcessCallbacks` context for a *secondary* process
/// (via `Container.createProcess`) - unlike the container's init process,
/// this doesn't hit the `E_INVALIDARG` bug noted in this file's module doc
/// comment.
const ExecCtx = struct {
    allocator: std.mem.Allocator,
    exited: wslc.sys.HANDLE,
    exit_code: i32 = -1,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,

    fn onData(self: *ExecCtx, io_handle: wslc.sys.WslcProcessIOHandle, data: []const u8) void {
        const buf = switch (io_handle) {
            .STDOUT => &self.stdout,
            .STDERR => &self.stderr,
            else => return,
        };
        buf.appendSlice(self.allocator, data) catch {};
    }

    fn onExit(self: *ExecCtx, exit_code: i32) void {
        self.exit_code = exit_code;
        _ = SetEvent(self.exited);
    }
};

const INFINITE: u32 = 0xFFFFFFFF;
extern "kernel32" fn CreateEventW(event_attrs: ?*anyopaque, manual_reset: i32, initial_state: i32, name: ?[*:0]const u16) callconv(.winapi) wslc.sys.HANDLE;
extern "kernel32" fn SetEvent(handle: wslc.sys.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: wslc.sys.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(handle: wslc.sys.HANDLE, milliseconds: u32) callconv(.winapi) u32;

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
