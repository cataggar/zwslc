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

# Drain stderr asynchronously (also avoids a classic redirected-process
# deadlock if the child ever writes enough to stderr to fill the OS pipe
# buffer while nothing is reading it) and keep it around for diagnostics.
$stderrLines = New-Object System.Collections.Generic.List[string]
$stderrEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
    if ($null -ne $EventArgs.Data) {
        $Event.MessageData.Add($EventArgs.Data) | Out-Null
    }
} -MessageData $stderrLines
$proc.BeginErrorReadLine()

# Write raw UTF-8 bytes directly to the underlying stdin stream - no
# StreamWriter involved at all, so there's no ambiguity about a preamble/BOM
# being auto-emitted on first write (observed as a real, CI-only JSON-RPC
# "Parse error" on the very first, pure-ASCII request - never reproduced
# locally with either powershell.exe or pwsh.exe, and not fixed by an
# explicitly-constructed no-BOM StreamWriter, so something about merely
# touching Process.StandardInput's own StreamWriter/BaseStream still wrote
# extra bytes first). Encoding.UTF8.GetBytes() never includes a BOM (only
# Encoding.UTF8.GetPreamble() does), unlike a StreamWriter which can.
$stdinStream = $proc.StandardInput.BaseStream

function Send-Request([string]$Json, [int]$WaitMs = 2000) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json + "`n")
    $stdinStream.Write($bytes, 0, $bytes.Length)
    $stdinStream.Flush()
    Start-Sleep -Milliseconds $WaitMs
    return $proc.StandardOutput.ReadLine()
}

function Show-Diagnostics {
    Start-Sleep -Milliseconds 200 # let any final async stderr lines arrive
    Write-Host "---- diagnostics ----"
    Write-Host "process HasExited: $($proc.HasExited)"
    if ($proc.HasExited) { Write-Host "process ExitCode: $($proc.ExitCode)" }
    Write-Host "stderr captured so far:"
    if ($stderrLines.Count -eq 0) { Write-Host "  <none>" } else { $stderrLines | ForEach-Object { Write-Host "  $_" } }
    Write-Host "----------------------"
}

try {
    $initResponse = Send-Request '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0.0.1"}}}'
    if ($null -eq $initResponse -or $initResponse -notmatch '"zwslc-mcp"') {
        $bytes = if ($null -ne $initResponse) { ($initResponse.ToCharArray() | ForEach-Object { [int]$_ }) -join ',' } else { '<null>' }
        Show-Diagnostics
        Write-Error "smoke-test-mcp FAILED: unexpected 'initialize' response: $initResponse (char codes: $bytes)"
        exit 1
    }

    $toolsResponse = Send-Request '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    if ($null -eq $toolsResponse) {
        Show-Diagnostics
        Write-Error "smoke-test-mcp FAILED: no response to 'tools/list'"
        exit 1
    }

    $missing = @($ExpectedTools | Where-Object { $toolsResponse -notmatch [regex]::Escape('"' + $_ + '"') })
    if ($missing.Count -gt 0) {
        Show-Diagnostics
        Write-Error "smoke-test-mcp FAILED: missing tools in tools/list response: $($missing -join ', ')`nFull response: $toolsResponse"
        exit 1
    }

    Write-Host "smoke-test-mcp PASSED: all $($ExpectedTools.Count) expected tools present in tools/list."
    exit 0
}
finally {
    Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) {
        $proc.Kill()
    }
}
