#Requires -Version 7.0
<#
.SYNOPSIS
Exports one cross-version Chroma targeting drift CSV per environment.

.PARAMETER LightMappingValidationPath
Root containing the per-version *_Chroma.csv validation perspectives. Defaults
to LightMappingValidation beside this script.

.PARAMETER OutputPath
Destination for the generated *_ChromaDrift.csv files. Defaults to
LightMappingVersionDriftValidation beside this script.

.PARAMETER ChromaLightIdTablePath
Root containing Heck/Chroma's authored light-ID tables. Defaults to the sibling
Heck repository's Chroma/LightIDTables directory.

.PARAMETER ChroMapperGameVersion
Game-version validation perspective used for the ChroMapper target column.
Defaults to 1.44.1.
#>
param(
    [string]$LightMappingValidationPath,

    [string]$OutputPath,

    [string]$ChromaLightIdTablePath,

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ChroMapperGameVersion = "1.44.1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Defaulting both roots beside the exporter keeps checked-in source and generated drift evidence relocatable as one repository.
if ([string]::IsNullOrWhiteSpace($LightMappingValidationPath)) {
    $LightMappingValidationPath = Join-Path $PSScriptRoot "LightMappingValidation"
}
else {
    $LightMappingValidationPath = [System.IO.Path]::GetFullPath($LightMappingValidationPath)
}

# Keeping drift output separate prevents the cross-version files from being mistaken for one-version verification perspectives.
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "LightMappingVersionDriftValidation"
}
else {
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
}

# Authored tables define which combined indexes are real Chroma table entries; validation identity fallbacks must not create drift rows.
if ([string]::IsNullOrWhiteSpace($ChromaLightIdTablePath)) {
    $ChromaLightIdTablePath = Join-Path (Split-Path -Parent $PSScriptRoot) "Heck\Chroma\LightIDTables"
}
else {
    $ChromaLightIdTablePath = [System.IO.Path]::GetFullPath($ChromaLightIdTablePath)
}

# A missing validation corpus cannot produce authoritative Chroma-table rows and should fail instead of creating an empty report set.
if (-not (Test-Path -LiteralPath $LightMappingValidationPath -PathType Container)) {
    throw "Light mapping validation root not found: $LightMappingValidationPath"
}

# Without the authored table corpus, tableless identity-fallback rows cannot be distinguished from actual Chroma mappings.
if (-not (Test-Path -LiteralPath $ChromaLightIdTablePath -PathType Container)) {
    throw "Chroma light-ID table root not found: $ChromaLightIdTablePath"
}

# Semantic numeric ordering keeps 1.9.x before 1.10.x without hard-coding the dumper's supported-version list.
$versionDirectories = @(
    Get-ChildItem -LiteralPath $LightMappingValidationPath -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name }
)
if ($versionDirectories.Count -eq 0) {
    throw "No semantic-version directories were found below: $LightMappingValidationPath"
}

# ChroMapper agreement is intentionally anchored to an explicitly selected game version, currently Beat Saber 1.44.1.
if ($ChroMapperGameVersion -notin $versionDirectories.Name) {
    throw "ChroMapper game version [$ChroMapperGameVersion] was not found below: $LightMappingValidationPath"
}

# Retaining the selected version's numeric position lets ChroMapper agreement use the full identifier after display cells are abbreviated.
$chroMapperGameVersionIndex = [Array]::IndexOf([string[]]$versionDirectories.Name, $ChroMapperGameVersion)

# Full paths are the dump's pre-combined common and relative hierarchy paths; appending the type disambiguates components on one object.
function Get-GameObjectIdentifier {
    param([Parameter(Mandatory)][object]$Row)

    if ($Row.mapsToDumpBehaviorLights -cne "True" -or
        [string]::IsNullOrWhiteSpace($Row.mappedDumpBehaviorGameObjectPath) -or
        [string]::IsNullOrWhiteSpace($Row.mappedDumpBehaviorComponentType)) {
        return ""
    }

    return "$($Row.mappedDumpBehaviorGameObjectPath) $($Row.mappedDumpBehaviorComponentType)"
}

# Showing only the changed span with nearby context keeps long hierarchy paths reviewable without hiding where characters were omitted.
function Get-IdentifierDiffExcerpt {
    param(
        [AllowEmptyString()]
        [string]$PreviousIdentifier,

        [AllowEmptyString()]
        [string]$CurrentIdentifier,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$ContextLength = 10
    )

    # Missing targets remain visibly empty; only two actual equal object identifiers should render as the literal word same.
    if ($CurrentIdentifier.Length -eq 0) {
        return ""
    }

    if ($CurrentIdentifier -ceq $PreviousIdentifier) {
        return "same"
    }

    # The first unequal character anchors the left context, including a current string that is a shortened prefix of the previous one.
    $sharedPrefixLength = 0
    $shorterLength = [Math]::Min($PreviousIdentifier.Length, $CurrentIdentifier.Length)
    while ($sharedPrefixLength -lt $shorterLength -and
        $PreviousIdentifier[$sharedPrefixLength] -ceq $CurrentIdentifier[$sharedPrefixLength]) {
        $sharedPrefixLength++
    }

    # Walking backward independently finds the current string's final changed character without letting the suffix overlap the shared prefix.
    $previousSuffixIndex = $PreviousIdentifier.Length - 1
    $currentSuffixIndex = $CurrentIdentifier.Length - 1
    while ($previousSuffixIndex -ge $sharedPrefixLength -and
        $currentSuffixIndex -ge $sharedPrefixLength -and
        $PreviousIdentifier[$previousSuffixIndex] -ceq $CurrentIdentifier[$currentSuffixIndex]) {
        $previousSuffixIndex--
        $currentSuffixIndex--
    }

    # A deletion can leave no changed character in the current string, so its first suffix character becomes the context anchor.
    $lastCurrentDifference = [Math]::Max($sharedPrefixLength, $currentSuffixIndex)
    $excerptStart = [Math]::Max(0, $sharedPrefixLength - $ContextLength)
    $excerptEnd = [Math]::Min($CurrentIdentifier.Length - 1, $lastCurrentDifference + $ContextLength)
    $excerpt = $CurrentIdentifier.Substring($excerptStart, ($excerptEnd - $excerptStart) + 1)
    $leadingEllipsis = if ($excerptStart -gt 0) {
        "..."
    }
    else {
        ""
    }
    $trailingEllipsis = if ($excerptEnd -lt ($CurrentIdentifier.Length - 1)) {
        "..."
    }
    else {
        ""
    }
    return "$leadingEllipsis$excerpt$trailingEllipsis"
}

# ChroMapper objects contain incidental components, so choose the component equivalent to the mapped runtime light rather than Transform or render helpers.
function Get-ChroMapperLightComponentType {
    param([Parameter(Mandatory)][object]$Row)

    $componentTypes = @(
        ([string]$Row.mappedChroMapperComponentTypes -split ';') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($componentTypes.Count -eq 0) {
        return ""
    }

    # RectangleFakeGlow's runtime and ChroMapper names differ but represent the same serialized light component.
    $runtimeTypeIdentity = ([string]$Row.mappedDumpBehaviorComponentType -split '[.+]')[-1] -replace 'WithLightId$', 'WithId'
    $matchingTypes = @(
        $componentTypes |
            Where-Object {
                $candidateIdentity = ($_ -split '[.+]')[-1] -replace 'WithLightId$', 'WithId'
                $candidateIdentity -ceq $runtimeTypeIdentity
            }
    )
    if ($matchingTypes.Count -eq 1) {
        return $matchingTypes[0]
    }

    # A missing runtime target still permits an unambiguous ChroMapper light component to be reported for drift diagnosis.
    $lightTypes = @(
        $componentTypes |
            Where-Object { $_ -match '(?:LightWithId|LightWithIds|LightWithLightId)$' }
    )
    if ($lightTypes.Count -eq 1) {
        return $lightTypes[0]
    }

    return ""
}

# The ChroMapper cell uses the same path-plus-component shape as game-version cells and remains empty when the target is absent or ambiguous.
function Get-ChroMapperObjectIdentifier {
    param([Parameter(Mandatory)][object]$Row)

    if ($Row.existsInChroMapperTable -cne "True" -or
        $Row.mappedChroMapperTargetsOtherLight -ceq "True" -or
        [string]::IsNullOrWhiteSpace($Row.mappedChroMapperGameObjectPath)) {
        return ""
    }

    $componentType = Get-ChroMapperLightComponentType -Row $Row
    if ([string]::IsNullOrWhiteSpace($componentType)) {
        return ""
    }

    return "$($Row.mappedChroMapperGameObjectPath) $componentType"
}

# Indexing every Chroma perspective once avoids repeatedly parsing thousands of rows while building each environment report.
$rowsByVersionAndEnvironment = @{}
$environmentNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($versionDirectory in $versionDirectories) {
    $environmentRows = @{}
    $chromaFiles = @(
        Get-ChildItem -LiteralPath $versionDirectory.FullName -Recurse -File -Filter '*_Chroma.csv'
    )
    foreach ($chromaFile in $chromaFiles) {
        $environmentName = $chromaFile.Directory.Name
        $rows = @(Import-Csv -LiteralPath $chromaFile.FullName)
        $rowsByIndex = @{}
        foreach ($row in $rows) {
            # The Chroma perspective is the authoritative row filter; inventory-only ChroMapper and dump indexes never enter this union.
            $index = "$($row.beatSaberLightId).$($row.chromaLightId)"
            if ($rowsByIndex.ContainsKey($index)) {
                throw "Duplicate Chroma light index [$index] in [$($chromaFile.FullName)]."
            }

            $rowsByIndex[$index] = $row
        }

        $environmentRows[$environmentName] = $rowsByIndex
        [void]$environmentNames.Add($environmentName)
    }

    $rowsByVersionAndEnvironment[$versionDirectory.Name] = $environmentRows
}

# Creating only the dedicated generated-data directory leaves all existing validation perspectives untouched.
[void](New-Item -ItemType Directory -Path $OutputPath -Force)
$results = [System.Collections.Generic.List[object]]::new()
foreach ($environmentName in @($environmentNames | Sort-Object)) {
    $chromaTableFile = Join-Path $ChromaLightIdTablePath "${environmentName}.json"
    if (-not (Test-Path -LiteralPath $chromaTableFile -PathType Leaf)) {
        continue
    }

    # Loading keys from the authored table excludes ChroMapper inventory indexes and no-table identity fallbacks from the report.
    $chromaTable = Get-Content -LiteralPath $chromaTableFile -Raw | ConvertFrom-Json -Depth 100
    $allIndexes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($beatSaberSlot in $chromaTable.PSObject.Properties) {
        foreach ($chromaEntry in $beatSaberSlot.Value.PSObject.Properties) {
            [void]$allIndexes.Add("$($beatSaberSlot.Name).$($chromaEntry.Name)")
        }
    }

    # Numeric ordering preserves the nested Chroma-table sequence: Beat Saber slot first, authored Chroma ID second.
    $orderedIndexes = @(
        $allIndexes |
            Sort-Object `
                @{ Expression = { [int]($_ -split '\.')[0] } },
                @{ Expression = { [int]($_ -split '\.')[1] } }
    )
    $outputRows = [System.Collections.Generic.List[object]]::new()
    foreach ($index in $orderedIndexes) {
        # Placing both agreement flags before version cells keeps drift filtering adjacent to the combined Chroma index.
        $outputRow = [ordered]@{
            ChromaLightIndex = $index
            DoAllEntriesAgree = $false
            DoEntriesSinceIntroAgree = $false
        }
        $gameIdentifiers = [System.Collections.Generic.List[string]]::new()
        foreach ($versionDirectory in $versionDirectories) {
            $identifier = ""
            $environmentRows = $rowsByVersionAndEnvironment[$versionDirectory.Name]
            if ($environmentRows.ContainsKey($environmentName) -and
                $environmentRows[$environmentName].ContainsKey($index)) {
                $identifier = Get-GameObjectIdentifier -Row $environmentRows[$environmentName][$index]
            }

            $outputRow[$versionDirectory.Name] = $identifier
            $gameIdentifiers.Add($identifier)
        }

        # Agreement requires complete coverage and one exact object identifier across every archived game version.
        $nonEmptyIdentifiers = @($gameIdentifiers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $outputRow.DoAllEntriesAgree = $nonEmptyIdentifiers.Count -eq $versionDirectories.Count -and
            @($nonEmptyIdentifiers | Sort-Object -Unique).Count -eq 1

        # Leading absences describe a not-yet-introduced light, while every value from its first appearance onward must remain present and identical.
        $firstIntroducedIndex = -1
        for ($versionIndex = 0; $versionIndex -lt $gameIdentifiers.Count; $versionIndex++) {
            if (-not [string]::IsNullOrWhiteSpace($gameIdentifiers[$versionIndex])) {
                $firstIntroducedIndex = $versionIndex
                break
            }
        }

        if ($firstIntroducedIndex -ge 0) {
            $identifiersSinceIntro = @($gameIdentifiers[$firstIntroducedIndex..($gameIdentifiers.Count - 1)])
            $outputRow.DoEntriesSinceIntroAgree = @(
                $identifiersSinceIntro |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            ).Count -eq $identifiersSinceIntro.Count -and
                @($identifiersSinceIntro | Sort-Object -Unique).Count -eq 1
        }

        # Version columns are presentation-only abbreviations; agreement flags above continue to use the complete identifiers.
        for ($versionIndex = 1; $versionIndex -lt $versionDirectories.Count; $versionIndex++) {
            $outputRow[$versionDirectories[$versionIndex].Name] = Get-IdentifierDiffExcerpt `
                -PreviousIdentifier $gameIdentifiers[$versionIndex - 1] `
                -CurrentIdentifier $gameIdentifiers[$versionIndex]
        }

        $chroMapperIdentifier = ""
        $chroMapperVersionRows = $rowsByVersionAndEnvironment[$ChroMapperGameVersion]
        if ($chroMapperVersionRows.ContainsKey($environmentName) -and
            $chroMapperVersionRows[$environmentName].ContainsKey($index)) {
            $chroMapperIdentifier = Get-ChroMapperObjectIdentifier -Row $chroMapperVersionRows[$environmentName][$index]
        }

        $gameIdentifierForChroMapperVersion = $gameIdentifiers[$chroMapperGameVersionIndex]
        # ChroMapper targets use the same compact display relative to their selected game version, while agreement below uses both full values.
        $outputRow.ChroMapper = Get-IdentifierDiffExcerpt `
            -PreviousIdentifier $gameIdentifierForChroMapperVersion `
            -CurrentIdentifier $chroMapperIdentifier
        # Exact, non-empty equality exposes both missing mappings and path/component drift in the selected comparison version.
        $outputRow.DoesChroMapperAgree = -not [string]::IsNullOrWhiteSpace($gameIdentifierForChroMapperVersion) -and
            $gameIdentifierForChroMapperVersion -ceq $chroMapperIdentifier
        $outputRows.Add([pscustomobject]$outputRow)
    }

    # One flat file per serialized environment makes cross-version drift easy to review and diff in source control.
    $outputFile = Join-Path $OutputPath "${environmentName}_ChromaDrift.csv"
    $outputRows | Export-Csv -LiteralPath $outputFile -NoTypeInformation -Encoding utf8
    $results.Add([pscustomobject]@{
        EnvironmentName = $environmentName
        Rows = $outputRows.Count
        DriftRows = @($outputRows | Where-Object { -not $_.DoAllEntriesAgree }).Count
        ChroMapperDisagreementRows = @($outputRows | Where-Object { -not $_.DoesChroMapperAgree }).Count
        CsvPath = $outputFile
    })
}

# Structured results make the exporter testable while the concise synopsis remains useful in an interactive PowerShell run.
Write-Host "Exported $($results.Count) Chroma targeting drift CSVs to: $OutputPath" -ForegroundColor Cyan
$results | Format-Table EnvironmentName, Rows, DriftRows, ChroMapperDisagreementRows -AutoSize
@($results)
