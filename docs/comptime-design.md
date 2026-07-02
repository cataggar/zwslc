# Comptime design

`zwslc` wraps the WSL container API (`wslcsdk.h`) using Zig comptime
metaprogramming, styled after [windows-rs's Zig
port](https://github.com/microsoft/windows-rs)'s `win-core`/`win-sys`
conventions. Unlike that project, there's no `.winmd`/metadata to drive a
`project()`-style generator — the WSLC C API is hand-transcribed from the
real header (see `packages/wslc-sys/src/root.zig`'s module doc comment for
how that was verified). So instead of one big metadata-driven generator, this
project uses five small, focused comptime *generators*, each solving one
specific repeated problem in the raw binding layer.

## 1. `AbiBlob(size, alignment)` — opaque settings wrapper

`WslcSessionSettings`/`WslcContainerSettings`/`WslcProcessSettings` are
intentionally opaque fixed-size byte blobs in the real header — callers never
read/write fields directly, only via `Wslc*Init*Settings`/`Wslc*Set*Settings*`
builder calls. `AbiBlob` generates the wrapper type and a paired `comptime`
assertion:

```zig
pub fn AbiBlob(comptime size: usize, comptime alignment: usize) type {
    return extern struct {
        _opaque: [size]u8 align(alignment) = undefined,
    };
}
pub const WslcSessionSettings = AbiBlob(WSLC_SESSION_OPTIONS_SIZE, WSLC_SESSION_OPTIONS_ALIGNMENT);
comptime {
    assert(@sizeOf(WslcSessionSettings) == WSLC_SESSION_OPTIONS_SIZE);
    assert(@alignOf(WslcSessionSettings) == WSLC_SESSION_OPTIONS_ALIGNMENT);
}
```

Without this, we'd hand-write three near-identical structs and hope the
size/alignment constants never silently drift from a future SDK header.

## 2. `Handle(tag)` — distinct nominal handle types

`wslcsdk.h` declares `WslcSession`/`WslcContainer`/`WslcProcess`/
`WslcCrashDumpSubscription` via `DECLARE_HANDLE`, which in C already produces
a nominal pointer-to-incomplete-struct type per handle — specifically so they
can't be silently interchanged. Zig can reproduce that guarantee with a
one-line generic:

```zig
pub fn Handle(comptime tag_name: []const u8) type {
    return ?*opaque { pub const debug_name = tag_name; };
}
pub const Session = Handle("WslcSession");
pub const Container = Handle("WslcContainer");
```

Each instantiation with a distinct `tag_name` produces a genuinely distinct
type at zero runtime cost — passing a `Container` where a `Session` is
expected is a compile error, something the original C API can't enforce at
all beyond naming convention.

## 3. `Flags(E)` — bitflag mixin

Six WSLC enums are bitflags (`WslcContainerFlags`, `WslcSessionFeatureFlags`,
...). Rather than hand-writing `merge`/`has` six times, one generic supplies
them, with a `comptime` guard that rejects a non-power-of-two enumerator or
an accidentally-exhaustive enum at compile time:

```zig
pub const WslcContainerFlags = enum(u32) {
    NONE = 0, AUTO_REMOVE = 0x1, ENABLE_GPU = 0x2, PRIVILEGED = 0x4,
    _, // non-exhaustive: required so arbitrary OR combinations are valid
    pub const merge = Flags(@This()).merge;
    pub const has = Flags(@This()).has;
};
```

`container_flags.merge(.AUTO_REMOVE, .ENABLE_GPU).has(.AUTO_REMOVE)` reads
like a hand-written API, but the implementation is shared and self-validating.

## 4. Table-driven `Error`/`ok`/`toError`

One array of `{name, hr}` pairs (the 15 `WSLC_E_*` domain codes plus a
curated set of generic HRESULTs) drives HRESULT<->error mapping, mirroring
windows-rs/zig's `hresult.ok()` idiom. **Caveat**: this Zig toolchain removed
the dynamic `@Type` builtin (only per-kind `@Struct`/`@Enum`/`@Union` remain,
no `@ErrorSet` equivalent), so `Error` itself has to be a literal
`error{...}` — but a `comptime` block cross-checks that literal against the
table (same names, same count), so the two can't silently drift apart even
though the error set itself isn't synthesized from the table directly.

## 5. `stdioCallback`/`exitCallback` — callback trampoline generators

The C API wants a plain `callconv(.winapi)` function pointer plus an opaque
`PVOID context` for `WslcProcessCallbacks` — it has no notion of a Zig
closure, and a *runtime* value can't carry per-instance behavior the way a
closure would (Zig function pointers can't capture state). Each generator
takes the context type and a handler function as `comptime` parameters and
synthesizes a fresh, ABI-correct trampoline at compile time:

```zig
pub fn stdioCallback(
    comptime Ctx: type,
    comptime handler: fn (ctx: *Ctx, io_handle: sys.WslcProcessIOHandle, data: []const u8) void,
) sys.WslcStdIOCallback {
    return struct {
        fn trampoline(io_handle: sys.WslcProcessIOHandle, data: [*]const u8, data_bytes: u32, context: ?*anyopaque) callconv(.winapi) void {
            const ctx: *Ctx = @ptrCast(@alignCast(context.?));
            handler(ctx, io_handle, data[0..data_bytes]);
        }
    }.trampoline;
}
```

Callers write a plain typed Zig function; the raw `anyopaque`/`callconv`
plumbing is generated, not hand-rolled, per call site.

## A hard-won lesson these techniques don't cover: pointer lifetime

None of the above is about memory *lifetime* — that turned out to be the
real source of bugs during development (see git history for Phases 4-5).
`wslcsdk.h`'s `Wslc*Init*Settings`/`Wslc*Set*Settings*` builder functions do
**not** deep-copy the strings/structs passed to them; they retain the
pointers and dereference them lazily, at the corresponding `WslcCreate*`
call (and, for a container's init-process callbacks, apparently for the
container's *entire lifetime*, not just through creation). `packages/wslc`'s
`Session`/`Container`/`Process` wrappers handle this by threading a single
`std.heap.ArenaAllocator` through the whole `build()` + `Create*()` sequence,
handing the arena off to the returned handle wrapper (freed only in its
`deinit()`) rather than tearing it down as soon as the builder function
returns. This isn't documented anywhere in `wslcsdk.h` — it was found by
comparing a raw `wslc-sys` reproduction (which happened to keep buffers alive
long enough) against the `wslc` wrapper (which didn't) after
`WslcCreateSession` returned `E_INVALIDARG` with a garbled error message.
