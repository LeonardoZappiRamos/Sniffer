function Invoke-StorageScan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [int]$MinimumSizeMB = 100,
        [int]$OlderThanDays = 180,

        # Fila opcional para acompanhar a varredura ao vivo (usada pela GUI).
        # Recebe objetos com Kind = 'Large' | 'Old' | 'Error' | 'Progress'.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$Feed,

        # Máximo de itens de cada tipo publicados na fila (contagens seguem
        # nos objetos Progress). Evita inundar quem consome a fila.
        [int]$FeedLimit = [int]::MaxValue
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        throw "Diretório inexistente ou inválido: $RootPath"
    }

    $root = (Get-Item -LiteralPath $RootPath -Force -ErrorAction Stop).FullName

    Write-Host "Diretório validado: $root"

    $cutoffDate = (Get-Date).AddDays(-$OlderThanDays)
    $minimumBytes = [long]$MinimumSizeMB * 1MB
    $reparsePoint = [IO.FileAttributes]::ReparsePoint

    $largeFiles = [System.Collections.Generic.List[object]]::new()
    $oldFiles = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()

    # Diretórios indexados na ordem em que são descobertos. Um filho sempre
    # tem índice maior que o pai, o que permite somar os totais numa só
    # passada de trás para frente ao final.
    $dirPaths = [System.Collections.Generic.List[string]]::new()
    $dirParents = [System.Collections.Generic.List[int]]::new()
    $dirBytes = [System.Collections.Generic.List[long]]::new()

    $dirPaths.Add($root); $dirParents.Add(-1); $dirBytes.Add(0)

    $stack = [System.Collections.Generic.Stack[int]]::new()
    $stack.Push(0)

    $totalFiles = 0
    $totalBytes = [long]0
    $clock = [Diagnostics.Stopwatch]::StartNew()

    while ($stack.Count -gt 0) {
        $index = $stack.Pop()
        $current = $dirPaths[$index]
        $ownBytes = [long]0

        try {
            # Enumeração .NET direta: muito mais leve que Get-ChildItem.
            # Inclui ocultos e de sistema (equivale a -Force).
            foreach ($entry in [IO.DirectoryInfo]::new($current).EnumerateFileSystemInfos()) {

                # Evita seguir junctions e links simbólicos.
                if (($entry.Attributes -band $reparsePoint) -ne 0) {
                    continue
                }

                if ($entry -is [IO.DirectoryInfo]) {
                    $dirPaths.Add($entry.FullName)
                    $dirParents.Add($index)
                    $dirBytes.Add(0)
                    $stack.Push($dirPaths.Count - 1)
                    continue
                }

                $size = $entry.Length
                $totalFiles++
                $ownBytes += $size

                $isLarge = $size -ge $minimumBytes
                $isOld = $entry.LastWriteTime -lt $cutoffDate

                # Só materializa objeto para arquivos que entram em algum relatório.
                if ($isLarge -or $isOld) {
                    $file = [PSCustomObject]@{
                        Path          = $entry.FullName
                        Name          = $entry.Name
                        Extension     = $entry.Extension
                        SizeBytes     = $size
                        SizeMB        = [math]::Round($size / 1MB, 2)
                        LastWriteTime = $entry.LastWriteTime
                        IsOld         = $isOld
                        Category      = "Unclassified"
                    }

                    if ($isLarge) {
                        $largeFiles.Add($file)
                        if ($Feed -and $largeFiles.Count -le $FeedLimit) { $Feed.Enqueue([PSCustomObject]@{ Kind = 'Large'; Item = $file }) }
                    }
                    if ($isOld) {
                        $oldFiles.Add($file)
                        if ($Feed -and $oldFiles.Count -le $FeedLimit) { $Feed.Enqueue([PSCustomObject]@{ Kind = 'Old'; Item = $file }) }
                    }
                }
            }
        }
        catch {
            $err = [PSCustomObject]@{
                Path    = $current
                Message = $_.Exception.Message
            }
            $errors.Add($err)
            if ($Feed -and $errors.Count -le $FeedLimit) { $Feed.Enqueue([PSCustomObject]@{ Kind = 'Error'; Item = $err }) }
        }

        $dirBytes[$index] = $ownBytes
        $totalBytes += $ownBytes

        if ($Feed -and $clock.ElapsedMilliseconds -ge 250) {
            $Feed.Enqueue([PSCustomObject]@{
                Kind    = 'Progress'
                Files   = $totalFiles
                Bytes   = $totalBytes
                Large   = $largeFiles.Count
                Old     = $oldFiles.Count
                Errors  = $errors.Count
                Current = $current
            })
            $clock.Restart()
        }
    }

    # Soma o tamanho de cada diretório no pai (filhos sempre depois dos pais).
    for ($i = $dirPaths.Count - 1; $i -gt 0; $i--) {
        $dirBytes[$dirParents[$i]] += $dirBytes[$i]
    }

    $directories = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $dirPaths.Count; $i++) {
        # Ignora árvores sem nenhum byte (pastas vazias).
        if ($dirBytes[$i] -gt 0) {
            $directories.Add([PSCustomObject]@{
                Path      = $dirPaths[$i]
                SizeGB    = [math]::Round($dirBytes[$i] / 1GB, 2)
                SizeBytes = $dirBytes[$i]
            })
        }
    }

    [PSCustomObject]@{
        RootPath           = $root
        ScanDate           = Get-Date
        TotalFiles         = $totalFiles
        TotalBytes         = $totalBytes
        TotalSizeGB        = [math]::Round($totalBytes / 1GB, 2)
        LargeFiles         = Get-SortedArray $largeFiles SizeBytes -Descending
        OldFiles           = Get-SortedArray $oldFiles LastWriteTime
        LargestDirectories = Get-SortedArray $directories SizeBytes -Descending
        Errors             = $errors
    }
}

# Ordenação nativa (Array.Sort com chaves long): bem mais rápida que
# Sort-Object em listas com centenas de milhares de itens.
function Get-SortedArray {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [string]$Property,
        [switch]$Descending
    )

    $array = $Items.ToArray()
    $keys = [long[]]::new($array.Length)
    $sign = if ($Descending) { -1 } else { 1 }
    for ($i = 0; $i -lt $array.Length; $i++) {
        $value = $array[$i].$Property
        if ($value -is [datetime]) { $value = $value.Ticks }
        $keys[$i] = $sign * $value
    }
    # Ordena índices (int[]): o PowerShell passa cópia de object[] para
    # métodos .NET, então Sort(keys, objetos) não moveria os objetos.
    $order = [int[]](0..($array.Length - 1))
    if ($array.Length -eq 0) { $order = [int[]]::new(0) }
    [Array]::Sort($keys, $order)

    $sorted = [object[]]::new($array.Length)
    for ($i = 0; $i -lt $order.Length; $i++) {
        $sorted[$i] = $array[$order[$i]]
    }
    , $sorted
}

Export-ModuleMember -Function Invoke-StorageScan, Get-SortedArray
