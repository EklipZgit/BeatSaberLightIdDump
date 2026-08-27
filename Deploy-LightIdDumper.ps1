#Requires -Version 7.0
<#
.SYNOPSIS
Builds/deploys LightIdDumper for selected or all installed Beat Saber versions, or uninstalls it.

.PARAMETER Version
One or more supported versions. If omitted, every installed supported version is selected.

.PARAMETER Release
Build and deploy Release configurations instead of Debug configurations.

.PARAMETER Uninstall
Remove LightIdDumper.dll from every configured supported game's Plugins folder without building.
#>
param(
    [ValidateSet("1.29.1", "1.34.2", "1.37.1", "1.40.8", "1.42.1", "1.44.1", "1.44.2")]
    [string[]]$Version,

    [switch]$Release,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Repository-local paths keep the complete utility portable as one checkout.
. (Join-Path $PSScriptRoot "ScriptCommon.ps1")
$BuildScript = Join-Path $PSScriptRoot "build-all-versions.ps1"
$VersionsToProcess = if ($null -ne $Version -and $Version.Count -gt 0) { @($Version) } else { @(Get-LightIdDumperInstalledVersions) }

# Uninstall is intentionally exact and non-recursive so no other plugin or user data is touched.
if ($Uninstall) {
    $Removed = @()
    $NotInstalled = @()
    foreach ($GameVersion in $VersionsToProcess) {
        $BeatSaberDir = Get-LightIdDumperBeatSaberDirectory -GameVersion $GameVersion

        # Luna deploys a companion PDB, so uninstall removes both exact mod artifacts and nothing recursively.
        $PluginDirectory = Join-Path $BeatSaberDir "Plugins"
        $InstalledArtifacts = @(
            (Join-Path $PluginDirectory "LightIdDumper.dll"),
            (Join-Path $PluginDirectory "LightIdDumper.pdb")
        )
        $ExistingArtifacts = @($InstalledArtifacts | Where-Object { Test-Path -LiteralPath $_ })
        if ($ExistingArtifacts.Count -gt 0) {
            Remove-Item -LiteralPath $ExistingArtifacts -Force
            $Removed += "$GameVersion ($($ExistingArtifacts -join ', '))"
        }
        else {
            $NotInstalled += $GameVersion
        }
    }

    Write-Host "Removed LightIdDumper from: $($Removed -join ', ')" -ForegroundColor Green
    if ($NotInstalled.Count -gt 0) {
        Write-Host "Not installed for: $($NotInstalled -join ', ')" -ForegroundColor Yellow
    }

    return
}

if (-not (Test-Path -LiteralPath $BuildScript)) {
    throw "Build script not found: $BuildScript"
}

# The project script owns configuration selection, compile references, artifact checks, and per-version deployment.
& $BuildScript -Version $VersionsToProcess -Release:$Release
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Completed BeatSaberLightIdDumper deployment at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
