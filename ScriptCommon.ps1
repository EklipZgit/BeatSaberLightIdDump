#Requires -Version 7.0

# Every script uses this one configuration list so installed-version discovery and build support cannot drift apart.
$script:LightIdDumperSupportedVersions = @("1.29.1", "1.34.2", "1.37.1", "1.40.8", "1.42.1", "1.44.1", "1.44.2")
$script:LightIdDumperBsManagerInstancesRoot = "C:\Users\tdrak\BSManager\BSInstances"

# An explicit process environment path wins; otherwise the standard BSManager instance location is used.
function Get-LightIdDumperBeatSaberDirectory {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("1.29.1", "1.34.2", "1.37.1", "1.40.8", "1.42.1", "1.44.1", "1.44.2")]
        [string]$GameVersion
    )

    $environmentVariable = "BEATSABER_" + $GameVersion.Replace(".", "_")
    $configuredDirectory = [Environment]::GetEnvironmentVariable($environmentVariable, "Process")
    if (-not [string]::IsNullOrWhiteSpace($configuredDirectory)) {
        return $configuredDirectory
    }

    return Join-Path $script:LightIdDumperBsManagerInstancesRoot $GameVersion
}

# Installed means both the version directory and its actual game executable exist.
function Get-LightIdDumperInstalledVersions {
    $installedVersions = @(
        foreach ($gameVersion in $script:LightIdDumperSupportedVersions) {
            $gameDirectory = Get-LightIdDumperBeatSaberDirectory -GameVersion $gameVersion
            if ((Test-Path -LiteralPath $gameDirectory -PathType Container) -and
                (Test-Path -LiteralPath (Join-Path $gameDirectory "Beat Saber.exe") -PathType Leaf)) {
                $gameVersion
            }
        }
    )

    if ($installedVersions.Count -eq 0) {
        throw "No supported Beat Saber installations were found below [$script:LightIdDumperBsManagerInstancesRoot] or through BEATSABER_* variables."
    }

    return $installedVersions
}
