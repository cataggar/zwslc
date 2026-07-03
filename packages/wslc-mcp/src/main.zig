//! `zwslc-mcp`: an MCP (Model Context Protocol) server exposing the WSL
//! container SDK (`packages/wslc`) as structured tools for AI agents.
//!
//! Unlike the stateless `zwslc` CLI, this is a long-lived process, so it can
//! hold an in-memory registry of containers/processes across tool calls
//! within a single server session, which is what finally makes
//! `container_status`/`container_logs`/`stop_container` work meaningfully
//! (see GitHub issue #2 for the full design rationale). Tools are registered
//! incrementally as they're implemented; this scaffold starts a server with
//! none yet.

const std = @import("std");
const mcp = @import("mcp");
const registry_mod = @import("registry.zig");

pub const Registry = registry_mod.Registry;

pub fn main(init: std.process.Init) !void {
    var server = mcp.Server.init(init.gpa, .{
        .name = "zwslc-mcp",
        .version = "0.0.0",
        .description = "MCP server exposing the WSL container SDK (packages/wslc) to AI agents.",
    });
    defer server.deinit();

    var registry = Registry.init(init.gpa);
    defer registry.deinit();

    // TODO(#2): register version/image/container tools here as they land
    // (passing `&registry` to the container-lifecycle ones).

    try server.run(init.io, init.gpa, .stdio);
}

test {
    // Pull in registry.zig's own tests too (see packages/wslc/src/root.zig
    // for the same pattern).
    std.testing.refAllDecls(@This());
}
