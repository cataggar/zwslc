//! packages/wslc: safe, idiomatic wrapper around `wslc-sys`.
//!
//! Phase 3 status: `Session`/`Container`/`Process` plus their Zig-native
//! settings builders are implemented, covering session lifecycle, container
//! lifecycle, process lifecycle, image pull/list/delete, and VHD volume
//! create/delete — enough for the Phase 4 end-to-end sample. Not yet wrapped
//! (use `wslc.sys` directly for now): image import/load/tag/push,
//! `WslcSessionAuthenticate`, and session crash-dump callback registration.

const std = @import("std");
pub const sys = @import("wslc-sys");

const session_mod = @import("session.zig");
const container_mod = @import("container.zig");
const process_mod = @import("process.zig");

pub const Session = session_mod.Session;
pub const SessionSettings = session_mod.SessionSettings;
pub const VhdRequirements = session_mod.VhdRequirements;

pub const Container = container_mod.Container;
pub const ContainerSettings = container_mod.ContainerSettings;
pub const PortMapping = container_mod.PortMapping;
pub const Volume = container_mod.Volume;
pub const NamedVolume = container_mod.NamedVolume;

pub const Process = process_mod.Process;
pub const ProcessSettings = process_mod.ProcessSettings;
pub const stdioCallback = process_mod.stdioCallback;
pub const exitCallback = process_mod.exitCallback;

/// Returns the installed WSL container SDK version, or an error if the call
/// fails. Doesn't require an active session — mirrors the first step of
/// Microsoft's documented end-to-end example. Ensures COM is initialized on
/// the calling thread first.
pub fn getVersion() sys.Error!sys.WslcVersion {
    try sys.ensureComInitialized();
    var v: sys.WslcVersion = .{ .major = 0, .minor = 0, .revision = 0 };
    try sys.ok(sys.WslcGetVersion(&v));
    return v;
}

/// Returns the bitmask of required WSL components not yet installed. Pass
/// the result to `installWithDependencies`, or check `.NONE`/`.has(...)` to
/// decide whether to proceed. Mirrors the prerequisite check in Microsoft's
/// documented end-to-end example (checked before anything else).
pub fn getMissingComponents() sys.Error!sys.WslcComponentFlags {
    try sys.ensureComInitialized();
    var flags: sys.WslcComponentFlags = .NONE;
    try sys.ok(sys.WslcGetMissingComponents(&flags));
    return flags;
}

/// Installs any missing WSL components (may require a reboot for
/// `VIRTUAL_MACHINE_PLATFORM`). `progress_callback`/`context` are optional.
pub fn installWithDependencies(progress_callback: sys.WslcInstallCallback, context: ?*anyopaque) sys.Error!void {
    try sys.ensureComInitialized();
    try sys.ok(sys.WslcInstallWithDependencies(progress_callback, context));
}

test "wslc.getVersion links through to the real SDK" {
    const v = try getVersion();
    try std.testing.expect(v.major >= 2);
}

test "wslc.getMissingComponents links through to the real SDK" {
    _ = try getMissingComponents();
}

test {
    // Pull in session.zig/container.zig/process.zig's own tests too.
    std.testing.refAllDecls(@This());
}
