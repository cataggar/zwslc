# zwslc

A Zig 0.16 SDK and CLI for the [WSL container API](https://wsl.dev/api-reference/c/)
(`wslcsdk.h` / `wslcsdk.lib`, `Microsoft.WSL.Containers`, currently in preview).

Uses Zig comptime to project the flat C ABI into a fast, type-safe surface, styled
after the patterns in [windows-rs's Zig port](https://github.com/microsoft/windows-rs).
See `docs/comptime-design.md` for the specific techniques used (and a hard-won
lesson about pointer lifetimes that isn't documented in `wslcsdk.h` itself).

> **PREVIEW NOTICE:** The underlying WSL container API is in preview and subject to
> breaking changes. This project follows suit.

## Install

Install pre-built binaries from GitHub Releases with [ghr](https://github.com/cataggar/ghr):

```console
$ ghr install cataggar/zwslc@v0.1.0 RWT2wp6Q5BroB9dEh2Y5zRtU6q6C/XaXx4NUeQ31MwL6N7Wk3Yg6BWV9
```

This installs both `zwslc` (the CLI) and `zwslc-mcp` (the MCP server), verifying
the downloaded release archive against the minisign public key above before
extracting it. See [`.github/workflows/release.yml`](.github/workflows/release.yml)
for how releases are built and signed.

## Layout

```
zwslc/
  build.zig               # top-level build graph; also fetches the real SDK (see below)
  build.zig.zon           # package manifest (mcp is the only build.zig.zon dep - see tools/fetch-sdk.ps1)
  tools/fetch-sdk.ps1      # downloads/extracts the Microsoft.WSL.Containers NuGet package
  tools/smoke-test-mcp.ps1 # spawns the built zwslc-mcp.exe and checks tools/list over real STDIO
  packages/
    wslc-sys/src/root.zig  # raw, ABI-exact extern bindings to wslcsdk.h (60 functions,
                           # 15 structs, 15 enums, 5 callbacks, 16 error codes) + the
                           # AbiBlob/Handle/Flags/Error comptime generators
    wslc/src/              # safe, idiomatic Session/Container/Process wrapper
      session.zig           #   Session + SessionSettings
      container.zig         #   Container + ContainerSettings
      process.zig           #   Process + ProcessSettings + stdioCallback/exitCallback
      strings.zig           #   shared PCSTR/PCWSTR marshaling helpers
    wslc-mcp/src/          # the `zwslc-mcp` MCP server (see docs/mcp-server.md)
      main.zig               #   server startup + tool registration
      context.zig             #   AppContext: shared lazy Session + Registry
      registry.zig            #   in-memory container registry (what makes this more than "the CLI as tools")
      tools/version.zig       #   get_version / get_missing_components
      tools/images.zig        #   pull/list/tag/push/delete_image
      tools/containers.zig    #   run/create/start/status/stop/delete_container, exec_in_container, container_logs
  cli/src/                 # the `zwslc` executable
    main.zig                #   arg parsing + dispatch
    container_cmds.zig      #   run / container ls
    image_cmds.zig           #   pull / images / tag / push / rmi
  samples/end_to_end/       # Zig port of Microsoft's documented C end-to-end example
  docs/comptime-design.md   # the five comptime techniques used, + the lifetime lesson
  docs/mcp-server.md       # zwslc-mcp tool reference, safety boundary, registry lifetime
```

Tests live inline in each package's source files (`zig build test` runs all of them).

## Requirements

- Zig **0.16.0** or later.
- Windows 10/11 to run. WSL with the container feature installed
  (`wsl --install --no-distribution`, plus whatever enables the container preview on
  your build) to exercise anything beyond `zwslc version`/`zig build test`.

## Build

```
zig build fetch-sdk   # one-time: download/extract wslcsdk.h/.lib/.dll (also runs automatically)
zig build             # build all packages + zwslc/zwslc-mcp -> zig-out/bin/{zwslc.exe,zwslc-mcp.exe}
zig build test        # run tests (struct/ABI/flag/error-set tests need no WSL install;
                      # a handful call into the real wslcsdk.dll and need COM, which
                      # ensureComInitialized() sets up automatically)
zig build run-sample  # run the end-to-end sample (needs the container preview enabled)
zig build run-mcp     # run zwslc-mcp (the MCP server) directly over STDIO
zig build smoke-test-mcp  # spawn the installed zwslc-mcp.exe and check tools/list over real STDIO
```

> You may see a `warning(link): unexpected LLD stderr` about a "skipped imported
> DllMain symbol" during linking — this is benign (Zig is just being cautious about
> unexpected linker stderr) and doesn't affect the build's exit code or the result.

## CLI usage

```
zwslc version
zwslc pull alpine:latest
zwslc images
zwslc run alpine:latest /bin/echo "hello from a container"
zwslc tag alpine:latest myrepo/myalpine:v1
zwslc rmi myrepo/myalpine:v1
```

Every invocation creates a fresh `WslcSession` against the **same session
storage the real `wslc.exe` CLI uses** for its default session
(`%LOCALAPPDATA%\wslc\sessions\wslc-cli-<username>`), so `zwslc`'s images and
containers are the same ones you'd see from the real tool — no separate,
disconnected image store. Since WSLC images are stored durably under that
path, `pull`/`images`/`tag`/`push`/`rmi` see the same images across separate
invocations (zwslc's own or the real wslc.exe's) even though the session
itself is new every time — verified by pulling, tagging, and listing across
three separate process runs.

> **Note:** only one process can have that storage open at a time. The real
> `wslc.exe` keeps its VM running in the background after use — confirmed
> empirically to *not* idle out on its own within at least an hour — and the
> public WSL container SDK has no API to attach to or share an
> already-running session (`WslcCreateSession` always creates a new one;
> there's no `WslcOpenSession`/`WslcListSessions`). If `zwslc` reports the
> storage is in use, run `wslc system session terminate` first.

## MCP server

`zig-out/bin/zwslc-mcp.exe` (see `packages/wslc-mcp/`) is a long-lived [Model
Context Protocol](https://modelcontextprotocol.io/docs/getting-started/intro)
server exposing the same SDK as structured tools for AI agents, using
[cataggar/mcp.zig](https://github.com/cataggar/mcp.zig) — built to make
`container_status`/`stop_container`/`container_logs`/etc. work meaningfully
across separate tool calls, unlike the stateless CLI. See
[`docs/mcp-server.md`](docs/mcp-server.md) for the full tool reference,
safety-boundary note, and registry-lifetime caveats.

## Scope: what's implemented vs. not supported

The SDK is a small (~60 function), preview-quality C API with real gaps —
notably, **no call to enumerate or reopen a container/session created by a
different process**. That shapes what a stateless CLI can and can't do:

| Command | Status |
|---|---|
| `version` | ✅ backed by `WslcGetVersion` |
| `run`/`container run` | ✅ foreground create→start→wait→cleanup (like `docker run` without `-d`) |
| `pull`/`image pull`, `images`/`image list`, `tag`, `push`, `rmi`/`image rm` | ✅ backed 1:1 by the image APIs; persist across invocations (see above) |
| `container ls`/`ps` | ⚠️ only meaningful within a single `run` invocation — no API to list/reopen containers from a prior process |
| `image build` | ❌ no corresponding C API (the real `wslc build` drives this some other way, not via `wslcsdk.h`) |
| `network *` | ❌ no C API surface at all |
| `settings` | ❌ no API-backed concept |
| container stdout/stderr forwarding during `run` | ⚠️ not wired up yet — registering callbacks on a container's init process currently makes `WslcStartContainer` fail (`E_INVALIDARG`) on this preview SDK build; see the note in `cli/src/container_cmds.zig` |

## Known SDK gotcha (not our bug)

`wslcsdk.h`'s builder functions (`Wslc*Init*Settings`/`Wslc*Set*Settings*`)
do **not** deep-copy the strings/structs you pass them — they retain the
pointers and dereference them lazily, at the corresponding `WslcCreate*`
call (and, for a container's init-process settings, apparently for the
container's entire lifetime). See `docs/comptime-design.md` for how
`packages/wslc` handles this with an arena whose lifetime is tied to the
resulting handle wrapper, not the builder call.

## License

MIT — see [`LICENSE`](LICENSE). The underlying `Microsoft.WSL.Containers`
NuGet package (`wslcsdk.h`/`.lib`/`.dll`, fetched at build time) is also
MIT-licensed, from [`github.com/microsoft/WSL`](https://github.com/microsoft/WSL).
