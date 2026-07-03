# zwslc-mcp: an MCP server for the WSL container SDK

`packages/wslc-mcp` builds `zwslc-mcp.exe`, a [Model Context
Protocol](https://modelcontextprotocol.io/docs/getting-started/intro) server
that exposes `packages/wslc` (the WSL container SDK wrapper) as structured
tools for AI agents, using [cataggar/mcp.zig](https://github.com/cataggar/mcp.zig)
(a fork of [muhammad-fiaz/mcp.zig](https://github.com/muhammad-fiaz/mcp.zig),
pinned to Zig 0.16.x) as the protocol library.

See [GitHub issue #2](https://github.com/cataggar/zwslc/issues/2) for the
original design rationale.

## Why an MCP server, not just "the CLI as tools"

`zwslc-mcp` is a **long-lived process**, unlike each stateless `zwslc.exe`
invocation. That's the key architectural difference: it holds an in-memory
registry of containers across separate `tools/call` requests within one
server session, which is what finally makes `container_status`/
`stop_container`/`delete_container`/`container_logs` work meaningfully -
something the CLI explicitly cannot do (see the root README's Scope table:
"`container ls`/`ps` ... only meaningful within a single `run` invocation -
no API to list/reopen containers created by a prior process"). The WSL
container SDK itself still has no such API; this server's registry, not the
SDK, provides that continuity, and only within this one server process.

`zwslc-mcp` uses the **same session storage as the real `wslc.exe` CLI**
(`%LOCALAPPDATA%\wslc\sessions\wslc-cli-<username>`), so its image/container
tools see and share the exact same images as the real tool and `zwslc`
itself - not a third, disconnected image store.

> **Note:** only one process can have that storage open at a time, and
> there's no SDK-level way around it - `WslcCreateSession` always creates a
> new session (there's no `WslcOpenSession`/`WslcListSessions` to attach to
> an existing one). The real `wslc.exe` keeps its VM running in the
> background after use - confirmed empirically to *not* idle out on its own
> within at least an hour - so a tool call that fails with a sharing
> violation likely means a `wslc.exe` session is still warm; run `wslc
> system session terminate` first.

## Running it

```
zig build                # builds zig-out/bin/zwslc-mcp.exe (+ wslcsdk.dll next to it)
zig build run-mcp        # runs it directly (STDIO transport)
zig build smoke-test-mcp # spawns the installed exe and checks tools/list over real STDIO
```

Point any MCP client that launches local STDIO servers (e.g. Copilot CLI, an
IDE's MCP integration) at `zig-out/bin/zwslc-mcp.exe`. No arguments; it
speaks MCP over stdin/stdout immediately.

## Tool reference

| Tool | Backed by | Notes |
|---|---|---|
| `get_version` | `WslcGetVersion` | no session needed - works even before the WSL container feature is installed |
| `get_missing_components` | `WslcGetMissingComponents` | returns `{missing: [...], sdk_needs_update}`; same prerequisite-check role as in Microsoft's documented end-to-end example |
| `list_images` | `WslcListSessionImages` | JSON array (name, size_bytes, full sha256 hex, created_unix_time) |
| `pull_image` | `WslcPullSessionImage` | |
| `tag_image` | `WslcTagSessionImage` | separate `repo`/`tag` JSON fields, unlike the CLI's combined `REPO:TAG` string |
| `push_image` | `WslcPushSessionImage` | |
| `delete_image` | `WslcDeleteSessionImage` | |
| `run_container` | create→start→wait→cleanup | blocking, like `docker run` without `-d`; if `auto_remove` is `false`, the container is kept and registered (see below) instead of orphaned |
| `create_container` | `WslcCreateContainer` | detached - creates but doesn't start; registers the container and returns a `container_id` |
| `start_container` | `WslcStartContainer` | looks up `container_id` in the registry |
| `container_status` | `WslcGetContainerState` | returns state/name/image/auto_remove/created_at_ms for a registered `container_id` |
| `stop_container` | `WslcStopContainer` | optional `signal` (default `SIGTERM`) and `timeout_seconds` (default 10) |
| `delete_container` | `WslcDeleteContainer` | removes the `container_id` from the registry |
| `exec_in_container` | `WslcCreateContainerProcess` (secondary process) | blocking; returns `{exit_code, stdout, stderr}` and appends the transcript to the container's accumulated log |
| `container_logs` | registry-buffered | returns the accumulated `exec_in_container` transcript for a `container_id` |

## Safety boundary

There is **no allowlist or sandboxing beyond the container boundary** in this
version: `run_container`/`exec_in_container` are real code-execution
capability, exactly like running `zwslc run`/a shell yourself. Whoever can
launch this MCP server can already run arbitrary containers directly, so
this doesn't introduce a new privilege boundary - but be aware that any
agent with access to these tools can execute arbitrary code inside
containers on this machine. This may warrant additional guardrails (image
allowlists, resource limits, network mode restrictions) if `zwslc-mcp` is
ever exposed somewhere more automated/multi-tenant than a local session.

## Registry lifetime and cleanup

- Containers created via `create_container`, or via `run_container` with
  `auto_remove: false`, are tracked in an in-memory registry for the life of
  the `zwslc-mcp` server process.
- On a **clean** server exit, the registry's cleanup best-effort stops and
  deletes any container that was registered with `auto_remove: true` (or via
  `run_container`'s default `auto_remove` behavior, which already
  stops+deletes before returning rather than registering at all). Containers
  registered with `auto_remove: false` are **intentionally left running** -
  same as exiting a shell that started a detached `docker run` container
  without `--rm`. Use `delete_container` (or `stop_container` first) to clean
  them up explicitly.
- A **hard crash** (not a clean process exit) can still orphan containers
  either way - this is a documented limitation, not something this registry
  fully solves. There's no cross-process/cross-restart persistence: a new
  `zwslc-mcp` process cannot see or manage containers from a previous one
  (matching the SDK's own lack of a list/reopen-by-ID API).
- `container_logs`' accumulated transcript only covers `exec_in_container`
  calls (secondary processes) - the container's own init-process stdout/
  stderr is not captured; see the next section.

## Known SDK preview limitations (not our bugs)

- **Init-process stdio isn't forwarded.** Registering *any* callback (even a
  bare onExit-only one) on a container's *init* process currently makes
  `WslcStartContainer` fail with `E_INVALIDARG` on this preview SDK build,
  with no error message text to diagnose further (see `cli/src/container_cmds.zig`
  and `docs/comptime-design.md`). `exec_in_container`/`container_logs`
  sidestep this by using a *secondary* process (`Container.createProcess`),
  which isn't affected.
- **`Process.waitForExit()` can race stdio callbacks.** The SDK's process
  exit *event* (what `waitForExit` waits on) can signal before all buffered
  stdout/stderr has been delivered via the stdio callback. `wslcsdk.h`
  documents that the `onExit` *callback* only fires once IO is fully
  flushed, so `exec_in_container` waits on a Win32 event set from `onExit`
  instead of calling `waitForExit()`, to avoid silently truncating captured
  output.
- Everything else in the root README's Scope table (no `image build`,
  `network *`, `settings` support - no corresponding C API) applies here too,
  since this server is built directly on the same `packages/wslc` SDK
  wrapper as the CLI.
