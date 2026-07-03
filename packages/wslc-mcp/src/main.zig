//! `zwslc-mcp`: an MCP (Model Context Protocol) server exposing the WSL
//! container SDK (`packages/wslc`) as structured tools for AI agents.
//!
//! Unlike the stateless `zwslc` CLI, this is a long-lived process, so it can
//! hold an in-memory registry of containers across tool calls within a
//! single server session, which is what finally makes `container_status`/
//! `container_logs`/`stop_container`/`delete_container` work meaningfully
//! (see GitHub issue #2 and docs/mcp-server.md for the full design
//! rationale, tool reference, safety-boundary note, and registry-lifetime
//! caveats).

const std = @import("std");
const mcp = @import("mcp");
const context_mod = @import("context.zig");
const version_tools = @import("tools/version.zig");
const image_tools = @import("tools/images.zig");
const container_tools = @import("tools/containers.zig");

pub const AppContext = context_mod.AppContext;

pub fn main(init: std.process.Init) !void {
    var server = mcp.Server.init(init.gpa, .{
        .name = "zwslc-mcp",
        .version = "0.0.0",
        .description = "MCP server exposing the WSL container SDK (packages/wslc) to AI agents.",
    });
    defer server.deinit();

    // `ctx.deinit()` (registry + lazily-created session cleanup) runs on
    // any clean shutdown - see docs/mcp-server.md's "Registry lifetime and
    // cleanup" section for exactly what is/isn't cleaned up, and why a hard
    // crash (not a clean exit) can still orphan containers.
    var ctx = AppContext.init(init.gpa, init.environ_map);
    defer ctx.deinit();

    try version_tools.register(&server);
    try image_tools.register(&server, &ctx);
    try container_tools.register(&server, &ctx);

    try server.run(init.io, init.gpa, .stdio);
}

test {
    // Pull in registry.zig/context.zig's own tests too (see
    // packages/wslc/src/root.zig for the same pattern).
    std.testing.refAllDecls(@This());
}
