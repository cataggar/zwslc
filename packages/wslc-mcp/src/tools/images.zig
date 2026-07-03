//! `list_images`/`pull_image`/`tag_image`/`push_image`/`delete_image` MCP
//! tools: wrap the same session image APIs `cli/src/image_cmds.zig` uses,
//! but return structured JSON instead of CLI-formatted text, and take named
//! JSON arguments instead of positional CLI args.

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

    try server.addTool(.{
        .name = "pull_image",
        .description = "Pull a container image into this machine's WSL container image store.",
        .inputSchema = try objectSchema(ctx.gpa, &.{
            .{ .name = "image", .desc = "Image reference to pull, e.g. 'alpine:latest'.", .required = true },
        }),
        .handler = pullImage,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = true },
    });

    try server.addTool(.{
        .name = "tag_image",
        .description = "Tag an existing image with a new repo:tag name.",
        .inputSchema = try objectSchema(ctx.gpa, &.{
            .{ .name = "image", .desc = "Source image name or ID.", .required = true },
            .{ .name = "repo", .desc = "Target repository name.", .required = true },
            .{ .name = "tag", .desc = "Target tag name.", .required = true },
        }),
        .handler = tagImage,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = true },
    });

    try server.addTool(.{
        .name = "push_image",
        .description = "Push an image to its registry.",
        .inputSchema = try objectSchema(ctx.gpa, &.{
            .{ .name = "image", .desc = "Image reference to push.", .required = true },
            .{ .name = "registry_auth", .desc = "Optional base64-encoded X-Registry-Auth header value.", .required = false },
        }),
        .handler = pushImage,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = true },
    });

    try server.addTool(.{
        .name = "delete_image",
        .description = "Delete an image from this machine's WSL container image store.",
        .inputSchema = try objectSchema(ctx.gpa, &.{
            .{ .name = "image", .desc = "Image name or ID to delete.", .required = true },
        }),
        .handler = deleteImage,
        .user_data = ctx,
        .annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = true },
    });
}

const StringField = struct { name: []const u8, desc: []const u8, required: bool };

/// Builds a `{ "type": "object", "properties": {...}, "required": [...] }`
/// input schema out of plain string fields. The schema outlives `builder`
/// (its contents are copied into freshly-allocated JSON values, not
/// borrowed from the builder's own bookkeeping - see
/// `InputSchemaBuilder.toInputSchema`), so `builder.deinit()` right after is
/// safe. Built once at tool-registration time with the server's long-lived
/// `gpa` and never freed, same as the `Tool`/schema data it becomes part of.
fn objectSchema(gpa: std.mem.Allocator, fields: []const StringField) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(gpa);
    defer builder.deinit(gpa);
    for (fields) |f| {
        _ = try builder.addString(gpa, f.name, f.desc, f.required);
    }
    return try builder.toInputSchema(gpa);
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

fn pullImage(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const image = tools.getString(args, "image") orelse return tools.ToolError.InvalidArguments;
    const session = ctx.getSession(io) catch return tools.ToolError.ExecutionFailed;

    session.pullImage(image, .{}, allocator) catch return tools.ToolError.ExecutionFailed;
    return tools.textResult(allocator, image) catch tools.ToolError.OutOfMemory;
}

fn tagImage(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const image = tools.getString(args, "image") orelse return tools.ToolError.InvalidArguments;
    const repo = tools.getString(args, "repo") orelse return tools.ToolError.InvalidArguments;
    const tag_name = tools.getString(args, "tag") orelse return tools.ToolError.InvalidArguments;
    const session = ctx.getSession(io) catch return tools.ToolError.ExecutionFailed;

    const image_z = allocator.dupeZ(u8, image) catch return tools.ToolError.OutOfMemory;
    defer allocator.free(image_z);
    const repo_z = allocator.dupeZ(u8, repo) catch return tools.ToolError.OutOfMemory;
    defer allocator.free(repo_z);
    const tag_z = allocator.dupeZ(u8, tag_name) catch return tools.ToolError.OutOfMemory;
    defer allocator.free(tag_z);

    const options: wslc.sys.WslcTagImageOptions = .{ .image = image_z.ptr, .repo = repo_z.ptr, .tag = tag_z.ptr };
    var err_msg: wslc.sys.PWSTR = null;
    const hr = wslc.sys.WslcTagSessionImage(session.handle, &options, &err_msg);
    wslc.sys.freeTaskMem(err_msg);
    wslc.sys.ok(hr) catch return tools.ToolError.ExecutionFailed;

    return tools.textResult(allocator, "ok") catch tools.ToolError.OutOfMemory;
}

fn pushImage(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const image = tools.getString(args, "image") orelse return tools.ToolError.InvalidArguments;
    const registry_auth = tools.getString(args, "registry_auth") orelse "";
    const session = ctx.getSession(io) catch return tools.ToolError.ExecutionFailed;

    const image_z = allocator.dupeZ(u8, image) catch return tools.ToolError.OutOfMemory;
    defer allocator.free(image_z);
    const auth_z = allocator.dupeZ(u8, registry_auth) catch return tools.ToolError.OutOfMemory;
    defer allocator.free(auth_z);

    const options: wslc.sys.WslcPushImageOptions = .{ .image = image_z.ptr, .registryAuth = auth_z.ptr };
    var err_msg: wslc.sys.PWSTR = null;
    const hr = wslc.sys.WslcPushSessionImage(session.handle, &options, &err_msg);
    wslc.sys.freeTaskMem(err_msg);
    wslc.sys.ok(hr) catch return tools.ToolError.ExecutionFailed;

    return tools.textResult(allocator, "ok") catch tools.ToolError.OutOfMemory;
}

fn deleteImage(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) tools.ToolError!tools.ToolResult {
    const ctx: *context.AppContext = @ptrCast(@alignCast(user_data.?));
    const image = tools.getString(args, "image") orelse return tools.ToolError.InvalidArguments;
    const session = ctx.getSession(io) catch return tools.ToolError.ExecutionFailed;

    session.deleteImage(image, allocator) catch return tools.ToolError.ExecutionFailed;
    return tools.textResult(allocator, image) catch tools.ToolError.OutOfMemory;
}

