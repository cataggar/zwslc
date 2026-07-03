//! `get_version`/`get_missing_components` MCP tools: thin structured-JSON
//! wrappers around `wslc.getVersion()`/`wslc.getMissingComponents()`.
//! Neither needs a session (mirrors the `zwslc version` CLI command), so
//! neither tool needs `Tool.user_data`.

const std = @import("std");
const mcp = @import("mcp");
const wslc = @import("wslc");

const tools = mcp.tools;

pub fn register(server: *mcp.Server) !void {
    try server.addTool(.{
        .name = "get_version",
        .description = "Get the installed WSL container SDK (wslcsdk) version.",
        .handler = getVersion,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
    });
    try server.addTool(.{
        .name = "get_missing_components",
        .description = "List WSL components required by the container SDK that are not yet installed on this machine (e.g. the Virtual Machine Platform feature, or the WSL package itself).",
        .handler = getMissingComponents,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
    });
}

fn getVersion(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const v = wslc.getVersion() catch return tools.ToolError.ExecutionFailed;

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "major", .{ .integer = @intCast(v.major) }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "minor", .{ .integer = @intCast(v.minor) }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "revision", .{ .integer = @intCast(v.revision) }) catch return tools.ToolError.OutOfMemory;
    return tools.structuredResult(allocator, .{ .object = obj }) catch tools.ToolError.OutOfMemory;
}

fn getMissingComponents(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const flags = wslc.getMissingComponents() catch return tools.ToolError.ExecutionFailed;

    var missing: std.json.Array = .init(allocator);
    if (flags.has(.VIRTUAL_MACHINE_PLATFORM)) {
        missing.append(.{ .string = "VIRTUAL_MACHINE_PLATFORM" }) catch return tools.ToolError.OutOfMemory;
    }
    if (flags.has(.WSL_PACKAGE)) {
        missing.append(.{ .string = "WSL_PACKAGE" }) catch return tools.ToolError.OutOfMemory;
    }

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "missing", .{ .array = missing }) catch return tools.ToolError.OutOfMemory;
    obj.put(allocator, "sdk_needs_update", .{ .bool = flags.has(.SDK_NEEDS_UPDATE) }) catch return tools.ToolError.OutOfMemory;
    return tools.structuredResult(allocator, .{ .object = obj }) catch tools.ToolError.OutOfMemory;
}
