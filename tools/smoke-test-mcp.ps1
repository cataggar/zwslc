<#
.SYNOPSIS
    Smoke test for zwslc-mcp: spawns the built zwslc-mcp.exe as a real
    subprocess and exchanges JSON-RPC over its STDIO transport, the same way
    a real MCP client would.

.DESCRIPTION
    Sends `initialize` then `tools/list`, and checks that every tool this
    project's packages/wslc-mcp is expected to expose is present in the
    response. Exits 0 on success, 1 (with a clear message) on failure - this
    is wired into `zig build smoke-test-mcp` (see build.zig) rather than
    `zig build test`, since it needs the already-built/installed executable
    on disk, not just compiled source.

.PARAMETER ExePath
    Path to zwslc-mcp.exe (defaults to zig-out\bin\zwslc-mcp.exe next to
    this script's repo root).
#>
param(
    [string]$ExePath = (Join-Path $PSScriptRoot "..\zig-out\bin\zwslc-mcp.exe")
)

$ErrorActionPreference = "Stop"

$ExpectedTools = @(
    "get_version",
    "get_missing_components",
    "list_images",
    "pull_image",
    "tag_image",
    "push_image",
    "delete_image",
    "run_container",
    "create_container",
    "start_container",
    "container_status",
    "stop_container",
    "delete_container",
    "exec_in_container",
    "container_logs"
)

if (-not (Test-Path $ExePath)) {
    Write-Error "smoke-test-mcp: executable not found at '$ExePath' - run 'zig build' first."
    exit 1
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Resolve-Path $ExePath).Path
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)

# Wrap stdin with an explicit, BOM-less UTF-8 StreamWriter: relying on
# ProcessStartInfo's default input encoding is not reliable across
# PowerShell versions/OS locales (StandardInputEncoding also isn't even
# available on Windows PowerShell 5.1's older .NET Framework) - a stray BOM
# prepended to the first written line is valid JSON to some parsers but not
# others, and was observed causing a real JSON-RPC "Parse error" response
# on a GitHub-hosted Windows runner (never reproduced locally) before this
# fix.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stdin = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, $utf8NoBom)
$stdin.AutoFlush = $true

function Send-Request([string]$Json, [int]$WaitMs = 2000) {
    $stdin.WriteLine($Json)
    Start-Sleep -Milliseconds $WaitMs
    return $proc.StandardOutput.ReadLine()
}

try {
    $initResponse = Send-Request '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0.0.1"}}}'
    if ($null -eq $initResponse -or $initResponse -notmatch '"zwslc-mcp"') {
        Write-Error "smoke-test-mcp FAILED: unexpected 'initialize' response: $initResponse"
        exit 1
    }

    $toolsResponse = Send-Request '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    if ($null -eq $toolsResponse) {
        Write-Error "smoke-test-mcp FAILED: no response to 'tools/list'"
        exit 1
    }

    $missing = @($ExpectedTools | Where-Object { $toolsResponse -notmatch [regex]::Escape('"' + $_ + '"') })
    if ($missing.Count -gt 0) {
        Write-Error "smoke-test-mcp FAILED: missing tools in tools/list response: $($missing -join ', ')`nFull response: $toolsResponse"
        exit 1
    }

    Write-Host "smoke-test-mcp PASSED: all $($ExpectedTools.Count) expected tools present in tools/list."
    exit 0
}
finally {
    $stdin.Dispose()
    if (-not $proc.HasExited) {
        $proc.Kill()
    }
}
