//! `list_images` MCP tool: wraps `session.listImages()`, returning JSON
//! (not the CLI's formatted table) with the full sha256 as hex - unlike the
//! CLI's truncated 4-byte preview in `cli/src/image_cmds.zig`.

const std = @import("std");
const mcp = @import("mcp");
const wslc = @import("wslc");
const context = @import("../context.zig");

const tools = mcp.tools;

pub fn register(server: *mcp.Server, ctx: *context.AppContext) !void {
    try server.addTool(.{
        .name = "list_images",
        .description = "List container images pulled into this machine's WSL container image store.",
        .handler = listImages,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true },
    });
}

fn listImages(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const session = ctx.getSession(io) catch return tools.ToolError.ExecutionFailed;

    const images = session.listImages(allocator) catch return tools.ToolError.ExecutionFailed;
    defer allocator.free(images);

    var arr: std.json.Array = .init(allocator);
    for (images) |img| {
        const name_len = std.mem.indexOfScalar(u8, &img.name, 0) orelse img.name.len;
        const name_copy = allocator.dupe(u8, img.name[0..name_len]) catch return tools.ToolError.OutOfMemory;
        const sha256_hex = allocator.dupe(u8, &std.fmt.bytesToHex(img.sha256, .lower)) catch return tools.ToolError.OutOfMemory;

        var obj: std.json.ObjectMap = .empty;
        obj.put(allocator, "name", .{ .string = name_copy }) catch return tools.ToolError.OutOfMemory;
        obj.put(allocator, "size_bytes", .{ .integer = img.sizeBytes }) catch return tools.ToolError.OutOfMemory;
        obj.put(allocator, "sha256", .{ .string = sha256_hex }) catch return tools.ToolError.OutOfMemory;
        obj.put(allocator, "created_unix_time", .{ .integer = @intCast(img.createdUnixTime) }) catch return tools.ToolError.OutOfMemory;
        arr.append(.{ .object = obj }) catch return tools.ToolError.OutOfMemory;
    }

    return tools.structuredResult(allocator, .{ .array = arr }) catch tools.ToolError.OutOfMemory;
}
