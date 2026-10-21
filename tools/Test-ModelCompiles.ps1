<#
.SYNOPSIS
    Deploys the TMDL model to an Analysis Services Tabular server as an empty, temporary database,
    reports any DAX or metadata errors, runs every measure through both calculation groups, and
    deletes the database again. No data is loaded and no data source credentials are needed.

.EXAMPLE
    .\tools\Test-ModelCompiles.ps1 -Server localhost
#>
param(
    [string] $Server = "localhost",
    [string] $ModelFolder = (Join-Path $PSScriptRoot "..\model\definition"),
    # Any folder with the Tabular Object Model and ADOMD client DLLs (DAX Studio and Tabular Editor ship them).
    [string] $LibraryFolder = "C:\Program Files\DAX Studio\bin",
    [switch] $Keep
)

$ErrorActionPreference = "Stop"

foreach ($name in "Microsoft.AnalysisServices.Core", "Microsoft.AnalysisServices", "Microsoft.AnalysisServices.Tabular", "Microsoft.AnalysisServices.AdomdClient") {
    try { Add-Type -Path (Join-Path $LibraryFolder "$name.dll") } catch [System.Reflection.ReflectionTypeLoadException] { }  # optional cloud-auth types; not needed locally
}

$databaseName = "LakefrontBikeShare_CompileCheck_" + (Get-Date -Format "yyyyMMddHHmmss")
$tabularServer = New-Object Microsoft.AnalysisServices.Tabular.Server
$tabularServer.Connect($Server)
if ($tabularServer.Databases.ContainsName($databaseName)) { throw "$databaseName already exists; refusing to touch it." }

$problems = New-Object System.Collections.Generic.List[string]
$database = $null
try {
    $database = [Microsoft.AnalysisServices.Tabular.TmdlSerializer]::DeserializeDatabaseFromFolder((Resolve-Path $ModelFolder).Path)
    $database.Name = $databaseName
    $database.ID = $databaseName
    $tabularServer.Databases.Add($database)
    $database.Update([Microsoft.AnalysisServices.UpdateOptions]::ExpandFull)
    Write-Host "Deployed empty copy as $databaseName (compatibility level $($database.CompatibilityLevel))"

    # Mark every table as processed but empty, then build calculation groups, relationships, and hierarchies.
    $database.Model.RequestRefresh([Microsoft.AnalysisServices.Tabular.RefreshType]::ClearValues)
    $database.Model.SaveChanges() | Out-Null
    $database.Model.RequestRefresh([Microsoft.AnalysisServices.Tabular.RefreshType]::Calculate)
    $database.Model.SaveChanges() | Out-Null
    $database.Refresh($true)

    $measures = @()
    foreach ($table in $database.Model.Tables) {
        foreach ($column in $table.Columns) {
            if ($column.State -ne "Ready") { $problems.Add("Column $($table.Name)[$($column.Name)]: $($column.State) $($column.ErrorMessage)") }
        }
        foreach ($measure in $table.Measures) {
            $measures += $measure.Name
            if ($measure.State -ne "Ready") { $problems.Add("Measure [$($measure.Name)]: $($measure.State) $($measure.ErrorMessage)") }
        }
        if ($table.CalculationGroup) {
            foreach ($item in $table.CalculationGroup.CalculationItems) {
                if ($item.State -ne "Ready") { $problems.Add("Calculation item $($table.Name)[$($item.Name)]: $($item.State) $($item.ErrorMessage)") }
            }
        }
    }
    Write-Host "Checked metadata: $($database.Model.Tables.Count) tables, $($measures.Count) measures"

    # Evaluate every measure under every pair of calculation items. Iterating the calculation group rows
    # forces evaluation even though the data tables are empty (a SUMMARIZECOLUMNS over an empty Date
    # table would never call the measure), so query-time errors surface too.
    $connection = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection("Data Source=$Server;Catalog=$databaseName")
    $connection.Open()
    $evaluations = 0
    foreach ($measure in $measures) {
        $dax = @"
EVALUATE
ADDCOLUMNS (
    CROSSJOIN (
        VALUES ( 'Time Intelligence'[Time Calculation] ),
        VALUES ( 'Trend Period'[Trend Period] )
    ),
    "@Value", [$measure]
)
"@
        try {
            $command = $connection.CreateCommand()
            $command.CommandText = $dax
            $reader = $command.ExecuteReader()
            while ($reader.Read()) { $evaluations++ }
            $reader.Close()
        } catch {
            $problems.Add("Query for [$measure]: $($_.Exception.Message)")
        }
    }
    $connection.Close()
    Write-Host "Evaluated $evaluations measure x calculation item combinations ($($measures.Count) measures)"
}
catch {
    $problems.Add("Deployment: $($_.Exception.Message)")
}
finally {
    if ($database -ne $null -and $tabularServer.Databases.ContainsName($databaseName) -and -not $Keep) {
        $tabularServer.Databases.GetByName($databaseName).Drop()
        Write-Host "Deleted $databaseName"
    }
    $tabularServer.Disconnect()
}

if ($problems.Count -gt 0) {
    Write-Host "`n$($problems.Count) problem(s):" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nEverything compiles." -ForegroundColor Green
