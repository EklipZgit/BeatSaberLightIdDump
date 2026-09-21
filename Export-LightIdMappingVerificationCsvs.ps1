#Requires -Version 7.0
<#
.SYNOPSIS
Exports LightIdDumper, Heck/Chroma, and ChroMapper mapping comparisons to CSV.

.PARAMETER GameVersion
Beat Saber version, such as 1.44.1. When omitted, every version represented in
the selected RuntimeLightData repository is verified. Installed supported
versions are used only when the repository contains no version directories.

.PARAMETER EnvironmentName
Serialized environment name. When omitted, every captured environment with
Chroma-addressable Basic Event lights is verified.

.PARAMETER RuntimeLightDataPath
Repository-style RuntimeLightData root. Defaults to RuntimeLightData beside this script.

.PARAMETER LightMappingValidationPath
CSV validation root. Defaults to LightMappingValidation beside this script. Four
perspective files are written per selected Basic Event environment.

.PARAMETER SummaryOnly
Collect and summarize every warning category without printing every individual warning.

.PARAMETER FailOnWarning
Exit with code 2 after reporting if any verification warning was found.
#>
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$GameVersion,

    [ValidatePattern('^[^\\/:*?"<>|]+(?:Environment)?$')]
    [string]$EnvironmentName,

    [string]$RuntimeLightDataPath,

    [string]$LightMappingValidationPath,

    [switch]$SummaryOnly,

    [switch]$FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared installation discovery remains the fallback when no repository dataset exists.
. (Join-Path $PSScriptRoot "ScriptCommon.ps1")
if ([string]::IsNullOrWhiteSpace($RuntimeLightDataPath)) {
    $RuntimeLightDataPath = Join-Path $PSScriptRoot "RuntimeLightData"
}
else {
    $RuntimeLightDataPath = [System.IO.Path]::GetFullPath($RuntimeLightDataPath)
}

# Validation CSVs belong beside the checked-in runtime corpus unless the caller explicitly redirects them.
if ([string]::IsNullOrWhiteSpace($LightMappingValidationPath)) {
    $LightMappingValidationPath = Join-Path $PSScriptRoot "LightMappingValidation"
}
else {
    $LightMappingValidationPath = [System.IO.Path]::GetFullPath($LightMappingValidationPath)
}

# Repository directories are authoritative by default, allowing verification without a matching game installation and preventing game-folder captures from shadowing checked-in data.
if ([string]::IsNullOrWhiteSpace($GameVersion)) {
    $repositoryVersions = @(
        if (Test-Path -LiteralPath $RuntimeLightDataPath -PathType Container) {
            Get-ChildItem -LiteralPath $RuntimeLightDataPath -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
                ForEach-Object { $_.Name } |
                Sort-Object { [version]$_ }
        }
    )
    $versionsToVerify = if ($repositoryVersions.Count -gt 0) {
        $repositoryVersions
    }
    else {
        @(Get-LightIdDumperInstalledVersions)
    }

    # Version aggregation delegates to the single-version path so warning/error semantics cannot drift.
    $versionResults = [System.Collections.Generic.List[object]]::new()
    foreach ($selectedVersion in $versionsToVerify) {
        try {
            $childArguments = @{
                GameVersion = $selectedVersion
                RuntimeLightDataPath = $RuntimeLightDataPath
                LightMappingValidationPath = $LightMappingValidationPath
                SummaryOnly = $SummaryOnly
            }
            if (-not [string]::IsNullOrWhiteSpace($EnvironmentName)) {
                $childArguments.EnvironmentName = $EnvironmentName
            }
            $childResult = & $PSCommandPath @childArguments
            foreach ($resultItem in @($childResult)) {
                $versionResults.Add($resultItem)
            }
        }
        catch {
            $message = "[$selectedVersion] verification failed before comparison: $($_.Exception.Message)"
            Write-Error $message -ErrorAction Continue
            $versionResults.Add([pscustomobject]@{
                GameVersion = $selectedVersion
                EnvironmentName = $EnvironmentName
                WarningCount = 0
                ErrorCount = 1
                Warnings = @()
                Errors = @([pscustomobject]@{ Code = "VERSION_VERIFICATION_FAILED"; Message = $message })
            })
        }
    }

    $totalWarnings = [int](($versionResults | Measure-Object WarningCount -Sum).Sum ?? 0)
    $totalErrors = [int](($versionResults | Measure-Object ErrorCount -Sum).Sum ?? 0)
    Write-Host "All-version verification complete: [$($versionResults.Count)] result(s), [$totalWarnings] warning(s), [$totalErrors] error(s)." -ForegroundColor Cyan
    $versionResults
    if ($FailOnWarning -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
        exit 2
    }

    return
}

# These results remain data objects so SummaryOnly can suppress noise without losing any diagnostic category.
$VerificationWarnings = [System.Collections.Generic.List[object]]::new()
$VerificationErrors = [System.Collections.Generic.List[object]]::new()

# Centralized warning creation keeps console and summary output consistent for every missing-side check.
function Add-VerificationWarning {
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $warning = [pscustomobject]@{
        Code = $Code
        Message = $Message
    }
    $VerificationWarnings.Add($warning)
    if (-not $SummaryOnly) {
        Write-Warning "[$Code] $Message"
    }
}

# Classification failures are errors because Chroma-addressable lights in OtherLights are excluded from normal mapping verification.
# Include the active dataset identity in every error because DumpAll can verify many environments in one process.
function Add-VerificationError {
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $errorResult = [pscustomobject]@{
        Code = $Code
        Message = $Message
    }
    $VerificationErrors.Add($errorResult)
    Write-Error "[$GameVersion/$EnvironmentBaseName] [$Code] $Message" -ErrorAction Continue
}

# Safe property access is only for optional fields in the current dump and ChroMapper EnvironmentData.
function Get-JsonPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

# Removing only numeric sibling indexes compares entity names while preserving every hierarchy segment and clone name.
function Get-EntityNamePath {
    param(
        [AllowNull()]
        [string]$GameObjectPath
    )

    if ([string]::IsNullOrWhiteSpace($GameObjectPath)) {
        return $null
    }

    return $GameObjectPath -replace '\[-?\d+\]', '[]'
}

# Leaf names make the directly addressable families visible without hard-coding one environment's fixture names.
function Get-PathLeafName {
    param(
        [AllowNull()]
        [string]$GameObjectPath
    )

    if ([string]::IsNullOrWhiteSpace($GameObjectPath)) {
        return "<non-GameObject>"
    }

    $leaf = ($GameObjectPath -split '\.')[-1]
    return $leaf -replace '^\[-?\d+\]', ''
}

# Runtime and exported names differ for RectangleFakeGlowLightWithId but describe the same serialized component.
function Get-LightComponentTypeIdentity {
    param(
        [AllowNull()]
        [string]$ComponentType
    )

    if ([string]::IsNullOrWhiteSpace($ComponentType)) {
        return $null
    }

    $simpleName = ($ComponentType -split '[.+]')[-1]
    return $simpleName -replace 'WithLightId$', 'WithId'
}

# ChroMapper stores enum names while the dump stores the exact integer accepted by Chroma's ILightWithId component type field.
function Convert-BasicBeatmapEventTypeNameToInt {
    param([AllowNull()][string]$TypeName)

    if ($TypeName -match '^Event(?<Index>\d+)$') {
        return [int]$Matches.Index
    }

    if ($TypeName -match '^Special(?<Index>\d+)$') {
        return 40 + [int]$Matches.Index
    }

    switch ($TypeName) {
        "VoidEvent" { return -1 }
        "BpmChange" { return 100 }
        "NoteJumpMovementSpeedChange" { return 1000 }
    }

    return $null
}

# Nested LightWithIds children are plain C# objects, so their owner supplies the comparable Unity entity path.
function Get-RuntimeEntityPath {
    param([Parameter(Mandatory)][object]$Light)

    $directPath = Get-JsonPropertyValue -InputObject $Light -Name "gameObjectPath"
    if (-not [string]::IsNullOrWhiteSpace($directPath)) {
        return [string]$directPath
    }

    return [string](Get-JsonPropertyValue -InputObject $Light -Name "ownerGameObjectPath")
}

# ChroMapper exports the owning component for nested child lights and the light component itself for MonoBehaviours.
function Get-RuntimeComparableComponentType {
    param([Parameter(Mandatory)][object]$Light)

    $ownerType = Get-JsonPropertyValue -InputObject $Light -Name "ownerComponentType"
    if (-not [string]::IsNullOrWhiteSpace($ownerType)) {
        return [string]$ownerType
    }

    return [string](Get-JsonPropertyValue -InputObject $Light -Name "componentType")
}

# A repository version directory is the sole source when present; game captures are a fallback only for versions absent from RuntimeLightData.
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Shared Feet and RectangleFakeGlow components do not make an otherwise GLS-only environment Chroma-addressable.
function Test-IsSharedPlayerPlatformLight {
    param([Parameter(Mandatory)][object]$Light)

    $componentType = [string](Get-JsonPropertyValue -InputObject $Light -Name "componentType")
    $leafName = Get-PathLeafName -GameObjectPath ([string](Get-JsonPropertyValue -InputObject $Light -Name "gameObjectPath"))
    return ($componentType -ceq "SpriteLightWithId" -and $leafName -ceq "Feet") -or
        ($componentType -ceq "RectangleFakeGlowLightWithId" -and $leafName -ceq "RectangleFakeGlow")
}

# LightSwitchEventEffect is the authoritative Basic Event-to-manager-slot binding exported by ChroMapper.
function Get-LightSwitchSlotIds {
    param([Parameter(Mandatory)][object]$ChroMapperEnvironmentData)

    $slotIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($chroMapperObject in @($ChroMapperEnvironmentData.objects)) {
        $switchEffects = @(Get-JsonPropertyValue -InputObject $chroMapperObject.components -Name "LightSwitchEventEffect" -DefaultValue @())
        foreach ($switchEffect in $switchEffects) {
            $lightsId = Get-JsonPropertyValue -InputObject $switchEffect -Name "lightsId"
            if ($null -ne $lightsId) {
                $null = $slotIds.Add([int]$lightsId)
            }
        }
    }

    # Preserve the HashSet as one object so one-slot environments still expose Count and Contains consistently.
    Write-Output -NoEnumerate $slotIds
}

# Mixed GLS environments such as The Second must be included when any LightSwitch-bound slot owns a real BehaviorLight; mapping tables remain definitive when present.
function Test-EnvironmentHasChromaAddressableBasicLights {
    param(
        [Parameter(Mandatory)][string]$CapturedEnvironmentName,
        [Parameter(Mandatory)][string]$BehaviorDumpPath
    )

    $heckTablePath = Join-Path $RepoRoot "Heck\Chroma\LightIDTables\$CapturedEnvironmentName.json"
    $chroMapperTablePath = Join-Path $RepoRoot "ChroMapper\Assets\Editor\Environments\LightIDTables\$CapturedEnvironmentName.json"
    if ((Test-Path -LiteralPath $heckTablePath -PathType Leaf) -or (Test-Path -LiteralPath $chroMapperTablePath -PathType Leaf)) {
        return $true
    }

    $chroMapperDataPath = Join-Path $RepoRoot "ChroMapper\Assets\__Scenes\Environments\Data\$CapturedEnvironmentName.json"
    # With no authored table or serialized LightSwitch binding, there is no evidence that a captured environment has Chroma-addressable Basic Event lights.
    if (-not (Test-Path -LiteralPath $chroMapperDataPath -PathType Leaf)) {
        return $false
    }

    $chroMapperData = Get-Content -LiteralPath $chroMapperDataPath -Raw | ConvertFrom-Json -Depth 100
    $lightSwitchSlotIds = Get-LightSwitchSlotIds -ChroMapperEnvironmentData $chroMapperData
    if ($lightSwitchSlotIds.Count -eq 0) {
        return $false
    }

    $behaviorDump = Get-Content -LiteralPath $BehaviorDumpPath -Raw | ConvertFrom-Json -Depth 100
    foreach ($slot in @($behaviorDump.lightIdSlots)) {
        if (-not $lightSwitchSlotIds.Contains([int]$slot.beatSaberLightId)) {
            continue
        }

        foreach ($light in @($slot.registeredLights)) {
            if (-not (Test-IsSharedPlayerPlatformLight -Light $light)) {
                return $true
            }
        }
    }

    return $false
}

$RepositoryVersionDirectory = Join-Path $RuntimeLightDataPath $GameVersion
$DumpRoot = $null
if (Test-Path -LiteralPath $RepositoryVersionDirectory -PathType Container) {
    $CaptureDirectories = @(Get-Item -LiteralPath $RepositoryVersionDirectory)
    $CaptureSearchDescription = $RepositoryVersionDirectory
}
else {
    $GameDirectory = Get-LightIdDumperBeatSaberDirectory -GameVersion $GameVersion
    $DumpRoot = Join-Path $GameDirectory "UserData\LightIdDumper"
    $CaptureDirectories = @(
        Get-ChildItem -LiteralPath $DumpRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq $GameVersion -or
                $_.Name.StartsWith("${GameVersion}_", [StringComparison]::OrdinalIgnoreCase)
            }
    )
    $CaptureSearchDescription = $DumpRoot
}

# With no environment filter, verify every paired capture in the newest version/build directory and aggregate failures without stopping at the first environment.
if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $matchingCaptureDirectories = @(
        $CaptureDirectories |
            ForEach-Object {
                $behaviorFiles = @(Get-ChildItem -LiteralPath $_.FullName -Filter "*Environment_BehaviorLights.json" -File -ErrorAction SilentlyContinue)
                if ($behaviorFiles.Count -gt 0) {
                    [pscustomobject]@{
                        Directory = $_
                        NewestWriteTimeUtc = ($behaviorFiles | Measure-Object LastWriteTimeUtc -Maximum).Maximum
                    }
                }
            } |
            Sort-Object NewestWriteTimeUtc -Descending
    )
    if ($matchingCaptureDirectories.Count -eq 0) {
        throw "No BehaviorLights captures found for Beat Saber [$GameVersion] below [$CaptureSearchDescription]."
    }

    $selectedCaptureDirectory = $matchingCaptureDirectories[0].Directory
    $capturedEnvironmentNames = @(
        Get-ChildItem -LiteralPath $selectedCaptureDirectory.FullName -Filter "*Environment_BehaviorLights.json" -File |
            ForEach-Object { $_.Name -replace '_BehaviorLights\.json$', '' } |
            Sort-Object -Unique
    )

    # Runtime and serialized scene evidence includes hybrid GLS/Basic Event environments while excluding only captures without Chroma-addressable BehaviorLights.
    $environmentNames = @(
        $capturedEnvironmentNames |
            Where-Object {
                $behaviorDumpPath = Join-Path $selectedCaptureDirectory.FullName "${_}_BehaviorLights.json"
                Test-EnvironmentHasChromaAddressableBasicLights -CapturedEnvironmentName $_ -BehaviorDumpPath $behaviorDumpPath
            }
    )
    $skippedEnvironmentCount = $capturedEnvironmentNames.Count - $environmentNames.Count
    Write-Host "Verifying [$($environmentNames.Count)] captured environments with Chroma-addressable Basic Event lights from [$($selectedCaptureDirectory.FullName)]; skipping [$skippedEnvironmentCount] environments without them." -ForegroundColor Cyan

    $allResults = [System.Collections.Generic.List[object]]::new()
    foreach ($capturedEnvironmentName in $environmentNames) {
        try {
            # Child invocations use the same single-environment implementation and return structured counts for aggregation.
            $childResult = & $PSCommandPath -GameVersion $GameVersion -EnvironmentName $capturedEnvironmentName -RuntimeLightDataPath $RuntimeLightDataPath -LightMappingValidationPath $LightMappingValidationPath -SummaryOnly:$SummaryOnly
            $allResults.Add($childResult)
        }
        catch {
            $message = "[$GameVersion/$capturedEnvironmentName] verification failed before comparison: $($_.Exception.Message)"
            Write-Error $message -ErrorAction Continue
            $allResults.Add([pscustomobject]@{
                GameVersion = $GameVersion
                EnvironmentName = $capturedEnvironmentName
                WarningCount = 0
                ErrorCount = 1
                Warnings = @()
                Errors = @([pscustomobject]@{ Code = "ENVIRONMENT_VERIFICATION_FAILED"; Message = $message })
            })
        }
    }

    $totalWarnings = [int](($allResults | Measure-Object WarningCount -Sum).Sum ?? 0)
    $totalErrors = [int](($allResults | Measure-Object ErrorCount -Sum).Sum ?? 0)
    Write-Host "All-environment verification complete: [$($allResults.Count)] environments, [$totalWarnings] warning(s), [$totalErrors] error(s)." -ForegroundColor Cyan
    $allResults
    if ($FailOnWarning -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
        exit 2
    }

    return
}

# A game patch may expose its build number in the capture-directory name, so select the newest matching pair for one environment.
$EnvironmentBaseName = [System.IO.Path]::GetFileNameWithoutExtension($EnvironmentName)
$DumpCandidates = @(
    $CaptureDirectories |
        ForEach-Object { Join-Path $_.FullName "${EnvironmentBaseName}_BehaviorLights.json" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Get-Item |
        Sort-Object LastWriteTimeUtc -Descending
)
if ($DumpCandidates.Count -eq 0) {
    throw "No LightIdDumper capture found for Beat Saber [$GameVersion] and environment [$EnvironmentBaseName] below [$CaptureSearchDescription]."
}

if ($DumpCandidates.Count -gt 1) {
    Add-VerificationWarning -Code "MULTIPLE_DUMPS" -Message "Found $($DumpCandidates.Count) matching dumps; using newest [$($DumpCandidates[0].FullName)]."
}

# Heck's right-hand values are runtime inner-list indexes; ChroMapper's are editor reconstruction-list indexes.
$DumpPath = $DumpCandidates[0].FullName
$OtherDumpPath = $DumpPath -replace '_BehaviorLights\.json$', '_OtherLights.json'
$HeckTablePath = Join-Path $RepoRoot "Heck\Chroma\LightIDTables\$EnvironmentBaseName.json"
$ChroMapperTablePath = Join-Path $RepoRoot "ChroMapper\Assets\Editor\Environments\LightIDTables\$EnvironmentBaseName.json"
$ChroMapperDataPath = Join-Path $RepoRoot "ChroMapper\Assets\__Scenes\Environments\Data\$EnvironmentBaseName.json"
# Runtime dumps and EnvironmentData are mandatory, while missing authored mapping tables must remain exportable as explicit coverage gaps.
$RequiredPaths = @($DumpPath, $OtherDumpPath, $ChroMapperDataPath)
foreach ($requiredPath in $RequiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required verification input not found: $requiredPath"
    }
}

# Parse all inputs and reject anything except the current schema before emitting mapping results.
$Dump = Get-Content -LiteralPath $DumpPath -Raw | ConvertFrom-Json -Depth 100
$OtherDump = Get-Content -LiteralPath $OtherDumpPath -Raw | ConvertFrom-Json -Depth 100
$ExpectedDumpFormatVersion = 5
foreach ($classifiedDump in @($Dump, $OtherDump)) {
    if ($null -eq $classifiedDump.PSObject.Properties["formatVersion"] -or [int]$classifiedDump.formatVersion -ne $ExpectedDumpFormatVersion) {
        $actualFormatVersion = Get-JsonPropertyValue -InputObject $classifiedDump -Name "formatVersion" -DefaultValue "missing"
        throw "LightIdDumper formatVersion [$actualFormatVersion] is not current formatVersion [$ExpectedDumpFormatVersion]. Recapture [$EnvironmentBaseName] with the currently deployed dumper."
    }

    # Repository verification rejects nondeterministic capture timestamps so a successful run guarantees stable rerun diffs.
    if ($null -ne $classifiedDump.PSObject.Properties["capturedAtUtc"]) {
        throw "LightIdDumper capture [$EnvironmentBaseName] contains retired capturedAtUtc metadata. Recapture with the currently deployed dumper."
    }
}

# Tableless Basic Event and hybrid environments still need dump/editor perspectives, so empty table objects preserve coverage without inventing mappings.
$HasHeckTable = Test-Path -LiteralPath $HeckTablePath -PathType Leaf
$HasChroMapperTable = Test-Path -LiteralPath $ChroMapperTablePath -PathType Leaf
$HeckTable = if ($HasHeckTable) {
    Get-Content -LiteralPath $HeckTablePath -Raw | ConvertFrom-Json -Depth 100
}
else {
    [pscustomobject]@{}
}
$ChroMapperTable = if ($HasChroMapperTable) {
    Get-Content -LiteralPath $ChroMapperTablePath -Raw | ConvertFrom-Json -Depth 100
}
else {
    [pscustomobject]@{}
}
$ChroMapperData = Get-Content -LiteralPath $ChroMapperDataPath -Raw | ConvertFrom-Json -Depth 100

# Missing source tables are coverage facts, not reasons to suppress an otherwise valid Basic Event environment export.
if (-not $HasHeckTable) {
    Add-VerificationWarning -Code "HECK_LIGHT_ID_TABLE_MISSING" -Message "No authored Heck/Chroma light-ID table exists for Basic Event environment [$EnvironmentBaseName]; Chroma's raw manager-index identity fallback will be exported."
}
if (-not $HasChroMapperTable) {
    Add-VerificationWarning -Code "CHROMAPPER_LIGHT_ID_TABLE_MISSING" -Message "No authored ChroMapper light-ID table exists for Basic Event environment [$EnvironmentBaseName]; its raw editor-index identity fallback will be exported."
}

# ChroMapper's event-track metadata names each semantic lighting group while LightSwitchEventEffect binds it to a manager slot.
$TrackNamesByEventType = @{}
$environmentData = Get-JsonPropertyValue -InputObject $ChroMapperData -Name "environmentData"
$lightTracks = Get-JsonPropertyValue -InputObject $environmentData -Name "lightTracks"
$eventTracks = @(Get-JsonPropertyValue -InputObject $lightTracks -Name "eventTracks" -DefaultValue @())
foreach ($track in $eventTracks) {
    $eventType = [string](Get-JsonPropertyValue -InputObject $track -Name "eventType")
    $trackName = [string](Get-JsonPropertyValue -InputObject $track -Name "trackName")
    if (-not [string]::IsNullOrWhiteSpace($eventType) -and -not [string]::IsNullOrWhiteSpace($trackName)) {
        $TrackNamesByEventType[$eventType] = $trackName
    }
}

$LightGroupNamesById = @{}
$EventTypesByLightId = @{}
foreach ($chroMapperObject in $ChroMapperData.objects) {
    $switchEffects = @(Get-JsonPropertyValue -InputObject $chroMapperObject.components -Name "LightSwitchEventEffect" -DefaultValue @())
    foreach ($switchEffect in $switchEffects) {
        $lightsIdValue = Get-JsonPropertyValue -InputObject $switchEffect -Name "lightsId"
        $eventTypeValue = Get-JsonPropertyValue -InputObject $switchEffect -Name "eventType"
        if ($null -eq $lightsIdValue -or $null -eq $eventTypeValue) {
            continue
        }

        $lightsId = [int]$lightsIdValue
        $eventType = [string]$eventTypeValue
        $eventTypeInteger = Convert-BasicBeatmapEventTypeNameToInt -TypeName $eventType
        if ($EventTypesByLightId.ContainsKey($lightsId) -and $EventTypesByLightId[$lightsId].Name -cne $eventType) {
            Add-VerificationWarning -Code "AMBIGUOUS_LIGHT_EVENT_TYPE" -Message "Beat Saber light ID [$lightsId] is controlled by both [$($EventTypesByLightId[$lightsId].Name)] and [$eventType]."
        }
        elseif (-not $EventTypesByLightId.ContainsKey($lightsId)) {
            $EventTypesByLightId[$lightsId] = [pscustomobject]@{
                Value = $eventTypeInteger
                Name = $eventType
            }
        }

        $groupName = $TrackNamesByEventType[$eventType]
        if ([string]::IsNullOrWhiteSpace($groupName)) {
            $groupName = $eventType
        }

        if ($LightGroupNamesById.ContainsKey($lightsId) -and $LightGroupNamesById[$lightsId] -cne $groupName) {
            Add-VerificationWarning -Code "AMBIGUOUS_LIGHT_GROUP_NAME" -Message "Beat Saber light ID [$lightsId] is bound to both [$($LightGroupNamesById[$lightsId])] and [$groupName]."
            continue
        }

        $LightGroupNamesById[$lightsId] = $groupName
    }
}

# The exported perspectives must contain only Basic Event slots; authored tables extend the set when serialized scene metadata is incomplete.
$BasicLightSlotIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($lightsId in $EventTypesByLightId.Keys) {
    $null = $BasicLightSlotIds.Add([int]$lightsId)
}
foreach ($table in @($HeckTable, $ChroMapperTable)) {
    foreach ($property in $table.PSObject.Properties) {
        $null = $BasicLightSlotIds.Add([int]$property.Name)
    }
}

# Environment identity mismatches make every following index comparison suspect and are reported before table traversal.
if ($Dump.environmentName -cne $EnvironmentBaseName) {
    Add-VerificationWarning -Code "ENVIRONMENT_NAME_MISMATCH" -Message "Dump environment [$($Dump.environmentName)] does not equal requested environment [$EnvironmentBaseName]."
}
if (-not ([string]$Dump.gameVersion).StartsWith($GameVersion, [StringComparison]::Ordinal)) {
    Add-VerificationWarning -Code "GAME_VERSION_MISMATCH" -Message "Dump game version [$($Dump.gameVersion)] does not begin with requested version [$GameVersion]."
}
if ($OtherDump.environmentName -cne $EnvironmentBaseName -or -not ([string]$OtherDump.gameVersion).StartsWith($GameVersion, [StringComparison]::Ordinal)) {
    Add-VerificationError -Code "OTHER_DUMP_IDENTITY_MISMATCH" -Message "OtherLights dump identity [$($OtherDump.environmentName)/$($OtherDump.gameVersion)] does not match [$EnvironmentBaseName/$GameVersion]."
}

# Current-format structural checks reject truncated and internally inconsistent captures before comparing mappings.
$calculatedRuntimeLightCount = 0
$seenDumpSlotIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($slot in $Dump.lightIdSlots) {
    $slotId = [int]$slot.beatSaberLightId
    if (-not $seenDumpSlotIds.Add($slotId)) {
        Add-VerificationWarning -Code "DUPLICATE_DUMP_SLOT" -Message "Dump contains Beat Saber light ID slot [$slotId] more than once."
    }

    $registeredLights = @($slot.registeredLights)
    if ([int]$slot.registeredLightCount -ne $registeredLights.Count) {
        Add-VerificationWarning -Code "DUMP_SLOT_COUNT_MISMATCH" -Message "Beat Saber light ID [$slotId] reports [$($slot.registeredLightCount)] entries but contains [$($registeredLights.Count)]."
    }

    $managerIndexes = [System.Collections.Generic.HashSet[int]]::new()
    $previousManagerIndex = -1
    for ($index = 0; $index -lt $registeredLights.Count; $index++) {
        $managerIndex = [int]$registeredLights[$index].indexWithinLightIdList
        if (-not $managerIndexes.Add($managerIndex) -or $managerIndex -le $previousManagerIndex) {
            Add-VerificationWarning -Code "DUMP_LIST_INDEX_INVALID" -Message "BehaviorLights slot [$slotId] has duplicate or unordered manager-list index [$managerIndex]."
        }
        $previousManagerIndex = $managerIndex

        # The current schema always emits both Chroma component-type fields, including explicit nulls for an unbound slot.
        if ($null -eq $registeredLights[$index].PSObject.Properties["type"] -or $null -eq $registeredLights[$index].PSObject.Properties["typeName"]) {
            throw "LightIdDumper entry [$slotId/$index] has no type/typeName properties. Recapture with the currently deployed dumper."
        }

    }

    # All entries in one manager slot inherit the same LightSwitchEventEffect event type; compare it once to ChroMapper's serialized binding.
    $reportedEventTypes = @(
        $registeredLights |
            ForEach-Object { "$(Get-JsonPropertyValue -InputObject $_ -Name 'type')|$([string](Get-JsonPropertyValue -InputObject $_ -Name 'typeName'))" } |
            Sort-Object -Unique
    )
    if ($reportedEventTypes.Count -gt 1) {
        Add-VerificationWarning -Code "INCONSISTENT_DUMP_LIGHT_EVENT_TYPE" -Message "Beat Saber light ID [$slotId] reports multiple type/typeName pairs: [$($reportedEventTypes -join ', ')]."
    }

    $expectedEventType = $EventTypesByLightId[$slotId]
    if ($registeredLights.Count -gt 0 -and $null -ne $expectedEventType) {
        $reportedType = Get-JsonPropertyValue -InputObject $registeredLights[0] -Name "type"
        $reportedTypeName = [string](Get-JsonPropertyValue -InputObject $registeredLights[0] -Name "typeName")
        if ($null -eq $reportedType -or [int]$reportedType -ne [int]$expectedEventType.Value -or $reportedTypeName -cne [string]$expectedEventType.Name) {
            Add-VerificationWarning -Code "LIGHT_EVENT_TYPE_MISMATCH" -Message "Beat Saber light ID [$slotId] reports type [$reportedType/$reportedTypeName], while ChroMapper binds [$($expectedEventType.Value)/$($expectedEventType.Name)]."
        }
    }

    $calculatedRuntimeLightCount += $registeredLights.Count
}
if ([int]$Dump.totalRegisteredLightCount -ne $calculatedRuntimeLightCount) {
    Add-VerificationWarning -Code "DUMP_TOTAL_COUNT_MISMATCH" -Message "Dump reports [$($Dump.totalRegisteredLightCount)] total entries but its slots contain [$calculatedRuntimeLightCount]."
}

# OtherLights is structurally checked and indexed for classification diagnostics, but never enters ordinary entity or table matching.
$OtherDumpSlotsById = @{}
$OtherLightsBySlotAndIndex = @{}
$calculatedOtherLightCount = 0
# Mixed environments need a second count because only Basic Event OtherLights are emitted and compared.
$basicEventOtherLightCount = 0
foreach ($slot in $OtherDump.lightIdSlots) {
    $slotId = [int]$slot.beatSaberLightId
    if ($OtherDumpSlotsById.ContainsKey($slotId)) {
        Add-VerificationError -Code "DUPLICATE_OTHER_DUMP_SLOT" -Message "OtherLights contains Beat Saber light ID slot [$slotId] more than once."
        continue
    }

    $OtherDumpSlotsById[$slotId] = $slot
    $registeredLights = @($slot.registeredLights)
    if ([int]$slot.registeredLightCount -ne $registeredLights.Count) {
        Add-VerificationError -Code "OTHER_DUMP_SLOT_COUNT_MISMATCH" -Message "OtherLights slot [$slotId] reports [$($slot.registeredLightCount)] entries but contains [$($registeredLights.Count)]."
    }

    $managerIndexes = [System.Collections.Generic.HashSet[int]]::new()
    $previousManagerIndex = -1
    foreach ($light in $registeredLights) {
        $managerIndex = [int]$light.indexWithinLightIdList
        if (-not $managerIndexes.Add($managerIndex) -or $managerIndex -le $previousManagerIndex) {
            Add-VerificationError -Code "OTHER_DUMP_LIST_INDEX_INVALID" -Message "OtherLights slot [$slotId] has duplicate or unordered manager-list index [$managerIndex]."
        }
        $previousManagerIndex = $managerIndex

        if ($null -eq $light.PSObject.Properties["type"] -or $null -eq $light.PSObject.Properties["typeName"]) {
            throw "OtherLights entry [$slotId/$managerIndex] has no type/typeName properties. Recapture with the currently deployed dumper."
        }

        $componentType = [string]$light.componentType
        if (($componentType.StartsWith("RuntimeLightWithIds+", [StringComparison]::Ordinal) -or
                $componentType.StartsWith("LightmapLightsWithIds+", [StringComparison]::Ordinal)) -and
            ([string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue -InputObject $light -Name "ownerGameObjectPath")) -or
                [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue -InputObject $light -Name "ownerComponentType")) -or
                $null -eq (Get-JsonPropertyValue -InputObject $light -Name "indexWithinOwner"))) {
            Add-VerificationWarning -Code "NESTED_LIGHT_OWNER_MISSING" -Message "OtherLights slot [$slotId] manager-list index [$managerIndex] is [$componentType] without complete owner path/type/index identity."
        }

        $OtherLightsBySlotAndIndex["$slotId/$managerIndex"] = $light
    }

    $calculatedOtherLightCount += $registeredLights.Count
    # The result summary reports the same Basic Event OtherLights population emitted to CSV, while the full count above still validates capture integrity.
    if ($BasicLightSlotIds.Contains($slotId)) {
        $basicEventOtherLightCount += $registeredLights.Count
    }
}
if ([int]$OtherDump.totalRegisteredLightCount -ne $calculatedOtherLightCount) {
    Add-VerificationError -Code "OTHER_DUMP_TOTAL_COUNT_MISMATCH" -Message "OtherLights reports [$($OtherDump.totalRegisteredLightCount)] total entries but its slots contain [$calculatedOtherLightCount]."
}

# ChroMapper reconstructs its ordered editor lists from the single serialized LightWithIdManager component.
$ChroMapperManagers = @($ChroMapperData.objects | Where-Object { $null -ne (Get-JsonPropertyValue -InputObject $_.components -Name "LightWithIdManager") })
if ($ChroMapperManagers.Count -ne 1) {
    throw "Expected exactly one ChroMapper LightWithIdManager object, found [$($ChroMapperManagers.Count)]."
}

$ChroMapperManagerComponents = @(Get-JsonPropertyValue -InputObject $ChroMapperManagers[0].components -Name "LightWithIdManager")
$ChroMapperLightsById = Get-JsonPropertyValue -InputObject $ChroMapperManagerComponents[0] -Name "lights"

# Heck resolves an unmapped Chroma lightID with `tableValue ?? id`, so a missing authored table means BehaviorLights use their raw manager indexes as Chroma IDs.
if (-not $HasHeckTable) {
    $identityRuntimeTable = [ordered]@{}
    foreach ($slot in @($Dump.lightIdSlots | Sort-Object { [int]$_.beatSaberLightId })) {
        $slotId = [int]$slot.beatSaberLightId
        if (-not $BasicLightSlotIds.Contains($slotId)) {
            continue
        }

        $identityGroup = [ordered]@{}
        foreach ($light in @($slot.registeredLights | Sort-Object { [int]$_.indexWithinLightIdList })) {
            $managerIndex = [int]$light.indexWithinLightIdList
            $identityGroup[[string]$managerIndex] = $managerIndex
        }

        # Omit empty groups because they have no Chroma-ID source rows and PowerShell strict mode cannot enumerate a propertyless group through the legacy table traversal.
        if ($identityGroup.Count -gt 0) {
            $identityRuntimeTable[[string]$slotId] = [pscustomobject]$identityGroup
        }
    }
    $HeckTable = [pscustomobject]$identityRuntimeTable
}

# ChroMapper likewise uses its raw reconstruction index without a remap table; array wrappers remain OtherLights and are not promoted into the Chroma-ID perspective.
if (-not $HasChroMapperTable) {
    $identityEditorTable = [ordered]@{}
    foreach ($slotProperty in @($ChroMapperLightsById.PSObject.Properties | Sort-Object { [int]$_.Name })) {
        $slotId = [int]$slotProperty.Name
        if (-not $BasicLightSlotIds.Contains($slotId)) {
            continue
        }

        $identityGroup = [ordered]@{}
        $editorLights = @($slotProperty.Value)
        for ($editorIndex = 0; $editorIndex -lt $editorLights.Count; $editorIndex++) {
            if ($null -ne (Get-JsonPropertyValue -InputObject $editorLights[$editorIndex] -Name "arrayId")) {
                continue
            }

            $identityGroup[[string]$editorIndex] = $editorIndex
        }

        # A source perspective needs no row for an empty editor group, and omitting it keeps strict-mode table enumeration valid.
        if ($identityGroup.Count -gt 0) {
            $identityEditorTable[[string]$slotId] = [pscustomobject]$identityGroup
        }
    }
    $ChroMapperTable = [pscustomobject]$identityEditorTable
}

$ChroMapperObjectsById = @{}
foreach ($chroMapperObject in $ChroMapperData.objects) {
    $ChroMapperObjectsById[[string]$chroMapperObject.id] = $chroMapperObject
}

# Fast slot lookup preserves every sparse original manager-list index from BehaviorLights.
$DumpSlotsById = @{}
$RuntimeLightCount = 0
foreach ($slot in $Dump.lightIdSlots) {
    # Convert JSON's Int64 value once so hashtable keys match the Int32 table keys used during lookup.
    $slotLightId = [int]$slot.beatSaberLightId
    # Hybrid environments expose GLS manager slots beside Basic Event slots; only the latter participate in Chroma light-ID verification.
    if (-not $BasicLightSlotIds.Contains($slotLightId)) {
        continue
    }

    if ($DumpSlotsById.ContainsKey($slotLightId)) {
        continue
    }

    $DumpSlotsById[$slotLightId] = $slot
    foreach ($light in $slot.registeredLights) {
        $RuntimeLightCount++

        if ($null -ne $light.componentLightId -and [int]$light.componentLightId -ne $slotLightId) {
            Add-VerificationWarning -Code "COMPONENT_LIGHT_ID_MISMATCH" -Message "Beat Saber light ID [$slotLightId] list index [$($light.indexWithinLightIdList)] contains componentLightId [$($light.componentLightId)]."
        }
    }
}

# Hash sets make the final missing-on-either-side scan independent of table ordering and duplicate target values.
$MappedRuntimeEntries = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$MappedChroMapperEntries = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$ComparedMappingCount = 0
$ExactPathCount = 0
$NameEquivalentPathCount = 0
$MappingsByLightId = @{}
$MappedFixtureFamilies = [System.Collections.Generic.List[object]]::new()
$ReportedOtherMappingKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

# Missing tables must not erase Basic Event source rows, while unrelated GLS slots must not enter the mapping corpus.
$allBeatSaberLightIds = @(
    @($HeckTable.PSObject.Properties | ForEach-Object { $_.Name }) +
    @($ChroMapperTable.PSObject.Properties | ForEach-Object { $_.Name }) +
    @($Dump.lightIdSlots | Where-Object { $BasicLightSlotIds.Contains([int]$_.beatSaberLightId) } | ForEach-Object { [string][int]$_.beatSaberLightId }) +
    @($OtherDump.lightIdSlots | Where-Object { $BasicLightSlotIds.Contains([int]$_.beatSaberLightId) } | ForEach-Object { [string][int]$_.beatSaberLightId }) +
    @($ChroMapperLightsById.PSObject.Properties | Where-Object { $BasicLightSlotIds.Contains([int]$_.Name) } | ForEach-Object { $_.Name })
)
$BeatSaberLightIds = @($allBeatSaberLightIds | Sort-Object { [int]$_ } -Unique)
foreach ($beatSaberLightIdText in $BeatSaberLightIds) {
    $beatSaberLightId = [int]$beatSaberLightIdText
    $heckGroupProperty = $HeckTable.PSObject.Properties[$beatSaberLightIdText]
    $chroMapperGroupProperty = $ChroMapperTable.PSObject.Properties[$beatSaberLightIdText]
    if ($HasHeckTable -and $null -eq $heckGroupProperty) {
        Add-VerificationWarning -Code "LIGHT_ID_SLOT_MISSING_FROM_HECK" -Message "Beat Saber light ID [$beatSaberLightId] exists in ChroMapper's table but not Heck's table."
    }

    if ($HasChroMapperTable -and $null -eq $chroMapperGroupProperty) {
        Add-VerificationWarning -Code "LIGHT_ID_SLOT_MISSING_FROM_CHROMAPPER" -Message "Beat Saber light ID [$beatSaberLightId] exists in Heck's table but not ChroMapper's table."
    }

    $heckGroup = $null -ne $heckGroupProperty ? $heckGroupProperty.Value : $null
    $chroMapperGroup = $null -ne $chroMapperGroupProperty ? $chroMapperGroupProperty.Value : $null
    $heckChromaIds = $null -ne $heckGroup ? @($heckGroup.PSObject.Properties.Name) : @()
    $chroMapperChromaIds = $null -ne $chroMapperGroup ? @($chroMapperGroup.PSObject.Properties.Name) : @()
    $chromaIds = @($heckChromaIds + $chroMapperChromaIds | Sort-Object { [int]$_ } -Unique)

    # Duplicate right-hand indexes alias multiple authored Chroma IDs to one fixture and must be explicit review warnings.
    if ($null -ne $heckGroup) {
        $duplicateHeckIndexes = @($heckGroup.PSObject.Properties | Group-Object { [int]$_.Value } | Where-Object Count -gt 1)
        foreach ($duplicateHeckIndex in $duplicateHeckIndexes) {
            $duplicateChromaIds = @($duplicateHeckIndex.Group.Name) -join ", "
            Add-VerificationWarning -Code "DUPLICATE_HECK_RUNTIME_INDEX" -Message "Beat Saber light ID [$beatSaberLightId] maps Chroma IDs [$duplicateChromaIds] to the same runtime list index [$($duplicateHeckIndex.Name)]."
        }

        # Heck values are authoritative runtime indexes, so any one that resolves only in OtherLights is a classification error even without a matching ChroMapper entry.
        foreach ($heckMapping in $heckGroup.PSObject.Properties) {
            $otherKey = "$beatSaberLightId/$([int]$heckMapping.Value)"
            $otherLight = $OtherLightsBySlotAndIndex[$otherKey]
            if ($null -ne $otherLight -and $ReportedOtherMappingKeys.Add("Heck/$otherKey")) {
                Add-VerificationError -Code "HECK_MAPPING_CLASSIFIED_AS_OTHER_LIGHT" -Message "Heck/Chroma maps Beat Saber light ID [$beatSaberLightId], Chroma ID [$($heckMapping.Name)] to manager index [$($heckMapping.Value)], but that component [$($otherLight.componentType)] is in OtherLights rather than BehaviorLights. Owner: [$($otherLight.ownerGameObjectPath)]."
            }
        }
    }

    if ($null -ne $chroMapperGroup) {
        $duplicateEditorIndexes = @($chroMapperGroup.PSObject.Properties | Group-Object { [int]$_.Value } | Where-Object Count -gt 1)
        foreach ($duplicateEditorIndex in $duplicateEditorIndexes) {
            $duplicateChromaIds = @($duplicateEditorIndex.Group.Name) -join ", "
            Add-VerificationWarning -Code "DUPLICATE_CHROMAPPER_EDITOR_INDEX" -Message "Beat Saber light ID [$beatSaberLightId] maps Chroma IDs [$duplicateChromaIds] to the same ChroMapper editor list index [$($duplicateEditorIndex.Name)]."
        }

        # ChroMapper-only mappings still need classification auditing even when Heck has no corresponding Chroma ID.
        $chroMapperListProperty = $ChroMapperLightsById.PSObject.Properties[$beatSaberLightIdText]
        if ($null -ne $chroMapperListProperty) {
            $chroMapperLights = @($chroMapperListProperty.Value)
            foreach ($chroMapperMapping in $chroMapperGroup.PSObject.Properties) {
                $editorListIndex = [int]$chroMapperMapping.Value
                if ($editorListIndex -ge 0 -and $editorListIndex -lt $chroMapperLights.Count -and
                    $null -ne (Get-JsonPropertyValue -InputObject $chroMapperLights[$editorListIndex] -Name "arrayId")) {
                    $classificationKey = "ChroMapper/$beatSaberLightId/$editorListIndex"
                    if ($ReportedOtherMappingKeys.Add($classificationKey)) {
                        Add-VerificationError -Code "CHROMAPPER_MAPPING_TARGETS_OTHER_LIGHT" -Message "ChroMapper maps Beat Saber light ID [$beatSaberLightId], Chroma ID [$($chroMapperMapping.Name)] to editor index [$editorListIndex], which is an arrayId wrapper belonging in OtherLights."
                    }
                }
            }
        }
    }

    foreach ($chromaIdText in $chromaIds) {
        $chromaId = [int]$chromaIdText
        $heckEntry = $null -ne $heckGroup ? $heckGroup.PSObject.Properties[$chromaIdText] : $null
        $chroMapperEntry = $null -ne $chroMapperGroup ? $chroMapperGroup.PSObject.Properties[$chromaIdText] : $null
        if ($null -eq $heckEntry) {
            Add-VerificationWarning -Code "CHROMA_ID_MISSING_FROM_HECK" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] exists only in ChroMapper's table."
            continue
        }

        if ($null -eq $chroMapperEntry) {
            Add-VerificationWarning -Code "CHROMA_ID_MISSING_FROM_CHROMAPPER" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] exists only in Heck's table."
            continue
        }

        $ComparedMappingCount++
        $MappingsByLightId[$beatSaberLightId] = 1 + [int]($MappingsByLightId[$beatSaberLightId] ?? 0)
        $runtimeListIndex = [int]$heckEntry.Value
        $editorListIndex = [int]$chroMapperEntry.Value
        [void]$MappedRuntimeEntries.Add("$beatSaberLightId/$runtimeListIndex")
        [void]$MappedChroMapperEntries.Add("$beatSaberLightId/$editorListIndex")

        # Heck must resolve to the exact LightWithIdManager._lights[ID][index] entry captured in game.
        $dumpSlot = $DumpSlotsById[$beatSaberLightId]
        if ($null -eq $dumpSlot) {
            if (-not $OtherDumpSlotsById.ContainsKey($beatSaberLightId)) {
                Add-VerificationWarning -Code "HECK_MAPPING_MISSING_GAME_SLOT" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] has no captured game slot in either classified file."
            }
            continue
        }

        $runtimeLight = @($dumpSlot.registeredLights | Where-Object { [int]$_.indexWithinLightIdList -eq $runtimeListIndex }) | Select-Object -First 1
        if ($null -eq $runtimeLight) {
            $otherLight = $OtherLightsBySlotAndIndex["$beatSaberLightId/$runtimeListIndex"]
            if ($null -ne $otherLight) {
                if ($ReportedOtherMappingKeys.Add("Heck/$beatSaberLightId/$runtimeListIndex")) {
                    Add-VerificationError -Code "HECK_MAPPING_CLASSIFIED_AS_OTHER_LIGHT" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] points Heck index [$runtimeListIndex] at OtherLights component [$($otherLight.componentType)] owned by [$($otherLight.ownerGameObjectPath)]."
                }
            }
            else {
                Add-VerificationWarning -Code "HECK_MAPPING_MISSING_GAME_LIGHT" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] points Heck index [$runtimeListIndex] at no captured game light in either classified file."
            }
            continue
        }

        # Family counts prove that combined groups such as Kaleidoscope's spike-top and distant-laser slot retain both populations.
        $runtimeEntityPath = Get-RuntimeEntityPath -Light $runtimeLight
        $MappedFixtureFamilies.Add([pscustomobject]@{
            BeatSaberLightId = $beatSaberLightId
            GroupName = $LightGroupNamesById[$beatSaberLightId] ?? "Unlabelled light ID $beatSaberLightId"
            Family = Get-PathLeafName -GameObjectPath $runtimeEntityPath
        })

        # ChroMapper's value indexes its reconstructed manager list rather than Beat Saber's runtime list.
        $chroMapperListProperty = $ChroMapperLightsById.PSObject.Properties[$beatSaberLightIdText]
        if ($null -eq $chroMapperListProperty) {
            Add-VerificationWarning -Code "CHROMAPPER_MAPPING_MISSING_EDITOR_SLOT" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] has no reconstructed ChroMapper slot."
            continue
        }

        $chroMapperLights = @($chroMapperListProperty.Value)
        if ($editorListIndex -lt 0 -or $editorListIndex -ge $chroMapperLights.Count) {
            Add-VerificationWarning -Code "CHROMAPPER_MAPPING_MISSING_EDITOR_LIGHT" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] points ChroMapper index [$editorListIndex] outside list length [$($chroMapperLights.Count)]."
            continue
        }

        $chroMapperLight = $chroMapperLights[$editorListIndex]
        # ChroMapper's arrayId entries represent non-MonoBehaviour wrappers and must never be authored mapping targets.
        if ($null -ne (Get-JsonPropertyValue -InputObject $chroMapperLight -Name "arrayId")) {
            if ($ReportedOtherMappingKeys.Add("ChroMapper/$beatSaberLightId/$editorListIndex")) {
                Add-VerificationError -Code "CHROMAPPER_MAPPING_TARGETS_OTHER_LIGHT" -Message "ChroMapper maps Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] to editor index [$editorListIndex], which is an arrayId wrapper belonging in OtherLights."
            }
            continue
        }

        $chroMapperObjectId = [string](Get-JsonPropertyValue -InputObject $chroMapperLight -Name "objectId")
        if ([string]::IsNullOrWhiteSpace($runtimeEntityPath) -or [string]::IsNullOrWhiteSpace($chroMapperObjectId)) {
            Add-VerificationWarning -Code "ENTITY_NAME_NOT_COMPARABLE" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] lacks a runtime or ChroMapper GameObject path."
            continue
        }

        if ($runtimeEntityPath -ceq $chroMapperObjectId) {
            $ExactPathCount++
        }
        elseif ((Get-EntityNamePath -GameObjectPath $runtimeEntityPath) -ceq (Get-EntityNamePath -GameObjectPath $chroMapperObjectId)) {
            # Sibling-number drift is expected across asset versions; run-unstable positions are intentionally unavailable as secondary evidence.
            $NameEquivalentPathCount++
        }
        else {
            Add-VerificationWarning -Code "ENTITY_NAME_MISMATCH" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId]: runtime [$runtimeEntityPath] versus ChroMapper [$chroMapperObjectId]."
            continue
        }

        # Component identity remains stable when runtime sibling indexes drift and position data is deliberately omitted.
        $chroMapperObject = $ChroMapperObjectsById[$chroMapperObjectId]
        if ($null -ne $chroMapperObject) {
            $runtimeComparableType = Get-RuntimeComparableComponentType -Light $runtimeLight
            $runtimeComparableTypeIdentity = Get-LightComponentTypeIdentity -ComponentType $runtimeComparableType
            $matchingComponentTypes = @(
                $chroMapperObject.components.PSObject.Properties.Name |
                    Where-Object { (Get-LightComponentTypeIdentity -ComponentType $_) -ceq $runtimeComparableTypeIdentity }
            )
            if ($matchingComponentTypes.Count -eq 0) {
                Add-VerificationWarning -Code "ENTITY_COMPONENT_TYPE_MISMATCH" -Message "Beat Saber light ID [$beatSaberLightId], Chroma ID [$chromaId] resolves to runtime type [$runtimeComparableType], but ChroMapper object [$chroMapperObjectId] does not contain it."
                continue
            }
        }
    }
}

# Direct Chroma targets are representatives; the full inventory pass compares only MonoBehaviour fixtures and deliberately leaves their original list indexes unchanged.
$RuntimePathComponents = [System.Collections.Generic.List[object]]::new()
$RuntimeNonGameObjectComponents = [System.Collections.Generic.List[object]]::new()
foreach ($slot in $Dump.lightIdSlots) {
    $slotLightId = [int]$slot.beatSaberLightId
    # Inventory discrepancies are meaningful only inside the Basic Event slots selected above.
    if (-not $BasicLightSlotIds.Contains($slotLightId)) {
        continue
    }

    foreach ($light in $slot.registeredLights) {
        $runtimeEntityPath = Get-RuntimeEntityPath -Light $light
        $runtimeRecord = [pscustomobject]@{
            BeatSaberLightId = $slotLightId
            Index = [int]$light.indexWithinLightIdList
            Light = $light
            GameObjectPath = $runtimeEntityPath
            EntityPath = Get-EntityNamePath -GameObjectPath $runtimeEntityPath
            ComparableComponentType = Get-RuntimeComparableComponentType -Light $light
        }
        if ([string]::IsNullOrWhiteSpace($runtimeEntityPath)) {
            $RuntimeNonGameObjectComponents.Add($runtimeRecord)
        }
        else {
            $RuntimePathComponents.Add($runtimeRecord)
        }
    }
}

# ChroMapper arrayId entries are non-MonoBehaviour wrappers, so inventory comparison excludes them just like the runtime flag does.
$ChroMapperLightCount = 0
$ExcludedChroMapperNonMonoBehaviourCount = 0
$ChroMapperPathComponents = [System.Collections.Generic.List[object]]::new()
foreach ($chroMapperSlotProperty in $ChroMapperLightsById.PSObject.Properties) {
    $beatSaberLightId = [int]$chroMapperSlotProperty.Name
    # ChroMapper may reconstruct GLS slots in the same manager, but those are outside Chroma light-ID-table verification.
    if (-not $BasicLightSlotIds.Contains($beatSaberLightId)) {
        continue
    }

    $chroMapperLights = @($chroMapperSlotProperty.Value)
    for ($editorListIndex = 0; $editorListIndex -lt $chroMapperLights.Count; $editorListIndex++) {
        $chroMapperLight = $chroMapperLights[$editorListIndex]
        $objectId = [string](Get-JsonPropertyValue -InputObject $chroMapperLight -Name "objectId")
        $arrayId = Get-JsonPropertyValue -InputObject $chroMapperLight -Name "arrayId"
        $editorRecord = [pscustomobject]@{
            BeatSaberLightId = $beatSaberLightId
            Index = $editorListIndex
            Light = $chroMapperLight
            ObjectId = $objectId
            EntityPath = Get-EntityNamePath -GameObjectPath $objectId
            Matched = $false
        }
        if ($null -ne $arrayId) {
            $ExcludedChroMapperNonMonoBehaviourCount++
        }
        else {
            $ChroMapperLightCount++
            $ChroMapperPathComponents.Add($editorRecord)
        }
    }
}

# Regression: runtime positions are nondeterministic, so repeated normalized paths pair exact paths first and otherwise consume remaining ChroMapper entries in stable editor order.
# Bake IDs exist only on the non-MonoBehaviour lightmap wrappers already excluded above, so BehaviorLights matching uses path, component identity, and ordering.
$MatchedPathComponentCount = 0
$MatchedSupportComponentCount = 0
$InventoryChroMapperByRuntimeKey = @{}
$InventoryRuntimeByChroMapperKey = @{}
foreach ($runtimeRecord in $RuntimePathComponents) {
    $candidates = @(
        $ChroMapperPathComponents |
            Where-Object {
                -not $_.Matched -and
                $_.BeatSaberLightId -eq $runtimeRecord.BeatSaberLightId -and
                $_.EntityPath -ceq $runtimeRecord.EntityPath
            }
    )
    if ($candidates.Count -eq 0) {
        Add-VerificationWarning -Code "GAME_COMPONENT_MISSING_FROM_CHROMAPPER" -Message "Beat Saber light ID [$($runtimeRecord.BeatSaberLightId)], runtime index [$($runtimeRecord.Index)], component [$($runtimeRecord.Light.componentType)], path [$($runtimeRecord.GameObjectPath)] has no ChroMapper inventory counterpart."
        continue
    }

    $exactPathCandidates = @($candidates | Where-Object { $_.ObjectId -ceq $runtimeRecord.GameObjectPath })
    $bestMatch = if ($exactPathCandidates.Count -gt 0) {
        $exactPathCandidates | Sort-Object Index | Select-Object -First 1
    }
    else {
        $candidates | Sort-Object Index | Select-Object -First 1
    }

    # When exported object metadata exists, the matching object must carry the same concrete light component type.
    $matchedChroMapperObject = $ChroMapperObjectsById[$bestMatch.ObjectId]
    if ($null -ne $matchedChroMapperObject) {
        $runtimeComponentTypeIdentity = Get-LightComponentTypeIdentity -ComponentType $runtimeRecord.ComparableComponentType
        $matchingComponentTypes = @(
            $matchedChroMapperObject.components.PSObject.Properties.Name |
                Where-Object { (Get-LightComponentTypeIdentity -ComponentType $_) -ceq $runtimeComponentTypeIdentity }
        )
        if ($matchingComponentTypes.Count -eq 0) {
            Add-VerificationWarning -Code "COMPONENT_TYPE_MISMATCH" -Message "Beat Saber light ID [$($runtimeRecord.BeatSaberLightId)], runtime index [$($runtimeRecord.Index)] is owned by [$($runtimeRecord.ComparableComponentType)] but ChroMapper object [$($bestMatch.ObjectId)] does not contain that component type."
            continue
        }
    }

    $bestMatch.Matched = $true
    # Persist the inventory pairing so CSVs can distinguish entity reconstruction from authored Chroma-table targets.
    $runtimeInventoryKey = "$($runtimeRecord.BeatSaberLightId)/$($runtimeRecord.Index)"
    $chroMapperInventoryKey = "$($bestMatch.BeatSaberLightId)/$($bestMatch.Index)"
    $InventoryChroMapperByRuntimeKey[$runtimeInventoryKey] = $bestMatch
    $InventoryRuntimeByChroMapperKey[$chroMapperInventoryKey] = $runtimeRecord
    $MatchedPathComponentCount++
    if (-not $MappedRuntimeEntries.Contains($runtimeInventoryKey)) {
        $MatchedSupportComponentCount++
    }
}

# Any remaining object-backed editor entry is genuinely absent from the runtime capture rather than merely non-addressable by Chroma.
foreach ($editorRecord in $ChroMapperPathComponents) {
    if (-not $editorRecord.Matched) {
        Add-VerificationWarning -Code "CHROMAPPER_COMPONENT_MISSING_FROM_GAME" -Message "Beat Saber light ID [$($editorRecord.BeatSaberLightId)], ChroMapper index [$($editorRecord.Index)], objectId [$($editorRecord.ObjectId)] has no runtime inventory counterpart."
    }
}

# Any owner-less entry reaching this collection is a MonoBehaviour and therefore indicates broken GameObject identity.
foreach ($runtimeRecord in $RuntimeNonGameObjectComponents) {
    Add-VerificationWarning -Code "NON_GAMEOBJECT_COMPONENT_NOT_COMPARABLE" -Message "Beat Saber light ID [$($runtimeRecord.BeatSaberLightId)], runtime index [$($runtimeRecord.Index)], component [$($runtimeRecord.Light.componentType)] has no direct or owner GameObject identity."
}

# CSV cells use stable, unique, semicolon-delimited values so one source light remains one filterable row even when tables alias it.
function Join-ValidationValues {
    param([AllowNull()][object[]]$Values)

    return @(
        $Values |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    ) -join ";"
}

# Table lookup is centralized because both mapping tables use dynamic JSON property names for slots and Chroma IDs.
function Get-LightIdTableGroup {
    param(
        [Parameter(Mandatory)][object]$Table,
        [Parameter(Mandatory)][int]$BeatSaberLightId
    )

    $property = $Table.PSObject.Properties[[string]$BeatSaberLightId]
    # An explicit branch avoids PowerShell parsing `return $null -ne ...` as returning the comparison Boolean.
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

# Reverse target lookup exposes every authored Chroma ID that aliases a manager/editor list index.
function Get-ChromaIdsForTargetIndex {
    param(
        [AllowNull()][object]$Group,
        [Parameter(Mandatory)][int]$TargetIndex
    )

    if ($null -eq $Group) {
        return @()
    }

    return @(
        $Group.PSObject.Properties |
            Where-Object { [int]$_.Value -eq $TargetIndex } |
            ForEach-Object { [int]$_.Name } |
            Sort-Object -Unique
    )
}

# ChroMapper detail resolution preserves invalid indexes as explicit missing-target flags rather than dropping their mappings.
function Get-ChroMapperValidationTarget {
    param(
        [Parameter(Mandatory)][int]$BeatSaberLightId,
        [Parameter(Mandatory)][int]$EditorIndex
    )

    $slotProperty = $ChroMapperLightsById.PSObject.Properties[[string]$BeatSaberLightId]
    if ($null -eq $slotProperty) {
        return [pscustomobject]@{ Exists = $false; Index = $EditorIndex; ObjectId = $null; ArrayId = $null; ComponentTypes = $null }
    }

    $lights = @($slotProperty.Value)
    if ($EditorIndex -lt 0 -or $EditorIndex -ge $lights.Count) {
        return [pscustomobject]@{ Exists = $false; Index = $EditorIndex; ObjectId = $null; ArrayId = $null; ComponentTypes = $null }
    }

    $light = $lights[$EditorIndex]
    $objectId = [string](Get-JsonPropertyValue -InputObject $light -Name "objectId")
    $arrayId = Get-JsonPropertyValue -InputObject $light -Name "arrayId"
    $componentTypes = @()
    $chroMapperObject = $ChroMapperObjectsById[$objectId]
    if ($null -ne $chroMapperObject) {
        $componentTypes = @($chroMapperObject.components.PSObject.Properties.Name | Sort-Object -Unique)
    }

    return [pscustomobject]@{
        Exists = $true
        Index = $EditorIndex
        ObjectId = $objectId
        ArrayId = $arrayId
        ComponentTypes = Join-ValidationValues -Values $componentTypes
    }
}

# Name comparison intentionally ignores only numeric hierarchy indexes, matching the verifier's entity-equivalence rule.
function Test-ValidationEntityNameMatch {
    param(
        [AllowNull()][string]$RuntimePath,
        [AllowNull()][string]$ChroMapperPath
    )

    if ([string]::IsNullOrWhiteSpace($RuntimePath) -or [string]::IsNullOrWhiteSpace($ChroMapperPath)) {
        return $false
    }

    return (Get-EntityNamePath -GameObjectPath $RuntimePath) -ceq (Get-EntityNamePath -GameObjectPath $ChroMapperPath)
}

# Component comparison applies the same serialized/runtime type normalization as the console verifier.
function Test-ValidationComponentTypeMatch {
    param(
        [AllowNull()][string]$RuntimeComponentType,
        [AllowNull()][string]$ChroMapperComponentTypes
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeComponentType) -or [string]::IsNullOrWhiteSpace($ChroMapperComponentTypes)) {
        return $false
    }

    $runtimeIdentity = Get-LightComponentTypeIdentity -ComponentType $RuntimeComponentType
    return @(
        $ChroMapperComponentTypes -split ';' |
            Where-Object { (Get-LightComponentTypeIdentity -ComponentType $_) -ceq $runtimeIdentity }
    ).Count -gt 0
}

# A wide internal join row keeps comparison logic centralized; the CSV exporter later projects it into perspective-specific schemas.
function New-LightMappingValidationRow {
    param([Parameter(Mandatory)][int]$BeatSaberLightId)

    $eventType = $EventTypesByLightId[$BeatSaberLightId]
    return [pscustomobject][ordered]@{
        gameObjectPath = $null
        relativeGameObjectPath = $null
        componentType = $null
        beatSaberLightId = $BeatSaberLightId
        beatSaberIndexInLightIdsList = $null
        componentLightId = $null
        type = $null -ne $eventType ? $eventType.Value : $null
        typeName = $null -ne $eventType ? $eventType.Name : $null
        lightGroupName = [string]($LightGroupNamesById[$BeatSaberLightId] ?? "Unlabelled")
        sceneName = $null
        ownerGameObjectPath = $null
        ownerComponentType = $null
        indexWithinOwner = $null
        isBehaviorLight = $false
        isOtherLight = $false
        isChroMapperArrayWrapper = $false
        chroMapperIndex = $null
        chroMapperName = $null
        chroMapperComponentTypes = $null
        chroMapperArrayId = $null
        chromaComponentIndex = $null
        chromaLightIndex = $null
        mapsToDumpBehavior = $false
        mapsToDumpBehaviorIndex = $null
        mapsToDumpBehaviorPath = $null
        mapsToDumpBehaviorComponentType = $null
        mapsToDumpOther = $false
        mapsToDumpOtherIndex = $null
        mapsToDumpOtherPath = $null
        mapsToDumpOtherComponentType = $null
        mapsToChroMapper = $false
        mapsToChroMapperIndex = $null
        mapsToChroMapperName = $null
        mapsToChroMapperComponentTypes = $null
        mapsToChroMapperArrayWrapper = $false
        tableMapsToChroMapper = $false
        tableChroMapperIndex = $null
        tableChroMapperName = $null
        inventoryMapsToChroMapper = $false
        inventoryChroMapperIndex = $null
        inventoryChroMapperName = $null
        tableMapsToDumpBehavior = $false
        tableDumpBehaviorIndex = $null
        tableDumpBehaviorPath = $null
        inventoryMapsToDumpBehavior = $false
        inventoryDumpBehaviorIndex = $null
        inventoryDumpBehaviorPath = $null
        tableTargetMatchesInventory = $false
        mapsToChroma = $false
        mapsToChromaComponentIndex = $null
        mapsToChromaLightIndex = $null
        anyMapping = $false
        dumpAndChroMapperNameComparable = $false
        chroMapperNameMatches = $false
        dumpAndChroMapperComponentTypeComparable = $false
        chroMapperComponentTypeMatches = $false
        chromaAndChroMapperAgree = $false
        errorMapsToOtherLight = $false
        warningMissingFromDump = $false
        warningMissingFromChroMapperTable = $false
        warningMissingFromChromaTable = $false
        warningMissingChroMapperTarget = $false
        warningNameMismatch = $false
        warningComponentTypeMismatch = $false
        warningComponentLightIdMismatch = $false
        warningDuplicateChromaRuntimeTarget = $false
        warningDuplicateChroMapperTarget = $false
        warningTableTargetDiffersFromInventory = $false
        notMappedByChroma = $false
        notMappedByChroMapper = $false
        anyValidationError = $false
        anyValidationWarning = $false
        validationCodes = $null
    }
}

# Validation codes and aggregate booleans are derived once after each perspective fills its category flags.
function Complete-LightMappingValidationRow {
    param([Parameter(Mandatory)][object]$Row)

    $codes = [System.Collections.Generic.List[string]]::new()
    foreach ($property in $Row.PSObject.Properties) {
        if ($property.Name.StartsWith("error", [StringComparison]::Ordinal) -and $property.Value -eq $true) {
            $codes.Add(($property.Name -creplace '([a-z0-9])([A-Z])', '$1_$2').ToUpperInvariant())
        }
        elseif ($property.Name.StartsWith("warning", [StringComparison]::Ordinal) -and $property.Value -eq $true) {
            $codes.Add(($property.Name -creplace '([a-z0-9])([A-Z])', '$1_$2').ToUpperInvariant())
        }
    }

    $Row.anyValidationError = @($Row.PSObject.Properties | Where-Object { $_.Name.StartsWith("error", [StringComparison]::Ordinal) -and $_.Value -eq $true }).Count -gt 0
    $Row.anyValidationWarning = @($Row.PSObject.Properties | Where-Object { $_.Name.StartsWith("warning", [StringComparison]::Ordinal) -and $_.Value -eq $true }).Count -gt 0
    $Row.validationCodes = Join-ValidationValues -Values @($codes)
    return $Row
}

# Runtime dictionaries make all perspective joins exact in the authoritative manager-list index space.
$BehaviorLightsBySlotAndIndex = @{}
foreach ($slot in $Dump.lightIdSlots) {
    $slotId = [int]$slot.beatSaberLightId
    # Keep cross-perspective joins scoped to the same Basic Event slot set as the emitted CSVs.
    if (-not $BasicLightSlotIds.Contains($slotId)) {
        continue
    }

    foreach ($light in $slot.registeredLights) {
        $BehaviorLightsBySlotAndIndex["$slotId/$([int]$light.indexWithinLightIdList)"] = $light
    }
}

# Dump perspectives retain every exported entry while adding table and ChroMapper cross-links.
function Get-DumpPerspectiveRows {
    param(
        [Parameter(Mandatory)][object]$ClassifiedDump,
        [Parameter(Mandatory)][bool]$IsOther
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($slot in @($ClassifiedDump.lightIdSlots | Sort-Object { [int]$_.beatSaberLightId })) {
        $slotId = [int]$slot.beatSaberLightId
        # A mixed environment's Dump perspectives intentionally omit GLS-only manager slots.
        if (-not $BasicLightSlotIds.Contains($slotId)) {
            continue
        }

        $heckGroup = Get-LightIdTableGroup -Table $HeckTable -BeatSaberLightId $slotId
        $chroMapperGroup = Get-LightIdTableGroup -Table $ChroMapperTable -BeatSaberLightId $slotId
        foreach ($light in @($slot.registeredLights | Sort-Object { [int]$_.indexWithinLightIdList })) {
            $managerIndex = [int]$light.indexWithinLightIdList
            $row = New-LightMappingValidationRow -BeatSaberLightId $slotId
            $row.gameObjectPath = Get-RuntimeEntityPath -Light $light
            $row.relativeGameObjectPath = Get-JsonPropertyValue -InputObject $light -Name "relativeGameObjectPath"
            $row.componentType = [string](Get-JsonPropertyValue -InputObject $light -Name "componentType")
            $row.beatSaberIndexInLightIdsList = $managerIndex
            $row.componentLightId = Get-JsonPropertyValue -InputObject $light -Name "componentLightId"
            $row.type = Get-JsonPropertyValue -InputObject $light -Name "type"
            $row.typeName = Get-JsonPropertyValue -InputObject $light -Name "typeName"
            $row.sceneName = Get-JsonPropertyValue -InputObject $light -Name "sceneName"
            $row.ownerGameObjectPath = Get-JsonPropertyValue -InputObject $light -Name "ownerGameObjectPath"
            $row.ownerComponentType = Get-JsonPropertyValue -InputObject $light -Name "ownerComponentType"
            $row.indexWithinOwner = Get-JsonPropertyValue -InputObject $light -Name "indexWithinOwner"
            $row.isBehaviorLight = -not $IsOther
            $row.isOtherLight = $IsOther

            $chromaIds = @(Get-ChromaIdsForTargetIndex -Group $heckGroup -TargetIndex $managerIndex)
            $row.mapsToChroma = $chromaIds.Count -gt 0
            $row.mapsToChromaComponentIndex = $row.mapsToChroma ? [string]$managerIndex : $null
            $row.mapsToChromaLightIndex = Join-ValidationValues -Values $chromaIds
            $row.chromaComponentIndex = $row.mapsToChromaComponentIndex
            $row.chromaLightIndex = $row.mapsToChromaLightIndex
            $row.notMappedByChroma = -not $row.mapsToChroma

            $chroMapperTargets = [System.Collections.Generic.List[object]]::new()
            $missingChroMapperIds = [System.Collections.Generic.List[int]]::new()
            foreach ($chromaId in $chromaIds) {
                $mappingProperty = $null -ne $chroMapperGroup ? $chroMapperGroup.PSObject.Properties[[string]$chromaId] : $null
                if ($null -eq $mappingProperty) {
                    $missingChroMapperIds.Add($chromaId)
                    continue
                }

                $chroMapperTargets.Add((Get-ChroMapperValidationTarget -BeatSaberLightId $slotId -EditorIndex ([int]$mappingProperty.Value)))
            }

            $existingTargets = @($chroMapperTargets | Where-Object Exists)
            $row.tableMapsToChroMapper = $existingTargets.Count -gt 0
            # Explicit projection remains safe under StrictMode when a source light has no table targets.
            $row.tableChroMapperIndex = Join-ValidationValues -Values @($chroMapperTargets | ForEach-Object { $_.Index })
            $row.tableChroMapperName = Join-ValidationValues -Values @($existingTargets | ForEach-Object { $_.ObjectId })
            $inventoryTarget = $IsOther ? $null : $InventoryChroMapperByRuntimeKey["$slotId/$managerIndex"]
            $inventoryDetail = $null -ne $inventoryTarget ? (Get-ChroMapperValidationTarget -BeatSaberLightId $slotId -EditorIndex $inventoryTarget.Index) : $null
            $row.inventoryMapsToChroMapper = $null -ne $inventoryTarget
            $row.inventoryChroMapperIndex = $null -ne $inventoryTarget ? $inventoryTarget.Index : $null
            $row.inventoryChroMapperName = $null -ne $inventoryTarget ? $inventoryTarget.ObjectId : $null
            $row.mapsToChroMapper = $row.tableMapsToChroMapper -or $row.inventoryMapsToChroMapper
            $row.mapsToChroMapperIndex = Join-ValidationValues -Values (@($chroMapperTargets | ForEach-Object { $_.Index }) + @($row.inventoryChroMapperIndex))
            $row.mapsToChroMapperName = Join-ValidationValues -Values (@($existingTargets | ForEach-Object { $_.ObjectId }) + @($row.inventoryChroMapperName))
            $row.mapsToChroMapperComponentTypes = Join-ValidationValues -Values (@($existingTargets | ForEach-Object { $_.ComponentTypes }) + @($null -ne $inventoryDetail ? $inventoryDetail.ComponentTypes : $null))
            $row.mapsToChroMapperArrayWrapper = @($existingTargets | Where-Object { $null -ne $_.ArrayId }).Count -gt 0
            $row.notMappedByChroMapper = -not $row.mapsToChroMapper
            $row.chromaAndChroMapperAgree = $chromaIds.Count -gt 0 -and $missingChroMapperIds.Count -eq 0
            $row.anyMapping = $row.mapsToChroma -or $row.mapsToChroMapper
            $row.tableTargetMatchesInventory = $row.tableMapsToChroMapper -and $row.inventoryMapsToChroMapper -and @($chroMapperTargets | Where-Object { $_.Index -eq $inventoryTarget.Index }).Count -gt 0

            $comparableNameTargets = @($existingTargets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ObjectId) -and -not [string]::IsNullOrWhiteSpace([string]$row.gameObjectPath) })
            $row.dumpAndChroMapperNameComparable = $comparableNameTargets.Count -gt 0
            $row.chroMapperNameMatches = $row.dumpAndChroMapperNameComparable -and @($comparableNameTargets | Where-Object { -not (Test-ValidationEntityNameMatch -RuntimePath $row.gameObjectPath -ChroMapperPath $_.ObjectId) }).Count -eq 0
            $runtimeComparableType = Get-RuntimeComparableComponentType -Light $light
            $comparableTypeTargets = @($existingTargets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ComponentTypes) -and -not [string]::IsNullOrWhiteSpace($runtimeComparableType) })
            $row.dumpAndChroMapperComponentTypeComparable = $comparableTypeTargets.Count -gt 0
            $row.chroMapperComponentTypeMatches = $row.dumpAndChroMapperComponentTypeComparable -and @($comparableTypeTargets | Where-Object { -not (Test-ValidationComponentTypeMatch -RuntimeComponentType $runtimeComparableType -ChroMapperComponentTypes $_.ComponentTypes) }).Count -eq 0

            $row.errorMapsToOtherLight = $IsOther -and $row.mapsToChroma
            $row.errorMapsToOtherLight = $row.errorMapsToOtherLight -or $row.mapsToChroMapperArrayWrapper
            $row.warningMissingFromChroMapperTable = $missingChroMapperIds.Count -gt 0
            $row.warningMissingChroMapperTarget = @($chroMapperTargets | Where-Object { -not $_.Exists }).Count -gt 0
            $row.warningNameMismatch = $row.dumpAndChroMapperNameComparable -and -not $row.chroMapperNameMatches
            $row.warningComponentTypeMismatch = $row.dumpAndChroMapperComponentTypeComparable -and -not $row.chroMapperComponentTypeMatches
            $row.warningComponentLightIdMismatch = $null -ne $row.componentLightId -and [int]$row.componentLightId -ne $slotId
            $row.warningDuplicateChromaRuntimeTarget = $chromaIds.Count -gt 1
            $row.warningDuplicateChroMapperTarget = @($chroMapperTargets | ForEach-Object { $_.Index } | Group-Object | Where-Object Count -gt 1).Count -gt 0
            $row.warningTableTargetDiffersFromInventory = $row.tableMapsToChroMapper -and $row.inventoryMapsToChroMapper -and -not $row.tableTargetMatchesInventory
            $rows.Add((Complete-LightMappingValidationRow -Row $row))
        }
    }

    return @($rows)
}

# ChroMapper perspective rows cover every reconstructed slot in a selected Basic Event environment, even when its authored mapping table is absent.
function Get-ChroMapperPerspectiveRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($slotIdText in @($BeatSaberLightIds | Sort-Object { [int]$_ })) {
        $slotId = [int]$slotIdText
        $heckGroup = Get-LightIdTableGroup -Table $HeckTable -BeatSaberLightId $slotId
        $chroMapperGroup = Get-LightIdTableGroup -Table $ChroMapperTable -BeatSaberLightId $slotId
        $slotProperty = $ChroMapperLightsById.PSObject.Properties[[string]$slotId]
        if ($null -eq $slotProperty) {
            continue
        }

        $lights = @($slotProperty.Value)
        for ($editorIndex = 0; $editorIndex -lt $lights.Count; $editorIndex++) {
            $target = Get-ChroMapperValidationTarget -BeatSaberLightId $slotId -EditorIndex $editorIndex
            $row = New-LightMappingValidationRow -BeatSaberLightId $slotId
            $row.chroMapperIndex = $editorIndex
            $row.chroMapperName = $target.ObjectId
            $row.chroMapperComponentTypes = $target.ComponentTypes
            $row.chroMapperArrayId = $target.ArrayId
            $row.isChroMapperArrayWrapper = $null -ne $target.ArrayId
            $row.mapsToChroMapper = $true
            $row.mapsToChroMapperIndex = $editorIndex
            $row.mapsToChroMapperName = $target.ObjectId
            $row.mapsToChroMapperComponentTypes = $target.ComponentTypes
            $row.mapsToChroMapperArrayWrapper = $row.isChroMapperArrayWrapper

            $chromaIds = @(Get-ChromaIdsForTargetIndex -Group $chroMapperGroup -TargetIndex $editorIndex)
            $row.mapsToChroma = $chromaIds.Count -gt 0
            $row.mapsToChromaLightIndex = Join-ValidationValues -Values $chromaIds
            $row.chromaLightIndex = $row.mapsToChromaLightIndex
            $row.notMappedByChroma = -not $row.mapsToChroma

            $runtimeIndexes = [System.Collections.Generic.List[int]]::new()
            $missingHeckIds = [System.Collections.Generic.List[int]]::new()
            foreach ($chromaId in $chromaIds) {
                $heckProperty = $null -ne $heckGroup ? $heckGroup.PSObject.Properties[[string]$chromaId] : $null
                if ($null -eq $heckProperty) {
                    $missingHeckIds.Add($chromaId)
                    continue
                }

                $runtimeIndexes.Add([int]$heckProperty.Value)
            }

            $behaviorTargets = @($runtimeIndexes | ForEach-Object { $BehaviorLightsBySlotAndIndex["$slotId/$_"] } | Where-Object { $null -ne $_ })
            $otherTargets = @($runtimeIndexes | ForEach-Object { $OtherLightsBySlotAndIndex["$slotId/$_"] } | Where-Object { $null -ne $_ })
            $row.tableMapsToDumpBehavior = $behaviorTargets.Count -gt 0
            $row.tableDumpBehaviorIndex = Join-ValidationValues -Values @($runtimeIndexes | Where-Object { $null -ne $BehaviorLightsBySlotAndIndex["$slotId/$_"] })
            $row.tableDumpBehaviorPath = Join-ValidationValues -Values @($behaviorTargets | ForEach-Object { Get-RuntimeEntityPath -Light $_ })
            $inventoryRuntimeTarget = $InventoryRuntimeByChroMapperKey["$slotId/$editorIndex"]
            $row.inventoryMapsToDumpBehavior = $null -ne $inventoryRuntimeTarget
            $row.inventoryDumpBehaviorIndex = $null -ne $inventoryRuntimeTarget ? $inventoryRuntimeTarget.Index : $null
            $row.inventoryDumpBehaviorPath = $null -ne $inventoryRuntimeTarget ? $inventoryRuntimeTarget.GameObjectPath : $null
            $row.mapsToDumpBehavior = $row.tableMapsToDumpBehavior -or $row.inventoryMapsToDumpBehavior
            $row.mapsToDumpBehaviorIndex = Join-ValidationValues -Values (@($runtimeIndexes | Where-Object { $null -ne $BehaviorLightsBySlotAndIndex["$slotId/$_"] }) + @($row.inventoryDumpBehaviorIndex))
            $row.mapsToDumpBehaviorPath = Join-ValidationValues -Values (@($behaviorTargets | ForEach-Object { Get-RuntimeEntityPath -Light $_ }) + @($row.inventoryDumpBehaviorPath))
            $row.mapsToDumpBehaviorComponentType = Join-ValidationValues -Values (@($behaviorTargets | ForEach-Object { Get-RuntimeComparableComponentType -Light $_ }) + @($null -ne $inventoryRuntimeTarget ? $inventoryRuntimeTarget.ComparableComponentType : $null))
            $row.mapsToDumpOther = $otherTargets.Count -gt 0
            $row.mapsToDumpOtherIndex = Join-ValidationValues -Values @($runtimeIndexes | Where-Object { $null -ne $OtherLightsBySlotAndIndex["$slotId/$_"] })
            $row.mapsToDumpOtherPath = Join-ValidationValues -Values @($otherTargets | ForEach-Object { Get-RuntimeEntityPath -Light $_ })
            $row.mapsToDumpOtherComponentType = Join-ValidationValues -Values @($otherTargets | ForEach-Object { Get-RuntimeComparableComponentType -Light $_ })
            $row.mapsToChromaComponentIndex = Join-ValidationValues -Values @($runtimeIndexes)
            $row.chromaComponentIndex = $row.mapsToChromaComponentIndex
            $row.anyMapping = $row.mapsToChroma -or $row.mapsToDumpBehavior -or $row.mapsToDumpOther
            $row.chromaAndChroMapperAgree = $chromaIds.Count -gt 0 -and $missingHeckIds.Count -eq 0
            $row.tableTargetMatchesInventory = $row.tableMapsToDumpBehavior -and $row.inventoryMapsToDumpBehavior -and @($runtimeIndexes | Where-Object { $_ -eq $inventoryRuntimeTarget.Index }).Count -gt 0

            $dumpTargets = @($behaviorTargets + $otherTargets + @($null -ne $inventoryRuntimeTarget ? $inventoryRuntimeTarget.Light : $null) | Where-Object { $null -ne $_ })
            $runtimePaths = @($dumpTargets | ForEach-Object { Get-RuntimeEntityPath -Light $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $row.dumpAndChroMapperNameComparable = $runtimePaths.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$target.ObjectId)
            $row.chroMapperNameMatches = $row.dumpAndChroMapperNameComparable -and @($runtimePaths | Where-Object { -not (Test-ValidationEntityNameMatch -RuntimePath $_ -ChroMapperPath $target.ObjectId) }).Count -eq 0
            $runtimeTypes = @($dumpTargets | ForEach-Object { Get-RuntimeComparableComponentType -Light $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $row.dumpAndChroMapperComponentTypeComparable = $runtimeTypes.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$target.ComponentTypes)
            $row.chroMapperComponentTypeMatches = $row.dumpAndChroMapperComponentTypeComparable -and @($runtimeTypes | Where-Object { -not (Test-ValidationComponentTypeMatch -RuntimeComponentType $_ -ChroMapperComponentTypes $target.ComponentTypes) }).Count -eq 0

            $row.errorMapsToOtherLight = $chromaIds.Count -gt 0 -and ($row.isChroMapperArrayWrapper -or $row.mapsToDumpOther)
            $row.warningMissingFromChromaTable = $missingHeckIds.Count -gt 0
            $row.warningMissingFromDump = $runtimeIndexes.Count -gt 0 -and $dumpTargets.Count -eq 0
            $row.warningNameMismatch = $row.dumpAndChroMapperNameComparable -and -not $row.chroMapperNameMatches
            $row.warningComponentTypeMismatch = $row.dumpAndChroMapperComponentTypeComparable -and -not $row.chroMapperComponentTypeMatches
            $row.warningDuplicateChroMapperTarget = $chromaIds.Count -gt 1
            $row.warningDuplicateChromaRuntimeTarget = @($runtimeIndexes | Group-Object | Where-Object Count -gt 1).Count -gt 0
            $row.warningTableTargetDiffersFromInventory = $row.tableMapsToDumpBehavior -and $row.inventoryMapsToDumpBehavior -and -not $row.tableTargetMatchesInventory
            $rows.Add((Complete-LightMappingValidationRow -Row $row))
        }
    }

    return @($rows)
}

# Chroma perspective rows originate only in Heck's Chroma table; ChroMapper-only IDs remain visible in the ChroMapper perspective as missing-from-Chroma warnings.
function Get-ChromaPerspectiveRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($slotIdText in @($BeatSaberLightIds | Sort-Object { [int]$_ })) {
        $slotId = [int]$slotIdText
        $heckGroup = Get-LightIdTableGroup -Table $HeckTable -BeatSaberLightId $slotId
        $chroMapperGroup = Get-LightIdTableGroup -Table $ChroMapperTable -BeatSaberLightId $slotId
        $chromaIds = @(
            # Explicit property projection handles empty dynamic JSON groups under StrictMode.
            @($null -ne $heckGroup ? @($heckGroup.PSObject.Properties | ForEach-Object { $_.Name }) : @()) |
                ForEach-Object { [int]$_ } |
                Sort-Object -Unique
        )
        foreach ($chromaId in $chromaIds) {
            $row = New-LightMappingValidationRow -BeatSaberLightId $slotId
            $row.chromaLightIndex = $chromaId
            $heckProperty = $null -ne $heckGroup ? $heckGroup.PSObject.Properties[[string]$chromaId] : $null
            $chroMapperProperty = $null -ne $chroMapperGroup ? $chroMapperGroup.PSObject.Properties[[string]$chromaId] : $null
            $runtimeIndex = $null -ne $heckProperty ? [int]$heckProperty.Value : $null
            $editorIndex = $null -ne $chroMapperProperty ? [int]$chroMapperProperty.Value : $null
            $row.mapsToChroma = $true
            $row.chromaComponentIndex = $runtimeIndex
            $row.mapsToChromaComponentIndex = $runtimeIndex
            $row.mapsToChromaLightIndex = $chromaId
            $row.mapsToChroMapper = $null -ne $chroMapperProperty
            $row.tableMapsToChroMapper = $row.mapsToChroMapper
            $row.mapsToChroMapperIndex = $editorIndex
            $row.tableChroMapperIndex = $editorIndex
            $row.chroMapperIndex = $editorIndex

            $chroMapperTarget = $null -ne $editorIndex ? (Get-ChroMapperValidationTarget -BeatSaberLightId $slotId -EditorIndex $editorIndex) : $null
            if ($null -ne $chroMapperTarget) {
                $row.chroMapperName = $chroMapperTarget.ObjectId
                $row.chroMapperComponentTypes = $chroMapperTarget.ComponentTypes
                $row.chroMapperArrayId = $chroMapperTarget.ArrayId
                $row.isChroMapperArrayWrapper = $null -ne $chroMapperTarget.ArrayId
                $row.mapsToChroMapperName = $chroMapperTarget.ObjectId
                $row.tableChroMapperName = $chroMapperTarget.ObjectId
                $row.mapsToChroMapperComponentTypes = $chroMapperTarget.ComponentTypes
                $row.mapsToChroMapperArrayWrapper = $row.isChroMapperArrayWrapper
            }

            $behaviorTarget = $null -ne $runtimeIndex ? $BehaviorLightsBySlotAndIndex["$slotId/$runtimeIndex"] : $null
            $otherTarget = $null -ne $runtimeIndex ? $OtherLightsBySlotAndIndex["$slotId/$runtimeIndex"] : $null
            $row.mapsToDumpBehavior = $null -ne $behaviorTarget
            $row.tableMapsToDumpBehavior = $row.mapsToDumpBehavior
            $row.mapsToDumpBehaviorIndex = $row.mapsToDumpBehavior ? $runtimeIndex : $null
            $row.tableDumpBehaviorIndex = $row.mapsToDumpBehaviorIndex
            $row.mapsToDumpBehaviorPath = $row.mapsToDumpBehavior ? (Get-RuntimeEntityPath -Light $behaviorTarget) : $null
            $row.tableDumpBehaviorPath = $row.mapsToDumpBehaviorPath
            $row.mapsToDumpBehaviorComponentType = $row.mapsToDumpBehavior ? (Get-RuntimeComparableComponentType -Light $behaviorTarget) : $null
            $row.mapsToDumpOther = $null -ne $otherTarget
            $row.mapsToDumpOtherIndex = $row.mapsToDumpOther ? $runtimeIndex : $null
            $row.mapsToDumpOtherPath = $row.mapsToDumpOther ? (Get-RuntimeEntityPath -Light $otherTarget) : $null
            $row.mapsToDumpOtherComponentType = $row.mapsToDumpOther ? (Get-RuntimeComparableComponentType -Light $otherTarget) : $null
            $row.anyMapping = $row.mapsToChroma -or $row.mapsToChroMapper -or $row.mapsToDumpBehavior -or $row.mapsToDumpOther
            $row.chromaAndChroMapperAgree = $row.mapsToChroma -and $row.mapsToChroMapper

            # Chroma rows expose whether ChroMapper's reconstructed entity pairs back to the same runtime entry Heck addresses.
            $inventoryRuntimeTarget = $null -ne $editorIndex ? $InventoryRuntimeByChroMapperKey["$slotId/$editorIndex"] : $null
            $row.inventoryMapsToDumpBehavior = $null -ne $inventoryRuntimeTarget
            $row.inventoryDumpBehaviorIndex = $null -ne $inventoryRuntimeTarget ? $inventoryRuntimeTarget.Index : $null
            $row.inventoryDumpBehaviorPath = $null -ne $inventoryRuntimeTarget ? $inventoryRuntimeTarget.GameObjectPath : $null
            $row.tableTargetMatchesInventory = $row.mapsToDumpBehavior -and $row.inventoryMapsToDumpBehavior -and $runtimeIndex -eq $inventoryRuntimeTarget.Index

            $dumpTarget = $null -ne $behaviorTarget ? $behaviorTarget : $otherTarget
            $dumpPath = $null -ne $dumpTarget ? (Get-RuntimeEntityPath -Light $dumpTarget) : $null
            $dumpType = $null -ne $dumpTarget ? (Get-RuntimeComparableComponentType -Light $dumpTarget) : $null
            $row.dumpAndChroMapperNameComparable = $null -ne $chroMapperTarget -and $chroMapperTarget.Exists -and -not [string]::IsNullOrWhiteSpace($dumpPath) -and -not [string]::IsNullOrWhiteSpace([string]$chroMapperTarget.ObjectId)
            $row.chroMapperNameMatches = $row.dumpAndChroMapperNameComparable -and (Test-ValidationEntityNameMatch -RuntimePath $dumpPath -ChroMapperPath $chroMapperTarget.ObjectId)
            $row.dumpAndChroMapperComponentTypeComparable = $null -ne $chroMapperTarget -and $chroMapperTarget.Exists -and -not [string]::IsNullOrWhiteSpace($dumpType) -and -not [string]::IsNullOrWhiteSpace([string]$chroMapperTarget.ComponentTypes)
            $row.chroMapperComponentTypeMatches = $row.dumpAndChroMapperComponentTypeComparable -and (Test-ValidationComponentTypeMatch -RuntimeComponentType $dumpType -ChroMapperComponentTypes $chroMapperTarget.ComponentTypes)

            $row.errorMapsToOtherLight = $row.mapsToDumpOther -or $row.mapsToChroMapperArrayWrapper
            $row.warningMissingFromDump = $row.mapsToChroma -and -not $row.mapsToDumpBehavior -and -not $row.mapsToDumpOther
            $row.warningMissingFromChroMapperTable = -not $row.mapsToChroMapper
            $row.warningMissingChroMapperTarget = $row.mapsToChroMapper -and ($null -eq $chroMapperTarget -or -not $chroMapperTarget.Exists)
            $row.warningNameMismatch = $row.dumpAndChroMapperNameComparable -and -not $row.chroMapperNameMatches
            $row.warningComponentTypeMismatch = $row.dumpAndChroMapperComponentTypeComparable -and -not $row.chroMapperComponentTypeMatches
            $row.warningDuplicateChromaRuntimeTarget = $null -ne $runtimeIndex -and @(Get-ChromaIdsForTargetIndex -Group $heckGroup -TargetIndex $runtimeIndex).Count -gt 1
            $row.warningDuplicateChroMapperTarget = $null -ne $editorIndex -and @(Get-ChromaIdsForTargetIndex -Group $chroMapperGroup -TargetIndex $editorIndex).Count -gt 1
            $row.warningTableTargetDiffersFromInventory = $row.mapsToDumpBehavior -and $row.inventoryMapsToDumpBehavior -and -not $row.tableTargetMatchesInventory
            $row.notMappedByChroMapper = -not $row.mapsToChroMapper
            $rows.Add((Complete-LightMappingValidationRow -Row $row))
        }
    }

    return @($rows)
}

# Each perspective projects only its own source identity, explicitly named target data, and applicable validation categories.
function ConvertTo-LightMappingValidationCsvRow {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][ValidateSet("DumpBehaviorLights", "DumpOtherLights", "ChroMapper", "Chroma")][string]$Perspective
    )

    switch ($Perspective) {
        "DumpBehaviorLights" {
            return [pscustomobject][ordered]@{
                gameObjectPath = $Row.gameObjectPath
                relativeGameObjectPath = $Row.relativeGameObjectPath
                componentType = $Row.componentType
                beatSaberLightId = $Row.beatSaberLightId
                beatSaberIndexInLightIdsList = $Row.beatSaberIndexInLightIdsList
                componentLightId = $Row.componentLightId
                type = $Row.type
                typeName = $Row.typeName
                lightGroupName = $Row.lightGroupName
                sceneName = $Row.sceneName
                mapsToChroma = $Row.mapsToChroma
                mappedChromaLightIds = $Row.mapsToChromaLightIndex
                mappedChromaBeatSaberIndicesInLightIdsList = $Row.mapsToChromaComponentIndex
                mapsToChroMapper = $Row.mapsToChroMapper
                mappedChroMapperIndices = $Row.mapsToChroMapperIndex
                mappedChroMapperGameObjectPaths = $Row.mapsToChroMapperName
                mappedChroMapperComponentTypes = $Row.mapsToChroMapperComponentTypes
                mappedChroMapperTargetsOtherLights = $Row.mapsToChroMapperArrayWrapper
                tableMapsToChroMapper = $Row.tableMapsToChroMapper
                tableMappedChroMapperIndices = $Row.tableChroMapperIndex
                tableMappedChroMapperGameObjectPaths = $Row.tableChroMapperName
                inventoryMapsToChroMapper = $Row.inventoryMapsToChroMapper
                inventoryMappedChroMapperIndex = $Row.inventoryChroMapperIndex
                inventoryMappedChroMapperGameObjectPath = $Row.inventoryChroMapperName
                tableMappedChroMapperTargetMatchesInventory = $Row.tableTargetMatchesInventory
                dumpBehaviorAndChroMapperNameComparable = $Row.dumpAndChroMapperNameComparable
                mappedChroMapperNameMatchesDumpBehavior = $Row.chroMapperNameMatches
                dumpBehaviorAndChroMapperComponentTypeComparable = $Row.dumpAndChroMapperComponentTypeComparable
                mappedChroMapperComponentTypeMatchesDumpBehavior = $Row.chroMapperComponentTypeMatches
                chromaAndChroMapperAgree = $Row.chromaAndChroMapperAgree
                anyMapping = $Row.anyMapping
                errorMapsToOtherLight = $Row.errorMapsToOtherLight
                warningMissingFromChroMapperTable = $Row.warningMissingFromChroMapperTable
                warningMissingChroMapperTarget = $Row.warningMissingChroMapperTarget
                warningNameMismatch = $Row.warningNameMismatch
                warningComponentTypeMismatch = $Row.warningComponentTypeMismatch
                warningComponentLightIdMismatch = $Row.warningComponentLightIdMismatch
                warningDuplicateChromaRuntimeTarget = $Row.warningDuplicateChromaRuntimeTarget
                warningDuplicateChroMapperTarget = $Row.warningDuplicateChroMapperTarget
                warningTableTargetDiffersFromInventory = $Row.warningTableTargetDiffersFromInventory
                notMappedByChroma = $Row.notMappedByChroma
                notMappedByChroMapper = $Row.notMappedByChroMapper
                anyValidationError = $Row.anyValidationError
                anyValidationWarning = $Row.anyValidationWarning
                validationCodes = $Row.validationCodes
            }
        }

        "DumpOtherLights" {
            return [pscustomobject][ordered]@{
                ownerGameObjectPath = $Row.ownerGameObjectPath
                ownerComponentType = $Row.ownerComponentType
                indexWithinOwner = $Row.indexWithinOwner
                relativeGameObjectPath = $Row.relativeGameObjectPath
                componentType = $Row.componentType
                beatSaberLightId = $Row.beatSaberLightId
                beatSaberIndexInLightIdsList = $Row.beatSaberIndexInLightIdsList
                componentLightId = $Row.componentLightId
                type = $Row.type
                typeName = $Row.typeName
                lightGroupName = $Row.lightGroupName
                mapsToChroma = $Row.mapsToChroma
                mappedChromaLightIds = $Row.mapsToChromaLightIndex
                mappedChromaBeatSaberIndicesInLightIdsList = $Row.mapsToChromaComponentIndex
                mapsToChroMapper = $Row.mapsToChroMapper
                mappedChroMapperIndices = $Row.mapsToChroMapperIndex
                mappedChroMapperGameObjectPaths = $Row.mapsToChroMapperName
                mappedChroMapperComponentTypes = $Row.mapsToChroMapperComponentTypes
                mappedChroMapperTargetsOtherLights = $Row.mapsToChroMapperArrayWrapper
                tableMapsToChroMapper = $Row.tableMapsToChroMapper
                tableMappedChroMapperIndices = $Row.tableChroMapperIndex
                tableMappedChroMapperGameObjectPaths = $Row.tableChroMapperName
                chromaAndChroMapperAgree = $Row.chromaAndChroMapperAgree
                anyMapping = $Row.anyMapping
                ownerAndChroMapperNameComparable = $Row.dumpAndChroMapperNameComparable
                mappedChroMapperNameMatchesOwner = $Row.chroMapperNameMatches
                ownerAndChroMapperComponentTypeComparable = $Row.dumpAndChroMapperComponentTypeComparable
                mappedChroMapperComponentTypeMatchesOwner = $Row.chroMapperComponentTypeMatches
                errorMapsToOtherLight = $Row.errorMapsToOtherLight
                warningMissingFromChroMapperTable = $Row.warningMissingFromChroMapperTable
                warningMissingChroMapperTarget = $Row.warningMissingChroMapperTarget
                warningNameMismatch = $Row.warningNameMismatch
                warningComponentTypeMismatch = $Row.warningComponentTypeMismatch
                warningComponentLightIdMismatch = $Row.warningComponentLightIdMismatch
                warningDuplicateChromaRuntimeTarget = $Row.warningDuplicateChromaRuntimeTarget
                warningDuplicateChroMapperTarget = $Row.warningDuplicateChroMapperTarget
                notMappedByChroma = $Row.notMappedByChroma
                notMappedByChroMapper = $Row.notMappedByChroMapper
                anyValidationError = $Row.anyValidationError
                anyValidationWarning = $Row.anyValidationWarning
                validationCodes = $Row.validationCodes
            }
        }

        "ChroMapper" {
            return [pscustomobject][ordered]@{
                chroMapperGameObjectPath = $Row.chroMapperName
                chroMapperComponentTypes = $Row.chroMapperComponentTypes
                beatSaberLightId = $Row.beatSaberLightId
                chroMapperIndex = $Row.chroMapperIndex
                chroMapperArrayId = $Row.chroMapperArrayId
                isChroMapperArrayWrapper = $Row.isChroMapperArrayWrapper
                type = $Row.type
                typeName = $Row.typeName
                lightGroupName = $Row.lightGroupName
                mapsToChroma = $Row.mapsToChroma
                mappedChromaLightIds = $Row.mapsToChromaLightIndex
                mappedChromaBeatSaberIndicesInLightIdsList = $Row.mapsToChromaComponentIndex
                mapsToDumpBehaviorLights = $Row.mapsToDumpBehavior
                mappedDumpBehaviorBeatSaberIndicesInLightIdsList = $Row.mapsToDumpBehaviorIndex
                mappedDumpBehaviorGameObjectPaths = $Row.mapsToDumpBehaviorPath
                mappedDumpBehaviorComponentTypes = $Row.mapsToDumpBehaviorComponentType
                tableMapsToDumpBehaviorLights = $Row.tableMapsToDumpBehavior
                tableMappedDumpBehaviorBeatSaberIndicesInLightIdsList = $Row.tableDumpBehaviorIndex
                tableMappedDumpBehaviorGameObjectPaths = $Row.tableDumpBehaviorPath
                inventoryMapsToDumpBehaviorLights = $Row.inventoryMapsToDumpBehavior
                inventoryMappedDumpBehaviorBeatSaberIndexInLightIdsList = $Row.inventoryDumpBehaviorIndex
                inventoryMappedDumpBehaviorGameObjectPath = $Row.inventoryDumpBehaviorPath
                mapsToDumpOtherLights = $Row.mapsToDumpOther
                mappedDumpOtherBeatSaberIndicesInLightIdsList = $Row.mapsToDumpOtherIndex
                mappedDumpOtherOwnerGameObjectPaths = $Row.mapsToDumpOtherPath
                mappedDumpOtherOwnerComponentTypes = $Row.mapsToDumpOtherComponentType
                tableMappedDumpBehaviorTargetMatchesInventory = $Row.tableTargetMatchesInventory
                dumpAndChroMapperNameComparable = $Row.dumpAndChroMapperNameComparable
                chroMapperNameMatchesMappedDump = $Row.chroMapperNameMatches
                dumpAndChroMapperComponentTypeComparable = $Row.dumpAndChroMapperComponentTypeComparable
                chroMapperComponentTypeMatchesMappedDump = $Row.chroMapperComponentTypeMatches
                chromaAndChroMapperAgree = $Row.chromaAndChroMapperAgree
                anyMapping = $Row.anyMapping
                errorMapsToOtherLight = $Row.errorMapsToOtherLight
                warningMissingFromDump = $Row.warningMissingFromDump
                warningMissingFromChromaTable = $Row.warningMissingFromChromaTable
                warningNameMismatch = $Row.warningNameMismatch
                warningComponentTypeMismatch = $Row.warningComponentTypeMismatch
                warningDuplicateChromaRuntimeTarget = $Row.warningDuplicateChromaRuntimeTarget
                warningDuplicateChroMapperTarget = $Row.warningDuplicateChroMapperTarget
                warningTableTargetDiffersFromInventory = $Row.warningTableTargetDiffersFromInventory
                notMappedByChroma = $Row.notMappedByChroma
                anyValidationError = $Row.anyValidationError
                anyValidationWarning = $Row.anyValidationWarning
                validationCodes = $Row.validationCodes
            }
        }

        "Chroma" {
            return [pscustomobject][ordered]@{
                chromaLightId = $Row.chromaLightIndex
                beatSaberLightId = $Row.beatSaberLightId
                lightGroupName = $Row.lightGroupName
                type = $Row.type
                typeName = $Row.typeName
                chromaTableBeatSaberIndexInLightIdsList = $Row.chromaComponentIndex
                existsInChroMapperTable = $Row.mapsToChroMapper
                mappedChroMapperIndex = $Row.mapsToChroMapperIndex
                mappedChroMapperGameObjectPath = $Row.mapsToChroMapperName
                mappedChroMapperComponentTypes = $Row.mapsToChroMapperComponentTypes
                mappedChroMapperTargetsOtherLight = $Row.mapsToChroMapperArrayWrapper
                mapsToDumpBehaviorLights = $Row.mapsToDumpBehavior
                mappedDumpBehaviorBeatSaberIndexInLightIdsList = $Row.mapsToDumpBehaviorIndex
                mappedDumpBehaviorGameObjectPath = $Row.mapsToDumpBehaviorPath
                mappedDumpBehaviorComponentType = $Row.mapsToDumpBehaviorComponentType
                mapsToDumpOtherLights = $Row.mapsToDumpOther
                mappedDumpOtherBeatSaberIndexInLightIdsList = $Row.mapsToDumpOtherIndex
                mappedDumpOtherOwnerGameObjectPath = $Row.mapsToDumpOtherPath
                mappedDumpOtherOwnerComponentType = $Row.mapsToDumpOtherComponentType
                inventoryMapsToDumpBehaviorLights = $Row.inventoryMapsToDumpBehavior
                inventoryMappedDumpBehaviorBeatSaberIndexInLightIdsList = $Row.inventoryDumpBehaviorIndex
                inventoryMappedDumpBehaviorGameObjectPath = $Row.inventoryDumpBehaviorPath
                tableMappedDumpBehaviorTargetMatchesInventory = $Row.tableTargetMatchesInventory
                mappedDumpAndChroMapperNameComparable = $Row.dumpAndChroMapperNameComparable
                mappedChroMapperNameMatchesMappedDump = $Row.chroMapperNameMatches
                mappedDumpAndChroMapperComponentTypeComparable = $Row.dumpAndChroMapperComponentTypeComparable
                mappedChroMapperComponentTypeMatchesMappedDump = $Row.chroMapperComponentTypeMatches
                errorMapsToOtherLight = $Row.errorMapsToOtherLight
                warningMissingFromDump = $Row.warningMissingFromDump
                warningMissingFromChroMapperTable = $Row.warningMissingFromChroMapperTable
                warningMissingChroMapperTarget = $Row.warningMissingChroMapperTarget
                warningNameMismatch = $Row.warningNameMismatch
                warningComponentTypeMismatch = $Row.warningComponentTypeMismatch
                warningDuplicateChromaRuntimeTarget = $Row.warningDuplicateChromaRuntimeTarget
                warningDuplicateChroMapperTarget = $Row.warningDuplicateChroMapperTarget
                warningTableTargetDiffersFromInventory = $Row.warningTableTargetDiffersFromInventory
                anyValidationError = $Row.anyValidationError
                anyValidationWarning = $Row.anyValidationWarning
                validationCodes = $Row.validationCodes
            }
        }
    }
}

# A perspective with no source rows still requires its schema header so every selected environment preserves the four-file contract.
function Export-LightMappingValidationCsv {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet("DumpBehaviorLights", "DumpOtherLights", "ChroMapper", "Chroma")][string]$Perspective,
        [AllowEmptyCollection()][object[]]$Rows
    )

    $projectedRows = @($Rows | ForEach-Object { ConvertTo-LightMappingValidationCsvRow -Row $_ -Perspective $Perspective })
    if ($projectedRows.Count -gt 0) {
        $projectedRows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
        return
    }

    $prototype = ConvertTo-LightMappingValidationCsvRow -Row (New-LightMappingValidationRow -BeatSaberLightId 0) -Perspective $Perspective
    $columnNames = $prototype.PSObject.Properties.Name
    # Header-only files preserve the same declared column order as populated perspectives.
    $header = @($columnNames | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ','
    Set-Content -LiteralPath $Path -Value $header -Encoding utf8
}

# Generate all four requested source perspectives beneath a version/environment directory on every successful comparison.
$ValidationEnvironmentDirectory = Join-Path (Join-Path $LightMappingValidationPath $GameVersion) $EnvironmentBaseName
New-Item -ItemType Directory -Path $ValidationEnvironmentDirectory -Force | Out-Null
$DumpBehaviorRows = @(Get-DumpPerspectiveRows -ClassifiedDump $Dump -IsOther $false)
$DumpOtherRows = @(Get-DumpPerspectiveRows -ClassifiedDump $OtherDump -IsOther $true)
$ChroMapperRows = @(Get-ChroMapperPerspectiveRows)
$ChromaRows = @(Get-ChromaPerspectiveRows)
$ValidationFilePrefix = "${GameVersion}_${EnvironmentBaseName}"
Export-LightMappingValidationCsv -Path (Join-Path $ValidationEnvironmentDirectory "${ValidationFilePrefix}_DumpBehaviorLights.csv") -Perspective "DumpBehaviorLights" -Rows $DumpBehaviorRows
Export-LightMappingValidationCsv -Path (Join-Path $ValidationEnvironmentDirectory "${ValidationFilePrefix}_DumpOtherLights.csv") -Perspective "DumpOtherLights" -Rows $DumpOtherRows
Export-LightMappingValidationCsv -Path (Join-Path $ValidationEnvironmentDirectory "${ValidationFilePrefix}_ChroMapper.csv") -Perspective "ChroMapper" -Rows $ChroMapperRows
Export-LightMappingValidationCsv -Path (Join-Path $ValidationEnvironmentDirectory "${ValidationFilePrefix}_Chroma.csv") -Perspective "Chroma" -Rows $ChromaRows

# Legacy generic names duplicate the new self-identifying files and must not remain in the canonical baseline.
foreach ($legacyFileName in @("DumpBehaviorLights.csv", "DumpOtherLights.csv", "ChroMapper.csv", "Chroma.csv")) {
    $legacyPath = Join-Path $ValidationEnvironmentDirectory $legacyFileName
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
        Remove-Item -LiteralPath $legacyPath -Force
    }
}
Write-Host "Validation CSVs: $ValidationEnvironmentDirectory" -ForegroundColor DarkCyan

# Per-slot summaries preserve the semantic event interpretation while excluding unrelated GLS slots in hybrid environments.
$GroupSummaries = foreach ($slot in @($Dump.lightIdSlots | Where-Object { $BasicLightSlotIds.Contains([int]$_.beatSaberLightId) })) {
    $slotLightId = [int]$slot.beatSaberLightId
    # Semantic summaries count only mapping-comparable MonoBehaviour fixtures.
    # BehaviorLights is already the complete MonoBehaviour set, so its named file replaces the removed per-record discriminator.
    $behaviorLights = @($slot.registeredLights)
    $directComponentCount = @($behaviorLights | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.gameObjectPath) }).Count

    # Owner-backed wrappers live exclusively in OtherLights now, so a BehaviorLights slot cannot contain nested-owner children.
    $ownerComponentCount = 0
    [pscustomobject]@{
        BeatSaberLightId = $slotLightId
        LightGroup = $LightGroupNamesById[$slotLightId] ?? "Unlabelled"
        ChromaFixtures = [int]($MappingsByLightId[$slotLightId] ?? 0)
        DirectComponents = $directComponentCount
        NestedOwnerChildren = $ownerComponentCount
        UnidentifiedEntries = $behaviorLights.Count - $directComponentCount - $ownerComponentCount
    }
}

# Family summaries expose mixed semantic groups such as spike-top lights plus distant BigCone lasers.
$FixtureFamilySummaries = @(
    $MappedFixtureFamilies |
        Group-Object BeatSaberLightId, GroupName, Family |
        ForEach-Object {
            [pscustomobject]@{
                BeatSaberLightId = $_.Group[0].BeatSaberLightId
                LightGroup = $_.Group[0].GroupName
                AddressableFamily = $_.Group[0].Family
                Count = $_.Count
            }
        } |
        Sort-Object BeatSaberLightId, AddressableFamily
)

# A compact category table makes large expected unmapped-light sets reviewable after individual diagnostics.
Write-Host ""
Write-Host "=== Light ID mapping verification ===" -ForegroundColor Cyan
Write-Host "BehaviorLights dump: $DumpPath"
Write-Host "OtherLights dump: $OtherDumpPath"
# Tableless Basic Event environments must identify the absent input clearly instead of printing a path that appears to have loaded successfully.
Write-Host "Heck table: $($HasHeckTable ? $HeckTablePath : "$HeckTablePath (missing)")"
Write-Host "ChroMapper table: $($HasChroMapperTable ? $ChroMapperTablePath : "$ChroMapperTablePath (missing)")"
Write-Host "ChroMapper data: $ChroMapperDataPath"
Write-Host "Mappings compared: $ComparedMappingCount"
Write-Host "Behavior lights: $RuntimeLightCount"
Write-Host "Basic Event OtherLights checked for classification conflicts: $basicEventOtherLightCount"
Write-Host "ChroMapper reconstructed lights: $ChroMapperLightCount"
Write-Host "Excluded ChroMapper arrayId entries: $ExcludedChroMapperNonMonoBehaviourCount"
Write-Host "Matched GameObject-backed components: $MatchedPathComponentCount"
Write-Host "Matched non-addressable renderer companions: $MatchedSupportComponentCount"
Write-Host "Exact entity paths: $ExactPathCount"
Write-Host "Entity-name-equivalent paths with sibling-index drift: $NameEquivalentPathCount"
Write-Host "Errors: $($VerificationErrors.Count)"
if ($VerificationErrors.Count -gt 0) {
    # Error categories remain prominent even when individual messages were already emitted during traversal.
    $errorSummary = $VerificationErrors |
        Group-Object Code |
        Sort-Object Name |
        Select-Object @{ Name = "ErrorCode"; Expression = { $_.Name } }, Count |
        Format-Table -AutoSize |
        Out-String
    Write-Host $errorSummary.TrimEnd() -ForegroundColor Red
}

Write-Host "Warnings: $($VerificationWarnings.Count)"
if ($VerificationWarnings.Count -gt 0) {
    # Materializing formatted output keeps warning and semantic-summary headings in deterministic console order.
    $warningSummary = $VerificationWarnings |
        Group-Object Code |
        Sort-Object Name |
        Select-Object @{ Name = "WarningCode"; Expression = { $_.Name } }, Count |
        Format-Table -AutoSize |
        Out-String
    Write-Host $warningSummary.TrimEnd()
}
elseif ($VerificationErrors.Count -eq 0) {
    Write-Host "All mappings and entities agree." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Semantic light groups ===" -ForegroundColor Cyan
Write-Host (($GroupSummaries | Format-Table -AutoSize | Out-String).TrimEnd())
Write-Host "=== Directly addressable fixture families ===" -ForegroundColor Cyan
Write-Host (($FixtureFamilySummaries | Format-Table -AutoSize | Out-String).TrimEnd())

# The returned object supports automation while the optional exit code preserves interactive diagnostic use by default.
$Result = [pscustomobject]@{
    GameVersion = $GameVersion
    EnvironmentName = $EnvironmentBaseName
    DumpFormatVersion = $Dump.formatVersion
    # The wrapper needs authored-source coverage separately because derived identity rows must not masquerade as a checked-in remap table.
    HasHeckTable = $HasHeckTable
    HasChroMapperTable = $HasChroMapperTable
    MappingCount = $ComparedMappingCount
    RuntimeLightCount = $RuntimeLightCount
    OtherLightCount = $basicEventOtherLightCount
    ChroMapperLightCount = $ChroMapperLightCount
    ExcludedChroMapperNonMonoBehaviourCount = $ExcludedChroMapperNonMonoBehaviourCount
    MatchedPathComponentCount = $MatchedPathComponentCount
    MatchedSupportComponentCount = $MatchedSupportComponentCount
    ExactPathCount = $ExactPathCount
    NameEquivalentPathCount = $NameEquivalentPathCount
    ErrorCount = $VerificationErrors.Count
    Errors = @($VerificationErrors)
    WarningCount = $VerificationWarnings.Count
    Warnings = @($VerificationWarnings)
    LightGroups = @($GroupSummaries)
    FixtureFamilies = @($FixtureFamilySummaries)
}
$Result

if ($FailOnWarning -and ($VerificationWarnings.Count -gt 0 -or $VerificationErrors.Count -gt 0)) {
    exit 2
}
