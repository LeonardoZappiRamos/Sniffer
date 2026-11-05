function Get-ObjectValue {
    param(
        [object]$Object,
        [string[]]$Names,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($name)) {
                return $Object[$name]
            }
        }
        else {
            $property = $Object.PSObject.Properties[$name]

            if ($null -ne $property) {
                return $property.Value
            }
        }
    }

    return $Default
}

function ConvertTo-Bytes {
    param([object]$Value)

    if ($null -eq $Value) {
        return [int64]0
    }

    try {
        return [int64]$Value
    }
    catch {
        return [int64]0
    }
}

function Export-ReportCsv {
    param(
        [object[]]$Data,
        [string]$Path
    )

    if ($null -ne $Data -and $Data.Count -gt 0) {
        $Data | Export-Csv `
            -LiteralPath $Path `
            -NoTypeInformation `
            -Encoding UTF8
    }
    else {
        # Mantém um CSV válido mesmo quando não há registros.
        "Path" | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Invoke-ReportGeneration {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,

        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [int]$TopDirectories = 50,

        [int]$KeepLastRuns = 10,

        [switch]$PruneOldReports
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $runDirectory = Join-Path $OutputRoot $timestamp

    New-Item -ItemType Directory -Path $runDirectory -Force |
        Out-Null

    # Os objetos do scanner já vêm no formato e na ordem dos relatórios
    # (arquivos grandes por tamanho, antigos por data, diretórios por tamanho).
    # Reconverter item a item custava minutos em varreduras grandes.
    $largeFiles = @(Get-ObjectValue $ScanResult @("LargeFiles") @())
    $oldFiles = @(Get-ObjectValue $ScanResult @("OldFiles") @())
    $directoriesFull = @(Get-ObjectValue $ScanResult @("LargestDirectories") @())
    $errors = Get-ObjectValue $ScanResult @("Errors") @()
    $directories = $directoriesFull

    $directoriesTop = @(
        $directoriesFull |
            Select-Object -First $TopDirectories
    )

    # Agrupa arquivos antigos por diretório (dicionário: Group-Object é lento
    # com centenas de milhares de itens).
    $folderCount = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    $folderBytes = [System.Collections.Generic.Dictionary[string, long]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $oldFiles) {
        $folder = [IO.Path]::GetDirectoryName($file.Path)
        if (-not $folder) { $folder = "(caminho desconhecido)" }

        if ($folderCount.ContainsKey($folder)) {
            $folderCount[$folder]++
            $folderBytes[$folder] += $file.SizeBytes
        }
        else {
            $folderCount[$folder] = 1
            $folderBytes[$folder] = $file.SizeBytes
        }
    }

    # ponytail: Sort-Object aqui ordena pastas, não arquivos; volume bem menor.
    $oldFilesByFolder = @(
        foreach ($folder in $folderCount.Keys) {
            $bytes = $folderBytes[$folder]
            [PSCustomObject]@{
                Directory = $folder
                FileCount = $folderCount[$folder]
                SizeBytes = $bytes
                SizeMB    = [math]::Round($bytes / 1MB, 2)
                SizeGB    = [math]::Round($bytes / 1GB, 3)
            }
        }
    ) | Sort-Object SizeBytes -Descending
    $oldFilesByFolder = @($oldFilesByFolder)

    # Métricas gerais.
    $totalBytes = ConvertTo-Bytes (
        Get-ObjectValue $ScanResult @("TotalBytes", "TotalSizeBytes") 0
    )

    $fileCount = Get-ObjectValue $ScanResult @("FileCount", "TotalFiles") 0

    if (-not $fileCount) {
        $fileCount = 0
    }

    $errorCount = 0

    if ($null -ne $errors) {
        $errorCount = @($errors).Count
    }

    $rootPath = Get-ObjectValue $ScanResult @("RootPath", "Path") ""

    $summary = [PSCustomObject]@{
        ScanDate           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ScannedPath        = $rootPath
        TotalFiles         = $fileCount
        TotalSizeBytes     = $totalBytes
        TotalSizeGB        = [math]::Round($totalBytes / 1GB, 2)
        LargeFilesCount    = $largeFiles.Count
        OldFilesCount      = $oldFiles.Count
        DirectoriesCount   = $directories.Count
        ErrorsCount        = $errorCount
        ReportsDirectory   = $runDirectory
    }

    # Exporta os relatórios.
    Export-ReportCsv $directoriesFull (
        Join-Path $runDirectory "directories-full.csv"
    )

    Export-ReportCsv $directoriesTop (
        Join-Path $runDirectory "directories-top.csv"
    )

    Export-ReportCsv $largeFiles (
        Join-Path $runDirectory "large-files.csv"
    )

    Export-ReportCsv $oldFiles (
        Join-Path $runDirectory "old-files-full.csv"
    )

    Export-ReportCsv $oldFilesByFolder (
        Join-Path $runDirectory "old-files-by-folder.csv"
    )

    Export-ReportCsv @($errors) (
        Join-Path $runDirectory "scan-errors.csv"
    )

    # Resumo JSON.
    $summary |
        ConvertTo-Json -Depth 5 |
        Set-Content `
            -LiteralPath (Join-Path $runDirectory "summary.json") `
            -Encoding UTF8

    # Resumo TXT.
    $summaryText = @"
========================================
          STORAGE SCAN REPORT
========================================

Data da execução: $($summary.ScanDate)
Diretório analisado: $($summary.ScannedPath)

----------------------------------------
RESUMO
----------------------------------------

Arquivos analisados: $($summary.TotalFiles)
Espaço ocupado:      $($summary.TotalSizeGB) GB
Arquivos grandes:    $($summary.LargeFilesCount)
Arquivos antigos:    $($summary.OldFilesCount)
Diretórios:          $($summary.DirectoriesCount)
Erros:               $($summary.ErrorsCount)

----------------------------------------
RELATÓRIOS GERADOS
----------------------------------------

directories-top.csv
directories-full.csv
large-files.csv
old-files-by-folder.csv
old-files-full.csv
scan-errors.csv
summary.json

Diretório dos relatórios:
$runDirectory

========================================
"@

    $summaryText |
        Set-Content `
            -LiteralPath (Join-Path $runDirectory "summary.txt") `
            -Encoding UTF8

    # Retenção opcional: somente executada se explicitamente solicitada.
    if ($PruneOldReports -and $KeepLastRuns -gt 0) {
        $oldRuns = @(
            Get-ChildItem -LiteralPath $OutputRoot -Directory |
                Where-Object {
                    $_.FullName -ne $runDirectory
                } |
                Sort-Object Name -Descending |
                Select-Object -Skip ($KeepLastRuns - 1)
        )

        foreach ($oldRun in $oldRuns) {
            Remove-Item -LiteralPath $oldRun.FullName -Recurse -Force
        }
    }

    return $summary
}

Export-ModuleMember -Function Invoke-ReportGeneration
