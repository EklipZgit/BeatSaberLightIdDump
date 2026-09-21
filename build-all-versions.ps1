#Requires -Version 7.0
<#
.SYNOPSIS
Builds and deploys LightIdDumper for one or all supported Beat Saber versions.

.DESCRIPTION
Each build uses a '<Configuration>-<Version>' configuration and the matching
BEATSABER_<Version> process environment variable. Luna's BSMT_CopyToPlugins
target installs LightIdDumper.dll into that version's Plugins directory.

.PARAMETER Version
One or more Beat Saber versions to build. If omitted, every installed supported version is built.

.PARAMETER Release
Build Release configurations instead of the default Debug configurations.

.PARAMETER PluginVersion
SemVer embedded into the BSIPA manifest before game-version build metadata.
#>
param(
    [ValidateSet("1.29.1", "1.34.2", "1.37.1", "1.40.8", "1.42.1", "1.44.1", "1.44.2")]
    [string[]]$Version,

    [switch]$Release,

    # Version 1.8.0 emits format 4 with classification-specific fields and removes constant/runtime-only record noise.
    [ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')]
    [string]$PluginVersion = "1.8.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared discovery keeps explicit environment overrides while making a no-argument build target only installed versions.
. (Join-Path $PSScriptRoot "ScriptCommon.ps1")

# Build every selected configuration; the project supplies version-local reference fallbacks for 1.44.2's assembly layout.
$SlnFile = Join-Path $PSScriptRoot "LightIdDumper.sln"
$Configuration = if ($Release) { "Release" } else { "Debug" }
$VersionsToBuild = if ($null -ne $Version -and $Version.Count -gt 0) { @($Version) } else { @(Get-LightIdDumperInstalledVersions) }

if (-not (Test-Path -LiteralPath $SlnFile)) {
    throw "Solution not found: $SlnFile"
}

# Fail before building if any selected installation cannot supply its compile references or deploy target.
$Invalid = @()
foreach ($GameVersion in $VersionsToBuild) {
    $InstallPath = Get-LightIdDumperBeatSaberDirectory -GameVersion $GameVersion
    if (-not (Test-Path -LiteralPath $InstallPath -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $InstallPath "Beat Saber.exe") -PathType Leaf)) {
        $Invalid += "    Beat Saber $GameVersion is not installed at: $InstallPath"
    }
}

if ($Invalid.Count -gt 0) {
    throw "Invalid Beat Saber installation paths:`n$($Invalid -join "`n")"
}

$SuccessfulBuilds = @()
$FailedBuilds = @()

# Luna asks Git for HEAD while generating artifact metadata; a newly initialized repository has no HEAD until its first commit.
$OriginalGitRedirectStderr = $env:GIT_REDIRECT_STDERR
try {
    $env:GIT_REDIRECT_STDERR = "nul"
    git -C $PSScriptRoot rev-parse --verify HEAD *> $null
    $RepositoryHasCommit = $LASTEXITCODE -eq 0
}
finally {
    $env:GIT_REDIRECT_STDERR = $OriginalGitRedirectStderr
}
if (-not $RepositoryHasCommit) {
    Write-Host "Git commit metadata unavailable because this repository has no commits yet; Luna will use placeholder HEAD metadata." -ForegroundColor DarkYellow
}

# Each configuration compiles against and deploys only to its matching game installation.
foreach ($GameVersion in $VersionsToBuild) {
    $BeatSaberDir = Get-LightIdDumperBeatSaberDirectory -GameVersion $GameVersion
    $BuildConfiguration = "$Configuration-$GameVersion"

    Write-Host ""
    Write-Host "=== Building $BuildConfiguration ===" -ForegroundColor Cyan
    Write-Host "BeatSaberDir: $BeatSaberDir"

    # Suppress only Git-for-Windows' expected missing-HEAD stderr during Luna metadata discovery; real dotnet build output remains visible.
    try {
        if (-not $RepositoryHasCommit) {
            $env:GIT_REDIRECT_STDERR = "nul"
        }
        dotnet build $SlnFile `
            -c $BuildConfiguration `
            "-p:BeatSaberDir=$BeatSaberDir" `
            "-p:Version=$PluginVersion" `
            --nologo
        $BuildExitCode = $LASTEXITCODE
    }
    finally {
        $env:GIT_REDIRECT_STDERR = $OriginalGitRedirectStderr
    }

    if ($BuildExitCode -ne 0) {
        $FailedBuilds += $BuildConfiguration
        Write-Host "Build failed for $BuildConfiguration" -ForegroundColor Red
        continue
    }

    $SuccessfulBuilds += $BuildConfiguration
    $BuiltDllPath = Join-Path $PSScriptRoot "LightIdDumper\bin\$BuildConfiguration\net48\LightIdDumper.dll"
    if (Test-Path -LiteralPath $BuiltDllPath) {
        $BuiltDll = Get-Item -LiteralPath $BuiltDllPath
        Write-Host "Built DLL: $($BuiltDll.FullName)" -ForegroundColor Green
        Write-Host "Built DLL timestamp (UTC): $($BuiltDll.LastWriteTimeUtc.ToString('O'))" -ForegroundColor Green

        # BSMT has now deployed either live or pending; discard only a pending LightIdDumper older than the live copy.
        Remove-StaleLightIdDumperPendingPlugin -GameDirectory $BeatSaberDir
    }
    else {
        $FailedBuilds += $BuildConfiguration
        $SuccessfulBuilds = @($SuccessfulBuilds | Where-Object { $_ -ne $BuildConfiguration })
        Write-Host "Expected artifact not found: $BuiltDllPath" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Build summary ===" -ForegroundColor Cyan
if ($SuccessfulBuilds.Count -gt 0) {
    Write-Host "Successful: $($SuccessfulBuilds -join ', ')" -ForegroundColor Green
}

if ($FailedBuilds.Count -gt 0) {
    Write-Host "Failed: $($FailedBuilds -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "All builds succeeded." -ForegroundColor Green
