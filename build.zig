const std = @import("std");

/// Pinned version of the `Microsoft.WSL.Containers` NuGet package. This is the
/// authoritative source of `wslcsdk.h` / `wslcsdk.lib` / `wslcsdk.dll` (MIT
/// licensed, https://github.com/microsoft/WSL). Bump this when a newer WSL
/// container SDK preview ships, then re-run `zig build fetch-sdk`.
const sdk_version = "2.9.3";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Version string embedded in `zwslc version`/the MCP server's
    // serverInfo - set by CI release builds via `-Dversion=<tag minus v>`
    // (matches ../wabt's release.yml convention). `build.zig.zon`'s own
    // `.version` field is separate package-manager metadata, bumped by hand.
    const version = b.option([]const u8, "version", "Version string embedded in zwslc/zwslc-mcp output") orelse "0.0.0-dev";
    const strip = b.option(bool, "strip", "Strip debug info from release binaries") orelse false;
    // A handful of tests (in wslc-sys/wslc) call real WSLC SDK functions
    // like WslcGetVersion that - it turns out - fail with a non-succeeded
    // HRESULT on a bare GitHub-hosted Windows runner (no WSL container
    // feature enabled), not just needing wslcsdk.dll + COM as this repo
    // previously assumed. Default true (full coverage for local dev, where
    // WSL is expected to be set up per the README); CI passes
    // -Dtest-real-sdk=false.
    const test_real_sdk = b.option(bool, "test-real-sdk", "Run tests that require an actual working WSL container feature (default true; CI sets false)") orelse true;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "test_real_sdk", test_real_sdk);
    // `Module.addOptions` calls `options.createModule()` internally, which
    // creates a *new* module object on every call - fine for a single
    // consumer, but multiple modules in the same dependency chain (e.g.
    // wslc_mod importing wslc_sys_mod, both wanting "build_options") each
    // ending up with their own distinct-but-identical module then collide
    // ("file exists in modules 'build_options' and 'build_options0'") once
    // the whole graph is compiled together. Create it once here and
    // `.addImport("build_options", build_options_mod)` everywhere instead.
    const build_options_mod = options.createModule();

    if (target.result.os.tag != .windows) {
        std.debug.panic(
            "zwslc only supports Windows targets (the WSL container API is Windows-only), got: {s}",
            .{@tagName(target.result.os.tag)},
        );
    }
    const arch_dir = switch (target.result.cpu.arch) {
        .x86_64 => "win-x64",
        .aarch64 => "win-arm64",
        else => std.debug.panic(
            "zwslc: unsupported architecture {s} (wslcsdk.lib is only published for x64/arm64)",
            .{@tagName(target.result.cpu.arch)},
        ),
    };

    // ---- Fetch & extract the real WSL container SDK (header + import lib + dll) ----
    // See tools/fetch-sdk.ps1 for why this isn't a build.zig.zon dependency.
    const sdk_dir = ".wslc-sdk-cache/microsoft.wsl.containers-" ++ sdk_version;
    const fetch_sdk = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
    fetch_sdk.addFileArg(b.path("tools/fetch-sdk.ps1"));
    fetch_sdk.addArgs(&.{ "-Version", sdk_version, "-Dest", sdk_dir });

    const fetch_step = b.step("fetch-sdk", "Download & extract the Microsoft.WSL.Containers NuGet package (header/lib/dll)");
    fetch_step.dependOn(&fetch_sdk.step);

    const sdk_lib_dir = b.pathJoin(&.{ sdk_dir, "runtimes", arch_dir });
    const sdk_dll_path = b.pathJoin(&.{ sdk_lib_dir, "native", "wslcsdk.dll" });

    // A compile/run step that needs the real DLL/import-lib must (a) wait for
    // the fetch to finish and (b) be able to find wslcsdk.dll at runtime.
    // `needsSdk` wires (a); `addPathDir(sdk_lib_dir + "/native")` on the
    // corresponding Run step wires (b).
    const sdk_native_dir = b.pathJoin(&.{ sdk_lib_dir, "native" });

    // ---- packages/wslc-sys: raw, ABI-exact bindings ----
    const wslc_sys_mod = b.addModule("wslc-sys", .{
        .root_source_file = b.path("packages/wslc-sys/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    wslc_sys_mod.addLibraryPath(b.path(sdk_lib_dir));
    wslc_sys_mod.linkSystemLibrary("wslcsdk", .{});
    wslc_sys_mod.addImport("build_options", build_options_mod);

    const wslc_sys_tests = b.addTest(.{ .root_module = wslc_sys_mod });
    wslc_sys_tests.step.dependOn(&fetch_sdk.step);
    const run_wslc_sys_tests = b.addRunArtifact(wslc_sys_tests);
    run_wslc_sys_tests.addPathDir(sdk_native_dir);

    // ---- packages/wslc: safe, idiomatic wrapper ----
    const wslc_mod = b.addModule("wslc", .{
        .root_source_file = b.path("packages/wslc/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wslc-sys", .module = wslc_sys_mod },
        },
    });
    wslc_mod.addImport("build_options", build_options_mod);

    const wslc_tests = b.addTest(.{ .root_module = wslc_mod });
    wslc_tests.step.dependOn(&fetch_sdk.step);
    const run_wslc_tests = b.addRunArtifact(wslc_tests);
    run_wslc_tests.addPathDir(sdk_native_dir);

    // ---- cli: the `zwslc` executable ----
    const cli_exe = b.addExecutable(.{
        .name = "zwslc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = if (strip) true else null,
            .imports = &.{
                .{ .name = "wslc", .module = wslc_mod },
            },
        }),
    });
    cli_exe.root_module.addImport("build_options", build_options_mod);
    cli_exe.step.dependOn(&fetch_sdk.step);
    b.installArtifact(cli_exe);
    // Ship wslcsdk.dll next to the installed exe so `zig-out/bin/zwslc.exe` is runnable standalone.
    const install_dll = b.addInstallFileWithDir(b.path(sdk_dll_path), .bin, "wslcsdk.dll");
    install_dll.step.dependOn(&fetch_sdk.step);
    b.getInstallStep().dependOn(&install_dll.step);

    const run_cmd = b.addRunArtifact(cli_exe);
    run_cmd.addPathDir(sdk_native_dir);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zwslc");
    run_step.dependOn(&run_cmd.step);

    const cli_tests = b.addTest(.{ .root_module = cli_exe.root_module });
    cli_tests.step.dependOn(&fetch_sdk.step);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    run_cli_tests.addPathDir(sdk_native_dir);

    // ---- wslc-mcp: the `zwslc-mcp` MCP server executable ----
    const mcp_dep = b.dependency("mcp", .{ .target = target, .optimize = optimize });
    const mcp_exe = b.addExecutable(.{
        .name = "zwslc-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/wslc-mcp/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = if (strip) true else null,
            .imports = &.{
                .{ .name = "wslc", .module = wslc_mod },
                .{ .name = "mcp", .module = mcp_dep.module("mcp") },
            },
        }),
    });
    mcp_exe.root_module.addImport("build_options", build_options_mod);
    mcp_exe.step.dependOn(&fetch_sdk.step);
    b.installArtifact(mcp_exe);
    const install_mcp_dll = b.addInstallFileWithDir(b.path(sdk_dll_path), .bin, "wslcsdk.dll");
    install_mcp_dll.step.dependOn(&fetch_sdk.step);
    b.getInstallStep().dependOn(&install_mcp_dll.step);

    const run_mcp_cmd = b.addRunArtifact(mcp_exe);
    run_mcp_cmd.addPathDir(sdk_native_dir);
    run_mcp_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_mcp_cmd.addArgs(args);
    const run_mcp_step = b.step("run-mcp", "Run zwslc-mcp (STDIO MCP server)");
    run_mcp_step.dependOn(&run_mcp_cmd.step);

    const mcp_tests = b.addTest(.{ .root_module = mcp_exe.root_module });
    mcp_tests.step.dependOn(&fetch_sdk.step);
    const run_mcp_tests = b.addRunArtifact(mcp_tests);
    run_mcp_tests.addPathDir(sdk_native_dir);

    // ---- smoke-test-mcp: black-box STDIO test of the *installed* zwslc-mcp.exe ----
    // Unlike `mcp_tests` above (a `zig test` binary compiled from the same
    // source, exercising Zig-level unit tests), this spawns the real
    // installed executable as a subprocess and talks real JSON-RPC over its
    // STDIO transport - the same way an actual MCP client would. See
    // tools/smoke-test-mcp.ps1 for why this is PowerShell rather than Zig
    // (avoids depending on Zig 0.16's still-evolving std.Io subprocess API
    // for a test that's inherently just "does the real binary work").
    const smoke_test_mcp = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
    smoke_test_mcp.addFileArg(b.path("tools/smoke-test-mcp.ps1"));
    smoke_test_mcp.addArg("-ExePath");
    smoke_test_mcp.addArg(b.getInstallPath(.bin, "zwslc-mcp.exe"));
    smoke_test_mcp.step.dependOn(b.getInstallStep());
    const smoke_test_mcp_step = b.step("smoke-test-mcp", "Spawn the installed zwslc-mcp.exe and verify its tools/list over real STDIO");
    smoke_test_mcp_step.dependOn(&smoke_test_mcp.step);

    // ---- samples/end_to_end: Zig port of Microsoft's documented C sample ----
    const sample_exe = b.addExecutable(.{
        .name = "end_to_end",
        .root_module = b.createModule(.{
            .root_source_file = b.path("samples/end_to_end/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wslc", .module = wslc_mod },
            },
        }),
    });
    sample_exe.step.dependOn(&fetch_sdk.step);

    const run_sample_cmd = b.addRunArtifact(sample_exe);
    run_sample_cmd.addPathDir(sdk_native_dir);
    if (b.args) |args| run_sample_cmd.addArgs(args);
    const run_sample_step = b.step("run-sample", "Run the end-to-end sample (samples/end_to_end)");
    run_sample_step.dependOn(&run_sample_cmd.step);

    // ---- aggregate test step ----
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_wslc_sys_tests.step);
    test_step.dependOn(&run_wslc_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_mcp_tests.step);
}
