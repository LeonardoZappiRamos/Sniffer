# Testes do Windows Sniffer. Compatível com Pester 3.4 (incluso no Windows).
# Rodar: Invoke-Pester .\tests

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'modules\StorageScanner.psm1') -Force
Import-Module (Join-Path $projectRoot 'modules\ReportManager.psm1') -Force

# Árvore de teste:
#   root\big.bin            2 MB, recente
#   root\a\old.txt          10 bytes, 400 dias
#   root\a\b\mid.bin        512 KB, recente
function New-Fixture([string]$Root) {
    New-Item -ItemType Directory (Join-Path $Root 'a\b') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $Root 'big.bin'), (New-Object byte[] (2MB)))
    [IO.File]::WriteAllBytes((Join-Path $Root 'a\old.txt'), (New-Object byte[] 10))
    [IO.File]::WriteAllBytes((Join-Path $Root 'a\b\mid.bin'), (New-Object byte[] (512KB)))
    (Get-Item (Join-Path $Root 'a\old.txt')).LastWriteTime = (Get-Date).AddDays(-400)
}

$expectedBytes = [long](2MB + 10 + 512KB)

Describe 'Invoke-StorageScan' {
    $root = Join-Path $TestDrive 'scan'
    New-Fixture $root
    $scan = Invoke-StorageScan -RootPath $root -MinimumSizeMB 1 -OlderThanDays 180 6>$null

    It 'conta todos os arquivos' {
        $scan.TotalFiles | Should Be 3
    }

    It 'soma o total em bytes' {
        $scan.TotalBytes | Should Be $expectedBytes
    }

    It 'lista só arquivos acima do tamanho mínimo' {
        @($scan.LargeFiles).Count | Should Be 1
        $scan.LargeFiles[0].Name | Should Be 'big.bin'
    }

    It 'lista arquivos mais antigos que o limite' {
        @($scan.OldFiles).Count | Should Be 1
        $scan.OldFiles[0].Name | Should Be 'old.txt'
    }

    It 'acumula tamanho nos diretórios ancestrais até a raiz' {
        $dirs = @{}
        $scan.LargestDirectories | ForEach-Object { $dirs[$_.Path] = $_.SizeBytes }
        $dirs[$scan.RootPath] | Should Be $expectedBytes
        $dirs[(Join-Path $scan.RootPath 'a')] | Should Be ([long](10 + 512KB))
        $dirs[(Join-Path $scan.RootPath 'a\b')] | Should Be ([long]512KB)
    }

    It 'ordena diretórios do maior para o menor' {
        $scan.LargestDirectories[0].Path | Should Be $scan.RootPath
    }

    It 'ordena resultados mesmo quando encontrados fora de ordem' {
        # 'a\small' é varrido antes de 'z\big': a ordem final precisa inverter.
        $oRoot = Join-Path $TestDrive 'order'
        New-Item -ItemType Directory "$oRoot\a", "$oRoot\z" -Force | Out-Null
        [IO.File]::WriteAllBytes("$oRoot\a\small.bin", (New-Object byte[] (1MB)))
        [IO.File]::WriteAllBytes("$oRoot\z\big.bin", (New-Object byte[] (3MB)))
        (Get-Item "$oRoot\a\small.bin").LastWriteTime = (Get-Date).AddDays(-200)
        (Get-Item "$oRoot\z\big.bin").LastWriteTime = (Get-Date).AddDays(-900)

        $oScan = Invoke-StorageScan -RootPath $oRoot -MinimumSizeMB 1 -OlderThanDays 180 6>$null
        ($oScan.LargeFiles | ForEach-Object Name) -join ',' | Should Be 'big.bin,small.bin'
        ($oScan.OldFiles | ForEach-Object Name) -join ',' | Should Be 'big.bin,small.bin'
        $oScan.LargestDirectories[1].Path | Should Be "$oRoot\z"

        $s = Invoke-ReportGeneration -ScanResult $oScan -OutputRoot (Join-Path $TestDrive 'order-reports')
        (Import-Csv (Join-Path $s.ReportsDirectory 'old-files-by-folder.csv'))[0].Directory | Should Be "$oRoot\z"
    }

    It 'envia itens e progresso pela fila -Feed' {
        $fRoot = Join-Path $TestDrive 'feed'
        New-Fixture $fRoot
        $feed = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Invoke-StorageScan -RootPath $fRoot -MinimumSizeMB 1 -Feed $feed 6>$null | Out-Null
        $kinds = @($feed.ToArray() | ForEach-Object Kind)
        @($kinds | Where-Object { $_ -eq 'Large' }).Count | Should Be 1
        @($kinds | Where-Object { $_ -eq 'Old' }).Count | Should Be 1

        $limited = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $r = Invoke-StorageScan -RootPath $fRoot -MinimumSizeMB 0 -Feed $limited -FeedLimit 2 6>$null
        @($r.LargeFiles).Count | Should Be 3
        @($limited.ToArray() | Where-Object { $_.Kind -eq 'Large' }).Count | Should Be 2
    }

    It 'falha com diretório inexistente' {
        { Invoke-StorageScan -RootPath (Join-Path $TestDrive 'nao-existe') } | Should Throw
    }

    It 'não segue junctions' {
        $jRoot = Join-Path $TestDrive 'junction'
        New-Fixture $jRoot
        cmd /c mklink /J "$jRoot\link" "$jRoot\a" | Out-Null
        $jScan = Invoke-StorageScan -RootPath $jRoot -MinimumSizeMB 1 6>$null
        $jScan.TotalFiles | Should Be 3
    }

    It 'registra pasta sem acesso em Errors sem abortar' {
        $dRoot = Join-Path $TestDrive 'denied'
        New-Fixture $dRoot
        $locked = Join-Path $dRoot 'locked'
        New-Item -ItemType Directory $locked | Out-Null
        icacls $locked /deny "$($env:USERNAME):(RX)" | Out-Null
        try {
            $dScan = Invoke-StorageScan -RootPath $dRoot 6>$null
            $dScan.TotalFiles | Should Be 3
            @($dScan.Errors).Count | Should Be 1
            $dScan.Errors[0].Path | Should Be $locked
            $dScan.Errors[0].Message | Should Not BeNullOrEmpty
        }
        finally {
            icacls $locked /remove:d "$($env:USERNAME)" | Out-Null
        }
    }
}

Describe 'Invoke-ReportGeneration' {
    $root = Join-Path $TestDrive 'scan'
    New-Fixture $root
    $scan = Invoke-StorageScan -RootPath $root -MinimumSizeMB 1 -OlderThanDays 180 6>$null
    $scan.Errors.Add([PSCustomObject]@{ Path = 'X:\fake'; Message = 'acesso negado' })
    $outRoot = Join-Path $TestDrive 'reports'
    $summary = Invoke-ReportGeneration -ScanResult $scan -OutputRoot $outRoot -TopDirectories 2
    $dir = $summary.ReportsDirectory

    It 'gera todos os arquivos de relatório' {
        foreach ($name in 'directories-full.csv', 'directories-top.csv', 'large-files.csv',
            'old-files-full.csv', 'old-files-by-folder.csv', 'scan-errors.csv',
            'summary.json', 'summary.txt') {
            Join-Path $dir $name | Should Exist
        }
    }

    It 'resumo traz total de bytes do scanner' {
        $summary.TotalSizeBytes | Should Be $expectedBytes
    }

    It 'resumo conta diretórios do scanner' {
        $summary.DirectoriesCount | Should Be 3
    }

    It 'resumo conta arquivos, grandes, antigos e erros' {
        $summary.TotalFiles | Should Be 3
        $summary.LargeFilesCount | Should Be 1
        $summary.OldFilesCount | Should Be 1
        $summary.ErrorsCount | Should Be 1
    }

    It 'respeita TopDirectories' {
        @(Import-Csv (Join-Path $dir 'directories-top.csv')).Count | Should Be 2
        @(Import-Csv (Join-Path $dir 'directories-full.csv')).Count | Should Be 3
    }

    It 'scan-errors.csv contém caminho e mensagem' {
        $rows = @(Import-Csv (Join-Path $dir 'scan-errors.csv'))
        $rows[0].Path | Should Be 'X:\fake'
        $rows[0].Message | Should Be 'acesso negado'
    }

    It 'summary.json é JSON válido com os mesmos números' {
        $json = Get-Content (Join-Path $dir 'summary.json') -Raw | ConvertFrom-Json
        $json.TotalFiles | Should Be 3
        $json.TotalSizeBytes | Should Be $expectedBytes
    }

    It 'agrupa antigos por pasta' {
        $rows = @(Import-Csv (Join-Path $dir 'old-files-by-folder.csv'))
        $rows.Count | Should Be 1
        $rows[0].Directory | Should Be (Join-Path $scan.RootPath 'a')
    }

    It 'gera CSV válido quando lista está vazia' {
        $empty = [PSCustomObject]@{ RootPath = 'X:\'; TotalFiles = 0; LargeFiles = @(); OldFiles = @(); Errors = @() }
        $s = Invoke-ReportGeneration -ScanResult $empty -OutputRoot (Join-Path $TestDrive 'empty')
        Get-Content (Join-Path $s.ReportsDirectory 'large-files.csv') | Should Be 'Path'
    }

    It 'PruneOldReports mantém só as N últimas execuções' {
        $pruneRoot = Join-Path $TestDrive 'prune'
        foreach ($n in 1..4) { New-Item -ItemType Directory (Join-Path $pruneRoot "2000-01-0${n}_000000") -Force | Out-Null }
        Invoke-ReportGeneration -ScanResult $scan -OutputRoot $pruneRoot -KeepLastRuns 2 -PruneOldReports | Out-Null
        @(Get-ChildItem $pruneRoot -Directory).Count | Should Be 2
    }
}

Describe 'main.ps1 (CLI)' {
    $root = Join-Path $TestDrive 'cli'
    New-Fixture $root
    $out = Join-Path $TestDrive 'cli-reports'
    $main = Join-Path $projectRoot 'main.ps1'

    It 'executa e grava relatórios em OutputRoot' {
        powershell -NoProfile -ExecutionPolicy Bypass -File $main -Path $root -MinimumSizeMB 1 -OutputRoot $out | Out-Null
        $LASTEXITCODE | Should Be 0
        @(Get-ChildItem $out -Directory).Count | Should Be 1
    }

    It 'retorna erro com pasta inexistente' {
        powershell -NoProfile -ExecutionPolicy Bypass -File $main -Path (Join-Path $TestDrive 'nada') -OutputRoot $out 2>$null | Out-Null
        $LASTEXITCODE | Should Not Be 0
    }
}

Describe 'gui.ps1' {
    It 'XAML carrega e expõe todos os controles' {
        $src = Get-Content (Join-Path $projectRoot 'gui.ps1') -Raw -Encoding UTF8
        $xamlText = [regex]::Match($src, "(?s)@'\s*(<Window.*?</Window>)\s*'@").Groups[1].Value
        Add-Type -AssemblyName PresentationFramework
        [xml]$xaml = $xamlText
        $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
        foreach ($name in 'PathBox', 'ScanButton', 'CancelButton', 'DirGrid', 'LargeGrid', 'OldGrid', 'ErrorGrid', 'SummaryText') {
            $window.FindName($name) | Should Not BeNullOrEmpty
        }
    }
}
