#Requires -Version 7.0
<#
.SYNOPSIS
Builds LightIdDumper, generates a clean donor map from the first custom song, batch-dumps every environment, validates the captures, cleans up, and uninstalls.

.PARAMETER Version
One or more supported game versions. All installed supported versions run when omitted.

.PARAMETER Environment
Dumps only this one catalog entry instead of the whole catalog. The controller receives the filter argument and
exits after that single environment, so each run resolves dynamically-spawned GameCore roots (ring clones) in a
fresh process; only the named environment's paired captures are replaced in RuntimeLightData.

.PARAMETER OutputPath
Final RuntimeLightData root. Defaults to RuntimeLightData inside this repository.

.PARAMETER TimeoutMinutes
Maximum time one Beat Saber process may run before the exact spawned process is stopped and the batch fails.

.PARAMETER Verify
Also compares captured lights with the Heck/Chroma and ChroMapper mapping datasets. Mapping discrepancies fail the run.
#>
param(
    [ValidateSet("1.29.1", "1.34.2", "1.37.1", "1.40.8", "1.42.1", "1.44.1", "1.44.2")]
    [string[]]$Version,

    [ValidateNotNullOrEmpty()]
    [string]$Environment,

    [string]$OutputPath,

    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 30,

    # Mapping-table comparison is opt-in because collecting valid runtime captures must not fail on an existing Heck or ChroMapper table discrepancy.
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Repository-local automation and shared discovery make the script portable and limit no-argument runs to installed versions.
. (Join-Path $PSScriptRoot "ScriptCommon.ps1")
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot "build-all-versions.ps1"
$DeployScript = Join-Path $PSScriptRoot "Deploy-LightIdDumper.ps1"
$VerifyScript = Join-Path $PSScriptRoot "Verify-LightIdMappings.ps1"
$VersionsToRun = if ($null -ne $Version -and $Version.Count -gt 0) { @($Version) } else { @(Get-LightIdDumperInstalledVersions) }
$FinalOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $PSScriptRoot "RuntimeLightData"
}
else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
$ExpectedDumpFormatVersion = 5
$RunFailures = [System.Collections.Generic.List[string]]::new()
$GeneratedDonorDirectories = [System.Collections.Generic.List[object]]::new()

# A generated donor map preserves the first installed custom song's audio while replacing its content with one empty
# difficulty that declares Chroma and Noodle Extensions requirements (on modern, fully modded installs), so automated
# level launches load through the same modded beatmap-data pipeline as the real Chroma/Noodle maps whose GameCore
# root ordering must be captured. Legacy installs (pre-1.37.1 Harmony/SiraUtil stacks) and installs without both mods
# keep a requirements-free donor because the requirements either cannot be satisfied or activate fragile legacy
# patch chains (the combined BeatmapObjectSpawnController.Start patching corrupted the dynamic method on 1.29.1).
function New-LightIdDumperGeneratedDonorMap {
    param(
        [Parameter(Mandatory)]
        [string]$GameDirectory,

        [Parameter(Mandatory)]
        [string]$GameVersion,

        [bool]$CarryRequirements
    )

    $customLevelsRoot = Join-Path $GameDirectory "Beat Saber_Data\CustomLevels"
    if (-not (Test-Path -LiteralPath $customLevelsRoot -PathType Container)) {
        throw "CustomLevels directory not found for Beat Saber [$GameVersion]: $customLevelsRoot"
    }

    # Directory ordering matches the in-mod donor ordering and excludes artifacts left by an interrupted earlier batch.
    $sourceMap = Get-ChildItem -LiteralPath $customLevelsRoot -Directory |
        Where-Object { -not $_.Name.StartsWith("000_LightIdDumperGenerated-", [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object FullName |
        Select-Object -First 1
    if ($null -eq $sourceMap) {
        throw "No source custom map exists below [$customLevelsRoot] for generated donor audio."
    }

    $sourceInfoPath = Get-ChildItem -LiteralPath $sourceMap.FullName -File |
        Where-Object Name -IEQ "Info.dat" |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($sourceInfoPath)) {
        throw "The first custom map [$($sourceMap.FullName)] has no Info.dat."
    }

    $sourceInfo = Get-Content -LiteralPath $sourceInfoPath -Raw | ConvertFrom-Json -Depth 100
    $songFilename = [string]($sourceInfo._songFilename ?? $sourceInfo.songFilename)
    $coverFilename = [string]($sourceInfo._coverImageFilename ?? $sourceInfo.coverImageFilename)
    $sourceAudioPath = Join-Path $sourceMap.FullName $songFilename
    $sourceCoverPath = Join-Path $sourceMap.FullName $coverFilename
    if ([string]::IsNullOrWhiteSpace($songFilename) -or -not (Test-Path -LiteralPath $sourceAudioPath -PathType Leaf)) {
        throw "The first custom map [$($sourceMap.FullName)] does not expose a readable song file through Info.dat."
    }

    # The version-specific name sorts before ordinary BeatSaver IDs, ensuring SongCore supplies this clean map as the first donor.
    $generatedDirectory = Join-Path $customLevelsRoot "000_LightIdDumperGenerated-$GameVersion"
    Remove-LightIdDumperGeneratedDonorMap -CustomLevelsRoot $customLevelsRoot -GeneratedDirectory $generatedDirectory
    New-Item -ItemType Directory -Path $generatedDirectory | Out-Null

    # Hard links avoid copying large audio/cover assets; copying is the portable fallback if the filesystem rejects links.
    $generatedAudioPath = Join-Path $generatedDirectory $songFilename
    try {
        New-Item -ItemType HardLink -Path $generatedAudioPath -Target $sourceAudioPath | Out-Null
    }
    catch {
        Copy-Item -LiteralPath $sourceAudioPath -Destination $generatedAudioPath
    }

    $generatedCoverFilename = if (-not [string]::IsNullOrWhiteSpace($coverFilename) -and (Test-Path -LiteralPath $sourceCoverPath -PathType Leaf)) {
        $coverFilename
    }
    else {
        $null
    }
    if ($null -ne $generatedCoverFilename) {
        $generatedCoverPath = Join-Path $generatedDirectory $generatedCoverFilename
        try {
            New-Item -ItemType HardLink -Path $generatedCoverPath -Target $sourceCoverPath | Out-Null
        }
        catch {
            Copy-Item -LiteralPath $sourceCoverPath -Destination $generatedCoverPath
        }
    }

    # V2 is accepted throughout the supported game matrix and the single empty Easy difficulty is overridden to every catalog environment at runtime.
    $generatedBeatmap = [ordered]@{
        _version = "2.2.0"
        _notes = @()
        _obstacles = @()
        _events = @()
        _waypoints = @()
    }
    $generatedBeatmap | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $generatedDirectory "LightIdDumper.dat") -Encoding utf8

    # An omitted _requirements key is the original working donor shape; an empty array would serialize as null
    # through the empty-pipeline behavior and break legacy StandardLevelInfoSaveData deserialization.
    $generatedDifficulty = [ordered]@{
        _difficulty = "Easy"
        _difficultyRank = 1
        _beatmapFilename = "LightIdDumper.dat"
        _noteJumpMovementSpeed = 10
        _noteJumpStartBeatOffset = 0
    }
    if ($CarryRequirements) {
        # Real Chroma/Noodle maps load through the modded pipeline whose GameCore root ordering this dumper must
        # reproduce; declaring the requirements makes the donor take that same load path while the empty beatmap
        # keeps the captured environment unmodified.
        $generatedDifficulty["_customData"] = [ordered]@{
            _requirements = @("Chroma", "Noodle Extensions")
        }
    }

    $generatedInfo = [ordered]@{
        _version = "2.1.0"
        _songName = "LightIdDumper - " + [string]($sourceInfo._songName ?? $sourceInfo.songName ?? $sourceMap.Name)
        _songSubName = [string]($sourceInfo._songSubName ?? $sourceInfo.songSubName ?? "")
        _songAuthorName = [string]($sourceInfo._songAuthorName ?? $sourceInfo.songAuthorName ?? "")
        _levelAuthorName = "LightIdDumper"
        _beatsPerMinute = [double]($sourceInfo._beatsPerMinute ?? $sourceInfo.beatsPerMinute ?? 120)
        _songTimeOffset = 0
        _shuffle = 0
        _shufflePeriod = 0.5
        _previewStartTime = 0
        _previewDuration = 10
        _songFilename = $songFilename
        _coverImageFilename = $generatedCoverFilename
        _environmentName = "DefaultEnvironment"
        _allDirectionsEnvironmentName = "DefaultEnvironment"
        _difficultyBeatmapSets = @(
            [ordered]@{
                _beatmapCharacteristicName = "Standard"
                _difficultyBeatmaps = @($generatedDifficulty)
            }
        )
    }
    $generatedInfo | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $generatedDirectory "Info.dat") -Encoding utf8

    Write-Host "Generated donor map from first custom song [$($sourceMap.FullName)] at [$generatedDirectory]." -ForegroundColor DarkCyan
    return [pscustomobject]@{
        CustomLevelsRoot = $customLevelsRoot
        GeneratedDirectory = $generatedDirectory
    }
}

# Cleanup is restricted to the exact generated leaf below the selected CustomLevels root.
function Remove-LightIdDumperGeneratedDonorMap {
    param(
        [Parameter(Mandatory)]
        [string]$CustomLevelsRoot,

        [Parameter(Mandatory)]
        [string]$GeneratedDirectory
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($CustomLevelsRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedGeneratedDirectory = [System.IO.Path]::GetFullPath($GeneratedDirectory)
    $generatedLeaf = [System.IO.Path]::GetFileName($resolvedGeneratedDirectory)
    if (-not $resolvedGeneratedDirectory.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $generatedLeaf.StartsWith("000_LightIdDumperGenerated-", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove generated donor outside the expected CustomLevels target: [$resolvedGeneratedDirectory]."
    }

    if (Test-Path -LiteralPath $resolvedGeneratedDirectory -PathType Container) {
        Remove-Item -LiteralPath $resolvedGeneratedDirectory -Recurse -Force
    }
}

# Exact current-format checks prevent stale, truncated, or owner-anonymous files from passing the batch.
function Test-LightIdDumpFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedEnvironment,

        [Parameter(Mandatory)]
        [string]$ExpectedGameVersion,

        [Parameter(Mandatory)]
        [datetime]$StartedAtUtc,

        [Parameter(Mandatory)]
        [bool]$ExpectedOtherLights
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Dump file does not exist: $Path"
    }

    $file = Get-Item -LiteralPath $Path
    if ($file.LastWriteTimeUtc -lt $StartedAtUtc.AddSeconds(-2)) {
        throw "Dump [$Path] predates this run. File UTC [$($file.LastWriteTimeUtc.ToString('O'))], run UTC [$($StartedAtUtc.ToString('O'))]."
    }

    $dump = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    if ([int]$dump.formatVersion -ne $ExpectedDumpFormatVersion) {
        throw "Dump [$Path] has formatVersion [$($dump.formatVersion)] instead of [$ExpectedDumpFormatVersion]."
    }

    # Wall-clock capture metadata would dirty every repository file on every run, so current-format validation rejects it outright.
    if ($null -ne $dump.PSObject.Properties["capturedAtUtc"]) {
        throw "Dump [$Path] contains retired capturedAtUtc metadata. Recapture with the current dumper."
    }

    if ([string]$dump.environmentName -cne $ExpectedEnvironment) {
        throw "Dump [$Path] names environment [$($dump.environmentName)] instead of [$ExpectedEnvironment]."
    }

    if (-not ([string]$dump.gameVersion).StartsWith($ExpectedGameVersion, [StringComparison]::Ordinal)) {
        throw "Dump [$Path] reports gameVersion [$($dump.gameVersion)] instead of [$ExpectedGameVersion]."
    }

    $slotIds = [System.Collections.Generic.HashSet[int]]::new()
    $calculatedTotal = 0
    # Format 4 relies on the classified filename and rejects every constant, inapplicable, or run-local field removed from both outputs.
    $alwaysForbiddenProperties = @(
        "isNonMonoBehavior",
        "isRegistered",
        "activeSelf",
        "activeInHierarchy",
        "ownerActiveSelf",
        "ownerActiveInHierarchy",
        "ownerInstanceId",
        "instanceId",
        "position",
        "localPosition",
        "ownerPosition",
        "ownerLocalPosition"
    )
    # Each file must expose only its applicable identity family so constant null placeholders cannot return unnoticed.
    $classificationForbiddenProperties = if ($ExpectedOtherLights) {
        @("gameObjectPath", "localScale", "sceneName")
    }
    else {
        @("ownerGameObjectPath", "ownerComponentType", "indexWithinOwner", "ownerLocalScale", "ownerSceneName", "intensity", "bakeId", "weight")
    }
    $classificationRequiredProperties = if ($ExpectedOtherLights) {
        @("ownerGameObjectPath", "ownerComponentType", "indexWithinOwner", "ownerLocalScale", "ownerSceneName", "intensity", "bakeId", "weight")
    }
    else {
        @("gameObjectPath", "localScale", "sceneName")
    }
    foreach ($slot in $dump.lightIdSlots) {
        $slotId = [int]$slot.beatSaberLightId
        if (-not $slotIds.Add($slotId)) {
            throw "Dump [$Path] repeats Beat Saber light ID slot [$slotId]."
        }

        $lights = @($slot.registeredLights)
        if ([int]$slot.registeredLightCount -ne $lights.Count) {
            throw "Dump [$Path] slot [$slotId] count does not match its entry array."
        }

        $managerIndexes = [System.Collections.Generic.HashSet[int]]::new()
        $previousManagerIndex = -1
        for ($index = 0; $index -lt $lights.Count; $index++) {
            $light = $lights[$index]
            $managerIndex = [int]$light.indexWithinLightIdList
            if (-not $managerIndexes.Add($managerIndex) -or $managerIndex -le $previousManagerIndex) {
                throw "Dump [$Path] slot [$slotId] has duplicate or unordered manager-list index [$managerIndex]."
            }
            $previousManagerIndex = $managerIndex

            # The paired filename is the classifier; redundant flags and fields from the opposite classification are invalid current output.
            foreach ($propertyName in @($alwaysForbiddenProperties + $classificationForbiddenProperties)) {
                if ($null -ne $light.PSObject.Properties[$propertyName]) {
                    throw "Dump [$Path] slot [$slotId] index [$index] unexpectedly contains removed property [$propertyName]."
                }
            }

            # Required class-specific fields remain explicit even when an individual value is null.
            foreach ($propertyName in $classificationRequiredProperties) {
                if ($null -eq $light.PSObject.Properties[$propertyName]) {
                    throw "Dump [$Path] slot [$slotId] index [$index] is missing classification-specific property [$propertyName]."
                }
            }

            # Chroma's component type is required even when its value is null because no LightSwitchEventEffect was found for the slot.
            if ($null -eq $light.PSObject.Properties["type"] -or $null -eq $light.PSObject.Properties["typeName"]) {
                throw "Dump [$Path] slot [$slotId] index [$index] has no type/typeName properties."
            }

            $componentType = [string]$light.componentType
            if (($componentType.StartsWith("RuntimeLightWithIds+", [StringComparison]::Ordinal) -or
                    $componentType.StartsWith("LightmapLightsWithIds+", [StringComparison]::Ordinal)) -and
                ([string]::IsNullOrWhiteSpace([string]$light.ownerGameObjectPath) -or
                    [string]::IsNullOrWhiteSpace([string]$light.ownerComponentType) -or
                    $null -eq $light.indexWithinOwner)) {
                throw "Dump [$Path] slot [$slotId] index [$index] is a nested light without complete owner identity."
            }
        }

        $calculatedTotal += $lights.Count
    }

    if ([int]$dump.totalRegisteredLightCount -ne $calculatedTotal) {
        throw "Dump [$Path] totalRegisteredLightCount does not match the sum of its slots."
    }
}

# Materials captures follow the same freshness rules as the light dumps so a missing or stale third file fails the batch.
function Test-MaterialDumpFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedEnvironment,

        [Parameter(Mandatory)]
        [string]$ExpectedGameVersion,

        [Parameter(Mandatory)]
        [datetime]$StartedAtUtc
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Materials dump file does not exist: $Path"
    }

    $file = Get-Item -LiteralPath $Path
    if ($file.LastWriteTimeUtc -lt $StartedAtUtc.AddSeconds(-2)) {
        throw "Materials dump [$Path] predates this run. File UTC [$($file.LastWriteTimeUtc.ToString('O'))], run UTC [$($StartedAtUtc.ToString('O'))]."
    }

    $dump = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    if ([int]$dump.formatVersion -ne 1) {
        throw "Materials dump [$Path] has formatVersion [$($dump.formatVersion)] instead of [1]."
    }

    if ([string]$dump.environmentName -cne $ExpectedEnvironment) {
        throw "Materials dump [$Path] names environment [$($dump.environmentName)] instead of [$ExpectedEnvironment]."
    }

    if (-not ([string]$dump.gameVersion).StartsWith($ExpectedGameVersion, [StringComparison]::Ordinal)) {
        throw "Materials dump [$Path] reports gameVersion [$($dump.gameVersion)] instead of [$ExpectedGameVersion]."
    }

    $materials = @($dump.materials)
    if ($materials.Count -eq 0) {
        throw "Materials dump [$Path] contains no material entries."
    }

    for ($index = 0; $index -lt $materials.Count; $index++) {
        $material = $materials[$index]
        if ($null -eq $material.PSObject.Properties["instanceId"] -or
            $null -eq $material.PSObject.Properties["renderQueue"] -or
            $null -eq $material.PSObject.Properties["shaderRenderQueue"] -or
            $null -eq $material.PSObject.Properties["customRenderQueue"]) {
            throw "Materials dump [$Path] entry [$index] is missing instanceId/renderQueue fields."
        }
    }
}

# The current run manifest is selected by both version prefix and a post-launch timestamp so old success cannot pass.
function Get-CurrentRunStatusFile {
    param(
        [Parameter(Mandatory)]
        [string]$GameDirectory,

        [Parameter(Mandatory)]
        [string]$GameVersion,

        [Parameter(Mandatory)]
        [datetime]$StartedAtUtc
    )

    $dumpRoot = Join-Path $GameDirectory "UserData\LightIdDumper"
    $candidates = @(
        Get-ChildItem -LiteralPath $dumpRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq $GameVersion -or
                $_.Name.StartsWith("$($GameVersion)_", [StringComparison]::OrdinalIgnoreCase)
            } |
            ForEach-Object { Join-Path $_.FullName "_dump-all-status.json" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Get-Item |
            Where-Object LastWriteTimeUtc -ge $StartedAtUtc.AddSeconds(-2) |
            Sort-Object LastWriteTimeUtc -Descending
    )

    if ($candidates.Count -eq 0) {
        throw "No current dump-all status file was written for Beat Saber [$GameVersion] below [$dumpRoot]."
    }

    return $candidates[0]
}

# Executable-path matching follows the real game even if Steam reparents or replaces the initially returned process.
function Get-BeatSaberProcessesForExecutable {
    param(
        [Parameter(Mandatory)]
        [string]$GameExecutable
    )

    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'Beat Saber.exe'" -ErrorAction SilentlyContinue |
            Where-Object { [string]::Equals($_.ExecutablePath, $GameExecutable, [StringComparison]::OrdinalIgnoreCase) }
    )
}

# Every version has one authoritative live log spelling; the first existing candidate is used for diagnostics.
function Get-BeatSaberLiveLogPath {
    param(
        [Parameter(Mandatory)]
        [string]$GameDirectory
    )

    $candidates = @(
        (Join-Path $GameDirectory "Logs\_latest.log"),
        (Join-Path $GameDirectory "Logs_latest.log")
    )
    return $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

# An empty controller error is supplemented by the earliest fatal platform or dump-all evidence so the originating exception is not hidden by its stack tail.
function Get-IncompleteRunReason {
    param(
        [AllowNull()]
        [string]$ManifestError,

        [AllowNull()]
        [string]$LiveLogPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ManifestError)) {
        return $ManifestError
    }

    if (-not [string]::IsNullOrWhiteSpace($LiveLogPath) -and (Test-Path -LiteralPath $LiveLogPath -PathType Leaf)) {
        $failureLines = @(
            Select-String -LiteralPath $LiveLogPath -Pattern 'Dump-all mode failed|Platform failed to initialize|PlatformRequiresAppRestartException|\[CRITICAL' |
                Select-Object -First 6 |
                ForEach-Object { $_.Line.Trim() }
        )
        if ($failureLines.Count -gt 0) {
            return $failureLines -join ' | '
        }
    }

    return "The game exited before the dump-all controller recorded a failure reason."
}

# Mapping verification runs only where all three repository datasets exist; structural dump validation always runs.
function Invoke-AvailableMappingVerification {
    param(
        [Parameter(Mandatory)]
        [string]$GameVersion,

        [Parameter(Mandatory)]
        [string]$EnvironmentName,

        [Parameter(Mandatory)]
        [string]$RuntimeLightDataPath
    )

    $heckPath = Join-Path $RepoRoot "Heck\Chroma\LightIDTables\$EnvironmentName.json"
    $mapperTablePath = Join-Path $RepoRoot "ChroMapper\Assets\Editor\Environments\LightIDTables\$EnvironmentName.json"
    $mapperDataPath = Join-Path $RepoRoot "ChroMapper\Assets\__Scenes\Environments\Data\$EnvironmentName.json"
    if (-not ((Test-Path -LiteralPath $heckPath) -and
            (Test-Path -LiteralPath $mapperTablePath) -and
            (Test-Path -LiteralPath $mapperDataPath))) {
        return
    }

    $result = & $VerifyScript -GameVersion $GameVersion -EnvironmentName $EnvironmentName -RuntimeLightDataPath $RuntimeLightDataPath -SummaryOnly
    # A mapped fixture classified into OtherLights is a hard verification error because normal Chroma lookup would silently lose it.
    if ([int]$result.ErrorCount -gt 0) {
        throw "[$GameVersion/$EnvironmentName] mapping verification produced [$($result.ErrorCount)] classification error(s)."
    }

    # The CSV-backed verifier counts affected perspective rows, so the deployment warning uses the same precise unit.
    if ([int]$result.WarningCount -gt 0) {
        Write-Warning "[$GameVersion/$EnvironmentName] mapping verification produced [$($result.WarningCount)] warning-flagged CSV row(s); inspect Verify-LightIdMappings.ps1 output."
    }
}

# Build/deploy happens before any launch, and the finally block removes the plugin even after a failed game run.
try {
    foreach ($gameVersion in $VersionsToRun) {
        & $BuildScript -Version $gameVersion -Release
        if ($LASTEXITCODE -ne 0) {
            throw "LightIdDumper build failed for Beat Saber [$gameVersion] with exit code [$LASTEXITCODE]."
        }
    }

    foreach ($gameVersion in $VersionsToRun) {
        $gameDirectory = Get-LightIdDumperBeatSaberDirectory -GameVersion $gameVersion
        if (-not (Test-Path -LiteralPath $gameDirectory -PathType Container)) {
            throw "Beat Saber [$gameVersion] directory is unavailable at [$gameDirectory]."
        }

        $gameExecutable = Join-Path $gameDirectory "Beat Saber.exe"
        if (-not (Test-Path -LiteralPath $gameExecutable -PathType Leaf)) {
            throw "Beat Saber executable not found: $gameExecutable"
        }

        # A pre-existing process is never reused or stopped because it was not created by this batch.
        $existingGameProcesses = @(Get-Process -Name "Beat Saber" -ErrorAction SilentlyContinue)
        if ($existingGameProcesses.Count -gt 0) {
            throw "Beat Saber is already running; close it before starting the automated dump batch."
        }

        # The generated map is present before process start so SongCore indexes one clean donor that reuses the first installed custom song.
        # Requirements ride along only on modern (1.37.1+) installs with both mods actually installed; legacy or
        # partially modded installs keep a vanilla donor because the requirements are unsatisfiable or fragile there.
        $pluginsDirectory = Join-Path $gameDirectory "Plugins"
        $hasChroma = Test-Path -LiteralPath (Join-Path $pluginsDirectory "Chroma.dll") -PathType Leaf
        $hasNoodleExtensions = Test-Path -LiteralPath (Join-Path $pluginsDirectory "NoodleExtensions.dll") -PathType Leaf
        $carryRequirements = ([version]$gameVersion -ge [version]"1.37.1") -and $hasChroma -and $hasNoodleExtensions
        $generatedDonor = New-LightIdDumperGeneratedDonorMap -GameDirectory $gameDirectory -GameVersion $gameVersion -CarryRequirements $carryRequirements
        $GeneratedDonorDirectories.Add($generatedDonor)

        $startedAtUtc = [datetime]::UtcNow
        Write-Host "Starting Beat Saber [$gameVersion] in FPFC dump-all mode..." -ForegroundColor Cyan
        # BSManager's Oculus+FPFC launch uses this argument prefix; the dump flag is the only argument added by this runner.
        $launchArguments = @("--no-yeet", "-vrmode", "oculus", "fpfc", "--dump-all-light-ids")
        if (-not [string]::IsNullOrWhiteSpace($Environment)) {
            # A fresh process per targeted run keeps dynamically-spawned GameCore roots at their first-play indices.
            $launchArguments += "--dump-light-ids-environment=$Environment"
        }
        $printedCommand = '"{0}" {1}' -f $gameExecutable, ($launchArguments -join ' ')
        Write-Host "Command: $printedCommand" -ForegroundColor DarkCyan

        # BSManager identifies direct copies as Beat Saber to Steamworks by injecting all three app-ID variables; without them Steam relaunches the game and prompts for custom arguments.
        $steamEnvironment = [ordered]@{
            SteamAppId = "620980"
            SteamOverlayGameId = "620980"
            SteamGameId = "620980"
        }
        Write-Host "Environment: $((@($steamEnvironment.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })) -join ' ')" -ForegroundColor DarkCyan

        # ProcessStartInfo supplies BSManager's launch environment directly to Beat Saber while ArgumentList preserves each argument without shell re-parsing.
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $gameExecutable
        $startInfo.WorkingDirectory = $gameDirectory
        $startInfo.UseShellExecute = $false
        foreach ($launchArgument in $launchArguments) {
            [void]$startInfo.ArgumentList.Add($launchArgument)
        }
        foreach ($steamVariable in $steamEnvironment.GetEnumerator()) {
            $startInfo.Environment[$steamVariable.Key] = $steamVariable.Value
        }
        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) {
            throw "Beat Saber [$gameVersion] process creation returned no process."
        }

        # Polling the exact executable path survives a short-lived bootstrap PID; the settle delay outlasts Steam's
        # app-instance lock so the next per-version launch does not race Steam into "already running" errors.
        $processExitSettleSeconds = 15
        $deadlineUtc = $startedAtUtc.AddMinutes($TimeoutMinutes)
        $lastGameProcessSeenUtc = [datetime]::UtcNow
        do {
            $matchingGameProcesses = @(Get-BeatSaberProcessesForExecutable -GameExecutable $gameExecutable)
            if ($matchingGameProcesses.Count -gt 0) {
                $lastGameProcessSeenUtc = [datetime]::UtcNow
            }
            elseif (([datetime]::UtcNow - $lastGameProcessSeenUtc).TotalSeconds -ge $processExitSettleSeconds) {
                break
            }

            Start-Sleep -Milliseconds 500
        }
        while ([datetime]::UtcNow -lt $deadlineUtc)

        if ([datetime]::UtcNow -ge $deadlineUtc) {
            # Timeout cleanup is restricted to this version's exact executable path, never an unrelated Beat Saber install.
            $timedOutProcesses = @(Get-BeatSaberProcessesForExecutable -GameExecutable $gameExecutable)
            foreach ($timedOutProcess in $timedOutProcesses) {
                Stop-Process -Id $timedOutProcess.ProcessId -Force
            }

            throw "Beat Saber [$gameVersion] exceeded the [$TimeoutMinutes]-minute dump timeout."
        }

        $liveLog = Get-BeatSaberLiveLogPath -GameDirectory $gameDirectory
        $statusFile = Get-CurrentRunStatusFile -GameDirectory $gameDirectory -GameVersion $gameVersion -StartedAtUtc $startedAtUtc
        $status = Get-Content -LiteralPath $statusFile.FullName -Raw | ConvertFrom-Json -Depth 100
        if ([int]$status.statusFormatVersion -ne 1 -or [int]$status.dumpFormatVersion -ne $ExpectedDumpFormatVersion) {
            throw "Status [$($statusFile.FullName)] does not describe the current dump format."
        }

        if (-not $status.complete) {
            $incompleteReason = Get-IncompleteRunReason -ManifestError ([string]$status.fatalError) -LiveLogPath $liveLog
            throw "Beat Saber [$gameVersion] did not complete dump-all mode: $incompleteReason"
        }

        $environmentResults = @($status.environments)
        $expectedEnvironmentNames = @($status.expectedEnvironmentNames)
        if ($expectedEnvironmentNames.Count -eq 0 -or $environmentResults.Count -ne $expectedEnvironmentNames.Count) {
            throw "Beat Saber [$gameVersion] expected [$($expectedEnvironmentNames.Count)] environments but reported [$($environmentResults.Count)] completed results."
        }

        $completedEnvironmentNames = @($environmentResults | ForEach-Object { [string]$_.environmentName })
        $missingEnvironmentNames = @($expectedEnvironmentNames | Where-Object { $_ -cnotin $completedEnvironmentNames })
        $unexpectedEnvironmentNames = @($completedEnvironmentNames | Where-Object { $_ -cnotin $expectedEnvironmentNames })
        if ($missingEnvironmentNames.Count -gt 0 -or $unexpectedEnvironmentNames.Count -gt 0) {
            throw "Beat Saber [$gameVersion] environment set mismatch. Missing [$($missingEnvironmentNames -join ', ')]; unexpected [$($unexpectedEnvironmentNames -join ', ')]."
        }

        # Repository output contains only durable light data; the transient in-game run manifest remains available solely for validation and diagnostics.
        $versionOutputDirectory = Join-Path $FinalOutputRoot $gameVersion
        $resolvedOutputRoot = [System.IO.Path]::GetFullPath($FinalOutputRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $resolvedVersionOutputDirectory = [System.IO.Path]::GetFullPath($versionOutputDirectory)
        if (-not $resolvedVersionOutputDirectory.StartsWith($resolvedOutputRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Resolved version output [$resolvedVersionOutputDirectory] escapes the requested output root [$resolvedOutputRoot]."
        }

        New-Item -ItemType Directory -Path $versionOutputDirectory -Force | Out-Null
        # Remove prior captures and legacy archived status manifests in this exact version directory so neither removed environments nor transient runner state survive.
        $staleOutputFiles = @(Get-ChildItem -LiteralPath $versionOutputDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "_dump-all-status.json" -or $_.Name -like "*Environment_BehaviorLights.json" -or $_.Name -like "*Environment_OtherLights.json" -or $_.Name -like "*Environment_Materials.json" })
        if (-not [string]::IsNullOrWhiteSpace($Environment)) {
            # A targeted run replaces only the named environment's captures; the rest of the version directory must survive.
            $staleOutputFiles = @($staleOutputFiles | Where-Object {
                if ($_.Name -eq "_dump-all-status.json") {
                    return $true
                }

                foreach ($completedEnvironmentName in $completedEnvironmentNames) {
                    if ($_.Name -like "$completedEnvironmentName`_*Lights.json" -or $_.Name -eq "$completedEnvironmentName`_Materials.json") {
                        return $true
                    }
                }

                return $false
            })
        }
        $staleOutputFiles | Remove-Item -Force
        foreach ($environmentResult in $environmentResults) {
            if (-not $environmentResult.succeeded) {
                throw "Beat Saber [$gameVersion] environment [$($environmentResult.environmentName)] failed: $($environmentResult.error)"
            }

            # Both classification files must be fresh and structurally valid before the environment is considered complete.
            $commonDumpValidationArguments = @{
                ExpectedEnvironment = [string]$environmentResult.environmentName
                ExpectedGameVersion = $gameVersion
                StartedAtUtc = $startedAtUtc
            }
            # The classified filename now drives validation directly; no retired per-light MonoBehaviour flag participates in the format.
            Test-LightIdDumpFile -Path ([string]$environmentResult.behaviorLightsOutputPath) -ExpectedOtherLights $false @commonDumpValidationArguments
            Test-LightIdDumpFile -Path ([string]$environmentResult.otherLightsOutputPath) -ExpectedOtherLights $true @commonDumpValidationArguments
            Test-MaterialDumpFile -Path ([string]$environmentResult.materialsOutputPath) @commonDumpValidationArguments
            Copy-Item -LiteralPath ([string]$environmentResult.behaviorLightsOutputPath) -Destination $versionOutputDirectory -Force
            Copy-Item -LiteralPath ([string]$environmentResult.otherLightsOutputPath) -Destination $versionOutputDirectory -Force
            Copy-Item -LiteralPath ([string]$environmentResult.materialsOutputPath) -Destination $versionOutputDirectory -Force
        }
        # Optional mapping verification reads the collected dataset; mandatory structural validation has already accepted every paired capture above.
        if ($Verify) {
            foreach ($environmentResult in $environmentResults) {
                Invoke-AvailableMappingVerification -GameVersion $gameVersion -EnvironmentName ([string]$environmentResult.environmentName) -RuntimeLightDataPath $FinalOutputRoot
            }
        }

        # The authoritative live log must corroborate plugin startup and successful automatic completion.
        if ($null -eq $liveLog) {
            throw "No authoritative live Beat Saber log was found for [$gameVersion]."
        }

        $liveLogText = Get-Content -LiteralPath $liveLog -Raw
        if (-not $liveLogText.Contains("LightIdDumper enabled", [StringComparison]::Ordinal) -or
            -not $liveLogText.Contains("Dump-all mode completed", [StringComparison]::Ordinal)) {
            throw "Live log [$liveLog] does not corroborate LightIdDumper startup and completion for [$gameVersion]."
        }

        # Remove the version's generated donor before the next shared CustomLevels scan so only one synthetic map can be selected.
        Remove-LightIdDumperGeneratedDonorMap -CustomLevelsRoot ([string]$generatedDonor.CustomLevelsRoot) -GeneratedDirectory ([string]$generatedDonor.GeneratedDirectory)
        Write-Host "Validated and collected [$($environmentResults.Count)] environments for Beat Saber [$gameVersion] at [$versionOutputDirectory]." -ForegroundColor Green
    }
}
catch {
    $RunFailures.Add($_.Exception.Message)
}
finally {
    # A failed or interrupted game run must not leave its generated donor in the shared custom-map library.
    foreach ($generatedDonor in $GeneratedDonorDirectories) {
        try {
            Remove-LightIdDumperGeneratedDonorMap -CustomLevelsRoot ([string]$generatedDonor.CustomLevelsRoot) -GeneratedDirectory ([string]$generatedDonor.GeneratedDirectory)
        }
        catch {
            $RunFailures.Add("Generated donor cleanup failed: $($_.Exception.Message)")
        }
    }

    try {
        & $DeployScript -Version $VersionsToRun -Uninstall
        if ($LASTEXITCODE -ne 0) {
            $RunFailures.Add("LightIdDumper uninstall returned exit code [$LASTEXITCODE].")
        }
    }
    catch {
        $RunFailures.Add("LightIdDumper uninstall failed: $($_.Exception.Message)")
    }
}

# A single terminal failure includes both the run error and any cleanup error after uninstall was attempted.
if ($RunFailures.Count -gt 0) {
    throw ("DumpAllLightIds failed:" + [Environment]::NewLine + ($RunFailures -join [Environment]::NewLine))
}

Write-Host "All requested Beat Saber versions dumped and validated into [$FinalOutputRoot]; LightIdDumper was uninstalled." -ForegroundColor Green
