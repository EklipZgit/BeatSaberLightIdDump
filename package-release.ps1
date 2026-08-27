#Requires -Version 7.0
<#
.SYNOPSIS
Builds plugin-only release archives for selected Beat Saber versions.
#>
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')]
    [string]$Version,

    [ValidateSet("1.29.1", "1.34.2", "1.37.1", "1.40.8", "1.42.1", "1.44.1", "1.44.2")]
    [string[]]$GameVersion = @("1.29.1", "1.34.2", "1.37.1", "1.40.8", "1.42.1", "1.44.1", "1.44.2")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Release packaging reuses the exact builds deployed and verified by the multi-version script.
$BuildScript = Join-Path $PSScriptRoot "build-all-versions.ps1"
$ProjectDirectory = Join-Path $PSScriptRoot "LightIdDumper"
$DistDirectory = Join-Path $PSScriptRoot "dist"
New-Item -ItemType Directory -Force -Path $DistDirectory | Out-Null

foreach ($SelectedGameVersion in $GameVersion) {
    & $BuildScript -Version $SelectedGameVersion -Release -PluginVersion $Version

    $ZipDirectory = Join-Path $ProjectDirectory "bin\Release-$SelectedGameVersion\net48\zip"
    $SourceZip = Get-ChildItem -LiteralPath $ZipDirectory -Filter "*.zip" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $SourceZip) {
        throw "No release archive was produced for Beat Saber $SelectedGameVersion."
    }

    $Destination = Join-Path $DistDirectory "LightIdDumper-$Version-bs$SelectedGameVersion.zip"
    Copy-Item -LiteralPath $SourceZip.FullName -Destination $Destination -Force
    Write-Host "Release archive ready: $Destination" -ForegroundColor Green
}
