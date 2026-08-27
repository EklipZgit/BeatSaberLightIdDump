#Requires -Version 7.0
<#
.SYNOPSIS
Exports LightId mapping validation CSVs and prints a synopsis from those files.

.PARAMETER GameVersion
Beat Saber version, such as 1.44.1. When omitted, every archived runtime-data
version is exported and summarized.

.PARAMETER EnvironmentName
Serialized environment name. When omitted, every table-covered environment is
exported and summarized.

.PARAMETER RuntimeLightDataPath
Repository-style RuntimeLightData root. Defaults to RuntimeLightData beside this script.

.PARAMETER LightMappingValidationPath
CSV validation root. Defaults to LightMappingValidation beside this script.

.PARAMETER SummaryOnly
Print only the aggregate category synopsis instead of per-environment perspective tables.

.PARAMETER FailOnWarning
Exit with code 2 when any CSV row has an error or warning flag.
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

# CSV generation remains independently callable while this wrapper owns all user-facing verification reporting.
$ExportScript = Join-Path $PSScriptRoot "Export-LightIdMappingVerificationCsvs.ps1"
if (-not (Test-Path -LiteralPath $ExportScript -PathType Leaf)) {
    throw "Light mapping CSV exporter not found: $ExportScript"
}

# Both scripts must resolve the same output root so the synopsis reads exactly the files produced by this invocation.
if ([string]::IsNullOrWhiteSpace($LightMappingValidationPath)) {
    $LightMappingValidationPath = Join-Path $PSScriptRoot "LightMappingValidation"
}
else {
    $LightMappingValidationPath = [System.IO.Path]::GetFullPath($LightMappingValidationPath)
}

# Preserve the exporter's optional selection parameters without manufacturing empty string arguments.
$exportArguments = @{
    LightMappingValidationPath = $LightMappingValidationPath
    SummaryOnly = $true
}
if (-not [string]::IsNullOrWhiteSpace($GameVersion)) {
    $exportArguments.GameVersion = $GameVersion
}
if (-not [string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $exportArguments.EnvironmentName = $EnvironmentName
}
if (-not [string]::IsNullOrWhiteSpace($RuntimeLightDataPath)) {
    $exportArguments.RuntimeLightDataPath = $RuntimeLightDataPath
}

# The exporter may discover mapping errors while building rows; suppress its legacy console streams so this wrapper reports only CSV-derived facts.
$exportResults = @(& $ExportScript @exportArguments 2>$null 3>$null 4>$null 5>$null 6>$null)
if ($exportResults.Count -eq 0) {
    throw "The CSV exporter returned no table-covered environment results."
}

# One result identity per environment prevents recursive all-version exporter output from being summarized more than once.
$resultIdentities = @(
    $exportResults |
        Where-Object {
            $null -ne $_ -and
                $null -ne $_.PSObject.Properties["GameVersion"] -and
                $null -ne $_.PSObject.Properties["EnvironmentName"]
        } |
        ForEach-Object {
            [pscustomobject]@{
                GameVersion = [string]$_.GameVersion
                EnvironmentName = [string]$_.EnvironmentName
            }
        } |
        Sort-Object GameVersion, EnvironmentName -Unique
)

# Validation category names are emitted as readable upper-snake labels matching the generated validationCodes cells.
function Convert-ValidationColumnToCode {
    param([Parameter(Mandatory)][string]$ColumnName)

    return ($ColumnName -creplace '([a-z0-9])([A-Z])', '$1_$2').ToUpperInvariant()
}

# Every perspective file is mandatory because absence would make a clean-looking synopsis incomplete.
$PerspectiveNames = @("DumpBehaviorLights", "DumpOtherLights", "ChroMapper", "Chroma")
$environmentResults = [System.Collections.Generic.List[object]]::new()
$allCategoryResults = [System.Collections.Generic.List[object]]::new()
foreach ($identity in $resultIdentities) {
    $environmentDirectory = Join-Path (Join-Path $LightMappingValidationPath $identity.GameVersion) $identity.EnvironmentName
    $perspectiveResults = [System.Collections.Generic.List[object]]::new()
    foreach ($perspectiveName in $PerspectiveNames) {
        # Self-identifying filenames keep version, environment, and perspective context outside the tabular data.
        $csvFileName = "$($identity.GameVersion)_$($identity.EnvironmentName)_${perspectiveName}.csv"
        $csvPath = Join-Path $environmentDirectory $csvFileName
        if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
            throw "Expected validation perspective not found: $csvPath"
        }

        # Header discovery remains valid for header-only CSVs, while populated files use Import-Csv for typed row traversal.
        $headerLine = Get-Content -LiteralPath $csvPath -TotalCount 1
        $columnNames = @($headerLine.Trim('"') -split '","')
        $rows = @(Import-Csv -LiteralPath $csvPath)
        $errorColumns = @($columnNames | Where-Object { $_.StartsWith("error", [StringComparison]::Ordinal) })
        $warningColumns = @($columnNames | Where-Object { $_.StartsWith("warning", [StringComparison]::Ordinal) })
        $errorRows = @($rows | Where-Object { $_.anyValidationError -eq "True" }).Count
        $warningRows = @($rows | Where-Object { $_.anyValidationWarning -eq "True" }).Count

        # Category counts are derived from their explicit Boolean columns rather than parsing human-readable validationCodes text.
        foreach ($categoryColumn in @($errorColumns + $warningColumns)) {
            $affectedRows = @($rows | Where-Object { $_.$categoryColumn -eq "True" }).Count
            if ($affectedRows -eq 0) {
                continue
            }

            $allCategoryResults.Add([pscustomobject]@{
                GameVersion = $identity.GameVersion
                EnvironmentName = $identity.EnvironmentName
                Perspective = $perspectiveName
                Severity = $categoryColumn.StartsWith("error", [StringComparison]::Ordinal) ? "Error" : "Warning"
                Code = Convert-ValidationColumnToCode -ColumnName $categoryColumn
                AffectedRows = $affectedRows
            })
        }

        $perspectiveResults.Add([pscustomobject]@{
            Perspective = $perspectiveName
            Rows = $rows.Count
            ErrorRows = $errorRows
            WarningRows = $warningRows
            CsvPath = $csvPath
        })
    }

    $environmentErrorRows = [int](($perspectiveResults | Measure-Object ErrorRows -Sum).Sum ?? 0)
    $environmentWarningRows = [int](($perspectiveResults | Measure-Object WarningRows -Sum).Sum ?? 0)
    $environmentCategories = @(
        $allCategoryResults |
            Where-Object {
                $_.GameVersion -ceq $identity.GameVersion -and
                    $_.EnvironmentName -ceq $identity.EnvironmentName
            }
    )
    $environmentResult = [pscustomobject]@{
        GameVersion = $identity.GameVersion
        EnvironmentName = $identity.EnvironmentName
        CsvDirectory = $environmentDirectory
        ErrorCount = $environmentErrorRows
        WarningCount = $environmentWarningRows
        ErrorCategoryCount = @($environmentCategories | Where-Object Severity -eq "Error" | Select-Object Code -Unique).Count
        WarningCategoryCount = @($environmentCategories | Where-Object Severity -eq "Warning" | Select-Object Code -Unique).Count
        Errors = @($environmentCategories | Where-Object Severity -eq "Error")
        Warnings = @($environmentCategories | Where-Object Severity -eq "Warning")
        Perspectives = @($perspectiveResults)
    }
    $environmentResults.Add($environmentResult)

    # Non-summary mode keeps the original verifier's useful per-environment scale and affected-row overview.
    if (-not $SummaryOnly) {
        Write-Host ""
        Write-Host "=== $($identity.GameVersion) / $($identity.EnvironmentName) ===" -ForegroundColor Cyan
        Write-Host "CSV directory: $environmentDirectory"
        Write-Host (($perspectiveResults | Select-Object Perspective, Rows, ErrorRows, WarningRows | Format-Table -AutoSize | Out-String).TrimEnd())
    }
}

# Aggregating category rows supplies the concise cross-version synopsis requested without hiding which perspectives are affected.
$categorySynopsis = @(
    $allCategoryResults |
        Group-Object Severity, Code |
        ForEach-Object {
            [pscustomobject]@{
                Severity = $_.Group[0].Severity
                Code = $_.Group[0].Code
                AffectedRows = [int](($_.Group | Measure-Object AffectedRows -Sum).Sum ?? 0)
                Environments = @($_.Group | Select-Object GameVersion, EnvironmentName -Unique).Count
                Perspectives = @($_.Group.Perspective | Sort-Object -Unique) -join ";"
            }
        } |
        Sort-Object @{ Expression = { $_.Severity -eq "Error" ? 0 : 1 } }, Code
)
$totalErrorRows = [int](($environmentResults | Measure-Object ErrorCount -Sum).Sum ?? 0)
$totalWarningRows = [int](($environmentResults | Measure-Object WarningCount -Sum).Sum ?? 0)

# Final console output mirrors the original verifier's category tables while making clear that counts are flagged rows across perspectives.
Write-Host ""
Write-Host "=== Light ID mapping verification CSV synopsis ===" -ForegroundColor Cyan
Write-Host "CSV root: $LightMappingValidationPath"
Write-Host "Environments: $($environmentResults.Count)"
Write-Host "Flagged error rows: $totalErrorRows"
Write-Host "Flagged warning rows: $totalWarningRows"
$errorSynopsis = @($categorySynopsis | Where-Object Severity -eq "Error")
if ($errorSynopsis.Count -gt 0) {
    Write-Host ""
    Write-Host "=== Error categories ===" -ForegroundColor Red
    Write-Host (($errorSynopsis | Select-Object Code, AffectedRows, Environments, Perspectives | Format-Table -AutoSize | Out-String).TrimEnd())
}

$warningSynopsis = @($categorySynopsis | Where-Object Severity -eq "Warning")
if ($warningSynopsis.Count -gt 0) {
    Write-Host ""
    Write-Host "=== Warning categories ===" -ForegroundColor Yellow
    Write-Host (($warningSynopsis | Select-Object Code, AffectedRows, Environments, Perspectives | Format-Table -AutoSize | Out-String).TrimEnd())
}
elseif ($errorSynopsis.Count -eq 0) {
    Write-Host "All exported mapping perspectives are clean." -ForegroundColor Green
}

# Structured results preserve DumpAllLightIds -Verify compatibility; FailOnWarning remains an opt-in command-line exit policy.
@($environmentResults)
if ($FailOnWarning -and ($totalErrorRows -gt 0 -or $totalWarningRows -gt 0)) {
    exit 2
}
