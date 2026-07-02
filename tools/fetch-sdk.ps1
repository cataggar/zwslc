<#
.SYNOPSIS
    Downloads and extracts the Microsoft.WSL.Containers NuGet package, which
    contains the authoritative wslcsdk.h header, wslcsdk.lib import libraries
    (x64 + arm64), and wslcsdk.dll runtime binaries.

.DESCRIPTION
    A .nupkg file is just a zip archive, but Zig's package manager (`zig fetch`)
    only recognizes package URLs ending in a known archive extension (.tar.gz,
    .zip, etc.) or git URLs. Since the NuGet flat-container URL ends in
    `.nupkg`, we can't use a `build.zig.zon` dependency directly. Instead, this
    script downloads the package to a locally-named `.zip` file (sidestepping
    the extension check) and extracts it with Expand-Archive, which is content-
    based (via System.IO.Compression) and doesn't care about the source
    extension either.

    Idempotent: skips the download/extract if the destination already contains
    the expected header and both architectures' import libraries.
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Dest
)

$ErrorActionPreference = 'Stop'

$destFull = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Dest))
$headerPath = Join-Path $destFull 'include\wslcsdk.h'
$x64LibPath = Join-Path $destFull 'runtimes\win-x64\wslcsdk.lib'
$arm64LibPath = Join-Path $destFull 'runtimes\win-arm64\wslcsdk.lib'

if ((Test-Path $headerPath) -and (Test-Path $x64LibPath) -and (Test-Path $arm64LibPath)) {
    Write-Host "wslc-sdk: already fetched at $destFull (version $Version)"
    exit 0
}

New-Item -ItemType Directory -Force -Path $destFull | Out-Null

$url = "https://api.nuget.org/v3-flatcontainer/microsoft.wsl.containers/$Version/microsoft.wsl.containers.$Version.nupkg"
$zipPath = Join-Path $destFull "microsoft.wsl.containers.$Version.zip"

Write-Host "wslc-sdk: downloading $url"
Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

Write-Host "wslc-sdk: extracting to $destFull"
Expand-Archive -Path $zipPath -DestinationPath $destFull -Force
Remove-Item -Force $zipPath

if (-not (Test-Path $headerPath)) {
    Write-Error "wslc-sdk: expected header not found after extraction: $headerPath"
    exit 1
}
if (-not (Test-Path $x64LibPath)) {
    Write-Error "wslc-sdk: expected x64 import lib not found after extraction: $x64LibPath"
    exit 1
}

Write-Host "wslc-sdk: ready ($Version) at $destFull"
