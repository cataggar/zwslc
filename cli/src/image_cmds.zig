//! `zwslc image ...` command implementations.

const std = @import("std");
const wslc = @import("wslc");
const main = @import("main.zig");

pub fn pull(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    if (args.len == 0) {
        std.debug.print("usage: zwslc pull IMAGE\n", .{});
        return 1;
    }
    const image = args[0];

    var session = main.defaultSession(gpa, arena, environ) catch return 1;
    defer session.deinit();

    session.pullImage(image, .{}, gpa) catch |err| {
        std.debug.print("zwslc: pull failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("{s}\n", .{image});
    return 0;
}

pub fn list(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    _ = args;
    var session = main.defaultSession(gpa, arena, environ) catch return 1;
    defer session.deinit();

    const images = session.listImages(gpa) catch |err| {
        std.debug.print("zwslc: failed to list images: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(images);

    std.debug.print("{s: <40} {s: <12} {s: <10}\n", .{ "NAME", "SIZE", "SHA256" });
    for (images) |img| {
        const name_len = std.mem.indexOfScalar(u8, &img.name, 0) orelse img.name.len;
        const size: u64 = @intCast(@max(0, img.sizeBytes));
        std.debug.print("{s: <40} {d: <12} {x}{x}{x}{x}...\n", .{
            img.name[0..name_len],
            size,
            img.sha256[0],
            img.sha256[1],
            img.sha256[2],
            img.sha256[3],
        });
    }
    return 0;
}

pub fn tag(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: zwslc tag IMAGE REPO:TAG\n", .{});
        return 1;
    }
    const image = args[0];
    const repo_tag = args[1];
    const colon = std.mem.lastIndexOfScalar(u8, repo_tag, ':') orelse {
        std.debug.print("zwslc: expected REPO:TAG, got '{s}'\n", .{repo_tag});
        return 1;
    };
    const repo = repo_tag[0..colon];
    const tag_name = repo_tag[colon + 1 ..];

    var session = main.defaultSession(gpa, arena, environ) catch return 1;
    defer session.deinit();

    const image_z = gpa.dupeZ(u8, image) catch return error.OutOfMemory;
    defer gpa.free(image_z);
    const repo_z = gpa.dupeZ(u8, repo) catch return error.OutOfMemory;
    defer gpa.free(repo_z);
    const tag_z = gpa.dupeZ(u8, tag_name) catch return error.OutOfMemory;
    defer gpa.free(tag_z);

    const options: wslc.sys.WslcTagImageOptions = .{ .image = image_z.ptr, .repo = repo_z.ptr, .tag = tag_z.ptr };
    var err_msg: wslc.sys.PWSTR = null;
    const hr = wslc.sys.WslcTagSessionImage(session.handle, &options, &err_msg);
    wslc.sys.freeTaskMem(err_msg);
    wslc.sys.ok(hr) catch |err| {
        std.debug.print("zwslc: tag failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

pub fn push(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    var image: ?[]const u8 = null;
    var registry_auth: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--registry-auth") and i + 1 < args.len) {
            i += 1;
            registry_auth = args[i];
        } else if (image == null) {
            image = args[i];
        }
    }
    const img = image orelse {
        std.debug.print("usage: zwslc push [--registry-auth AUTH] IMAGE\n", .{});
        return 1;
    };

    var session = main.defaultSession(gpa, arena, environ) catch return 1;
    defer session.deinit();

    const image_z = gpa.dupeZ(u8, img) catch return error.OutOfMemory;
    defer gpa.free(image_z);
    const auth_z = gpa.dupeZ(u8, registry_auth) catch return error.OutOfMemory;
    defer gpa.free(auth_z);

    const options: wslc.sys.WslcPushImageOptions = .{ .image = image_z.ptr, .registryAuth = auth_z.ptr };
    var err_msg: wslc.sys.PWSTR = null;
    const hr = wslc.sys.WslcPushSessionImage(session.handle, &options, &err_msg);
    wslc.sys.freeTaskMem(err_msg);
    wslc.sys.ok(hr) catch |err| {
        std.debug.print("zwslc: push failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

pub fn remove(gpa: std.mem.Allocator, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    if (args.len == 0) {
        std.debug.print("usage: zwslc rmi IMAGE\n", .{});
        return 1;
    }
    var session = main.defaultSession(gpa, arena, environ) catch return 1;
    defer session.deinit();

    var failures: u8 = 0;
    for (args) |name_or_id| {
        session.deleteImage(name_or_id, gpa) catch |err| {
            std.debug.print("zwslc: failed to remove '{s}': {s}\n", .{ name_or_id, @errorName(err) });
            failures += 1;
            continue;
        };
        std.debug.print("{s}\n", .{name_or_id});
    }
    return if (failures != 0) 1 else 0;
}
