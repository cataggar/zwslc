const std = @import("std");

/// Pinned version of the `Microsoft.WSL.Containers` NuGet package. This is the
/// authoritative source of `wslcsdk.h` / `wslcsdk.lib` / `wslcsdk.dll` (MIT
/// licensed, https://github.com/microsoft/WSL). Bump this when a newer WSL
/// container SDK preview ships, then re-run `zig build fetch-sdk`.
const sdk_version = "2.9.3";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
            .imports = &.{
                .{ .name = "wslc", .module = wslc_mod },
            },
        }),
    });
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
}
