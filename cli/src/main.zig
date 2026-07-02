//! zwslc: a CLI reproducing the shape of the real `wslc.exe`, built on the
//! `wslc` package.
//!
//! Phase 1 status: only `zwslc version` is implemented, as an end-to-end
//! smoke test (cli -> wslc -> wslc-sys -> real wslcsdk.lib). The full command
//! tree (container/image/system session/volume/registry, see the plan's
//! coverage table) lands in Phase 5.

const std = @import("std");
const wslc = @import("wslc");

pub fn main(init: std.process.Init) !void {
    var args_it = try init.minimal.args.iterateAllocator(init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // skip argv[0]
    const cmd = args_it.next() orelse "version";

    if (std.mem.eql(u8, cmd, "version")) {
        return version();
    }

    std.debug.print("zwslc: unknown or not-yet-implemented command '{s}'\n", .{cmd});
    std.process.exit(1);
}

fn version() !void {
    const v = wslc.getVersion() catch |err| {
        std.debug.print("zwslc: failed to query WSL container SDK version: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("zwslc 0.0.0 (wslcsdk {d}.{d}.{d})\n", .{ v.major, v.minor, v.revision });
}
