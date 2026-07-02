# zwslc

A Zig 0.16 SDK and CLI for the [WSL container API](https://wsl.dev/api-reference/c/)
(`wslcsdk.h` / `wslcsdk.lib`, `Microsoft.WSL.Containers`, currently in preview).

Uses Zig comptime to project the flat C ABI into a fast, type-safe surface, styled
after the patterns in [windows-rs's Zig port](https://github.com/microsoft/windows-rs).

> **PREVIEW NOTICE:** The underlying WSL container API is in preview and subject to
> breaking changes. This project follows suit.

## Layout

```
zwslc/
  build.zig              # top-level build graph
  build.zig.zon          # dependency manifest (pins Microsoft.WSL.Containers NuGet package)
  packages/
    wslc-sys/             # raw, ABI-exact extern bindings to wslcsdk.h
    wslc/                  # safe, idiomatic Session/Container/Process/Image wrapper
  cli/                     # `zwslc` executable, reproducing the wslc.exe command shape
  samples/
    end_to_end/            # Zig port of Microsoft's documented C end-to-end example
  tests/                   # package-level tests
  docs/
    comptime-design.md     # explains the comptime techniques used
```

## Requirements

- Zig **0.16.0** or later.
- Windows 10/11 to run. WSL with the container feature installed
  (`wsl --install --no-distribution`) to exercise anything beyond `zwslc version`.

## Build

```
zig build            # build all packages + the zwslc CLI
zig build test       # run tests (struct/ABI/flag/error-set tests run without WSL installed;
                      # integration tests are skipped unless WslcGetMissingComponents == NONE)
```

## Scope

See `docs/comptime-design.md` for the comptime techniques and the project's plan
for the full command-coverage table (what's backed 1:1 by the public SDK vs.
explicitly unsupported, e.g. `image build` and `network *`, which have no
corresponding C API).
