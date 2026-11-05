param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Container)) {
            throw "Diretório inexistente ou inválido: $_"
        }
        $true
    })]
    [string]$Path,

    [int]$MinimumSizeMB = 100,

    [int]$OlderThanDays = 180,

    [int]$TopDirectories = 50,

    [string]$OutputRoot = (Join-Path $PSScriptRoot "reports")
)

$ErrorActionPreference = "Stop"

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "          WINDOWS SNIFFER             " -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    # Caminhos dos módulos.
    $scannerModule = Join-Path $PSScriptRoot "modules\StorageScanner.psm1"
    $reportModule = Join-Path $PSScriptRoot "modules\ReportManager.psm1"

    foreach ($module in @($scannerModule, $reportModule)) {
        if (-not (Test-Path -LiteralPath $module)) {
            throw "Módulo não encontrado: $module"
        }
        Import-Module $module -Force
    }

    Write-Host "Iniciando varredura..." -ForegroundColor Yellow
    Write-Host "Diretório: $Path"
    Write-Host "Tamanho mínimo: $MinimumSizeMB MB"
    Write-Host "Considerar antigo após: $OlderThanDays dias"
    Write-Host ""

    $scan = Invoke-StorageScan `
        -RootPath $Path `
        -MinimumSizeMB $MinimumSizeMB `
        -OlderThanDays $OlderThanDays

    Write-Host "Gerando relatórios..." -ForegroundColor Yellow

    $summary = Invoke-ReportGeneration `
        -ScanResult $scan `
        -OutputRoot $OutputRoot `
        -TopDirectories $TopDirectories

    Write-Host ""
    Write-Host "======================================" -ForegroundColor Green
    Write-Host "        VARREDURA CONCLUÍDA           " -ForegroundColor Green
    Write-Host "======================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Arquivos analisados: $($summary.TotalFiles)"
    Write-Host "Espaço ocupado: $($summary.TotalSizeGB) GB"
    Write-Host "Arquivos grandes: $($summary.LargeFilesCount)"
    Write-Host "Arquivos antigos: $($summary.OldFilesCount)"
    Write-Host "Diretórios: $($summary.DirectoriesCount)"
    Write-Host "Erros: $($summary.ErrorsCount)"
    Write-Host ""
    Write-Host "Relatórios salvos em:" -ForegroundColor Cyan
    Write-Host $summary.ReportsDirectory -ForegroundColor White
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "ERRO DURANTE A EXECUÇÃO:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    exit 1
}
