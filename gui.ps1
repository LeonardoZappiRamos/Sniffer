# Interface gráfica (WPF) do Windows Sniffer.
# Reaproveita StorageScanner e ReportManager. A varredura roda em um runspace
# separado e publica o que encontra numa fila; a janela esvazia a fila a cada
# 300 ms e vai preenchendo as tabelas ao vivo.

# WPF exige thread STA. Relança em STA se necessário (ex.: pwsh em MTA).
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$appRoot = $PSScriptRoot
$reportsRoot = Join-Path $appRoot 'reports'

# ponytail: tabelas mostram no máximo isto por aba; os CSVs têm tudo.
$displayCap = 5000

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Sniffer" Width="1100" Height="700" MinWidth="760" MinHeight="480"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
    <Window.Resources>
        <Style TargetType="DataGrid">
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#E5E5E5"/>
            <Setter Property="EnableRowVirtualization" Value="True"/>
        </Style>
    </Window.Resources>
    <DockPanel Margin="12">
        <!-- Parâmetros -->
        <Grid DockPanel.Dock="Top">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="Pasta:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox x:Name="PathBox" Grid.Column="1" Padding="4" VerticalContentAlignment="Center"/>
            <Button x:Name="BrowseButton" Grid.Column="2" Content="Procurar..." Padding="12,4" Margin="8,0,0,0"/>
        </Grid>

        <WrapPanel DockPanel.Dock="Top" Margin="0,10,0,0">
            <TextBlock Text="Tamanho mínimo (MB):" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="MinSizeBox" Width="70" Text="100" Padding="4" Margin="0,0,16,0"/>
            <TextBlock Text="Antigo após (dias):" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="DaysBox" Width="70" Text="180" Padding="4" Margin="0,0,16,0"/>
            <TextBlock Text="Top diretórios:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="TopBox" Width="70" Text="50" Padding="4" Margin="0,0,16,0"/>
            <Button x:Name="ScanButton" Content="Analisar" Padding="18,4" FontWeight="SemiBold" IsDefault="True"/>
            <Button x:Name="CancelButton" Content="Cancelar" Padding="12,4" Margin="8,0,0,0" IsEnabled="False"/>
        </WrapPanel>

        <!-- Status -->
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Button x:Name="OpenReportsButton" DockPanel.Dock="Right" Content="Abrir pasta de relatórios" Padding="12,4" IsEnabled="False"/>
            <ProgressBar x:Name="Progress" DockPanel.Dock="Left" Width="140" Height="14" Margin="0,0,10,0" Visibility="Hidden"/>
            <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="StatusText" Text="Escolha uma pasta e clique em Analisar."/>
                <TextBlock x:Name="CurrentText" Foreground="#777" FontSize="11" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
        </DockPanel>

        <!-- Resultados -->
        <TabControl x:Name="Tabs" Margin="0,12,0,0">
            <TabItem Header="Resumo">
                <TextBlock x:Name="SummaryText" Margin="16" FontFamily="Consolas" FontSize="14" Text="Nenhuma varredura executada."/>
            </TabItem>
            <TabItem x:Name="LargeTab" Header="Arquivos grandes">
                <DataGrid x:Name="LargeGrid">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Tamanho (MB)" Binding="{Binding SizeMB, StringFormat=N2}" SortMemberPath="SizeBytes"/>
                        <DataGridTextColumn Header="Nome" Binding="{Binding Name}"/>
                        <DataGridTextColumn Header="Modificado em" Binding="{Binding LastWriteTime, StringFormat=dd/MM/yyyy HH:mm}"/>
                        <DataGridTextColumn Header="Caminho" Binding="{Binding Path}"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
            <TabItem x:Name="OldTab" Header="Arquivos antigos">
                <DataGrid x:Name="OldGrid">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Tamanho (MB)" Binding="{Binding SizeMB, StringFormat=N2}" SortMemberPath="SizeBytes"/>
                        <DataGridTextColumn Header="Nome" Binding="{Binding Name}"/>
                        <DataGridTextColumn Header="Modificado em" Binding="{Binding LastWriteTime, StringFormat=dd/MM/yyyy HH:mm}"/>
                        <DataGridTextColumn Header="Caminho" Binding="{Binding Path}"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
            <TabItem x:Name="DirTab" Header="Diretórios">
                <DataGrid x:Name="DirGrid">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Tamanho (MB)" Binding="{Binding SizeMB, StringFormat=N1}" SortMemberPath="SizeBytes"/>
                        <DataGridTextColumn Header="Caminho" Binding="{Binding Path}"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
            <TabItem x:Name="ErrorTab" Header="Erros">
                <DataGrid x:Name="ErrorGrid">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Caminho" Binding="{Binding Path}"/>
                        <DataGridTextColumn Header="Erro" Binding="{Binding Message}"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $ui[$_.Name] = $window.FindName($_.Name)
}

# Varredura executada fora da thread da interface.
$scanScript = {
    param($AppRoot, $Path, $MinimumSizeMB, $OlderThanDays, $TopDirectories, $OutputRoot, $Feed, $Cap)

    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path $AppRoot 'modules\StorageScanner.psm1') -Force
    Import-Module (Join-Path $AppRoot 'modules\ReportManager.psm1') -Force

    $scan = Invoke-StorageScan -RootPath $Path -MinimumSizeMB $MinimumSizeMB -OlderThanDays $OlderThanDays -Feed $Feed -FeedLimit $Cap

    $Feed.Enqueue([PSCustomObject]@{ Kind = 'Stage'; Text = 'Gerando relatórios...' })
    $summary = Invoke-ReportGeneration -ScanResult $scan -OutputRoot $OutputRoot -TopDirectories $TopDirectories

    function Limit($Items) {
        , @($Items | Select-Object -First $Cap)
    }

    # Na tela, antigos ordenados por tamanho (o que mais libera espaço primeiro).
    $old = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $scan.OldFiles) { $old.Add($f) }

    [PSCustomObject]@{
        Summary     = $summary
        Directories = @($scan.LargestDirectories | Select-Object -First $TopDirectories |
            Select-Object Path, SizeBytes, @{ n = 'SizeMB'; e = { $_.SizeBytes / 1MB } })
        LargeFiles  = Limit $scan.LargeFiles
        OldFiles    = Limit (Get-SortedArray $old SizeBytes -Descending)
        Errors      = Limit $scan.Errors
    }
}

$script:job = $null
$script:handle = $null
$script:feed = $null
$script:lastReportDir = $null
$script:startedAt = $null
$script:progress = $null
$script:stage = $null

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(300)

function Set-Busy([bool]$Busy) {
    $ui.ScanButton.IsEnabled = -not $Busy
    $ui.BrowseButton.IsEnabled = -not $Busy
    $ui.CancelButton.IsEnabled = $Busy
    $ui.Progress.IsIndeterminate = $Busy
    $ui.Progress.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
}

function Read-PositiveInt([Windows.Controls.TextBox]$Box, [string]$Label) {
    $value = 0
    if (-not [int]::TryParse($Box.Text.Trim(), [ref]$value) -or $value -lt 0) {
        throw "$Label deve ser um número inteiro maior ou igual a zero."
    }
    $value
}

function Format-Count([long]$Shown, [long]$Total) {
    if ($Total -gt $Shown) { '{0:N0} de {1:N0}' -f $Shown, $Total } else { '{0:N0}' -f $Total }
}

# Liga uma grade a uma coleção nova; opcionalmente ordenada ao vivo.
function New-LiveList($Grid, [string]$SortBy) {
    $list = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $Grid.ItemsSource = $list
    if ($SortBy) {
        $view = [Windows.Data.CollectionViewSource]::GetDefaultView($list)
        $view.SortDescriptions.Add([ComponentModel.SortDescription]::new($SortBy, 'Descending'))
    }
    , $list
}

function Update-Headers([long]$Large, [long]$Old, [long]$Errors) {
    $ui.LargeTab.Header = "Arquivos grandes ($(Format-Count $script:large.Count $Large))"
    $ui.OldTab.Header = "Arquivos antigos ($(Format-Count $script:old.Count $Old))"
    $ui.ErrorTab.Header = "Erros ($(Format-Count $script:errors.Count $Errors))"
}

# Move o que o scanner publicou para as tabelas.
function Receive-Feed {
    # Orçamento de tempo por ciclo para a janela nunca congelar.
    $item = $null
    $budget = [Diagnostics.Stopwatch]::StartNew()
    while ($budget.ElapsedMilliseconds -lt 100 -and $script:feed.TryDequeue([ref]$item)) {
        switch ($item.Kind) {
            'Large' { if ($script:large.Count -lt $displayCap) { $script:large.Add($item.Item) } }
            'Old' { if ($script:old.Count -lt $displayCap) { $script:old.Add($item.Item) } }
            'Error' { if ($script:errors.Count -lt $displayCap) { $script:errors.Add($item.Item) } }
            'Progress' { $script:progress = $item }
            'Stage' { $script:stage = $item.Text }
        }
    }

    $elapsed = [int]((Get-Date) - $script:startedAt).TotalSeconds
    $p = $script:progress
    if ($p) {
        $ui.StatusText.Text = '{0}  {1:N0} arquivos · {2:N2} GB · {3}s' -f `
            $(if ($script:stage) { $script:stage } else { 'Analisando...' }), $p.Files, ($p.Bytes / 1GB), $elapsed
        $ui.CurrentText.Text = if ($script:stage) { '' } else { $p.Current }
        Update-Headers $p.Large $p.Old $p.Errors
    }
    else {
        $ui.StatusText.Text = "Analisando... ${elapsed}s"
    }
}

function Show-Result($Result) {
    $s = $Result.Summary
    $ui.SummaryText.Text = @"
Data da execução:     $($s.ScanDate)
Diretório analisado:  $($s.ScannedPath)

Arquivos analisados:  $('{0:N0}' -f $s.TotalFiles)
Espaço ocupado:       $($s.TotalSizeGB) GB
Arquivos grandes:     $('{0:N0}' -f $s.LargeFilesCount)
Arquivos antigos:     $('{0:N0}' -f $s.OldFilesCount)
Diretórios:           $('{0:N0}' -f $s.DirectoriesCount)
Erros:                $('{0:N0}' -f $s.ErrorsCount)

Relatórios em:
$($s.ReportsDirectory)
"@
    # Troca as listas ao vivo pelas finais (ordenadas, limitadas a $displayCap).
    $script:large = New-LiveList $ui.LargeGrid
    $script:old = New-LiveList $ui.OldGrid
    $script:errors = New-LiveList $ui.ErrorGrid
    foreach ($f in $Result.LargeFiles) { $script:large.Add($f) }
    foreach ($f in $Result.OldFiles) { $script:old.Add($f) }
    foreach ($e in $Result.Errors) { $script:errors.Add($e) }
    $ui.DirGrid.ItemsSource = $Result.Directories

    Update-Headers $s.LargeFilesCount $s.OldFilesCount $s.ErrorsCount
    $ui.DirTab.Header = "Diretórios ($($Result.Directories.Count))"

    $script:lastReportDir = $s.ReportsDirectory
    $ui.OpenReportsButton.IsEnabled = $true
}

$timer.Add_Tick({
    Receive-Feed
    if (-not $script:handle.IsCompleted) {
        return
    }

    $timer.Stop()
    $ui.CurrentText.Text = ''
    try {
        $result = $script:job.EndInvoke($script:handle) | Select-Object -Last 1
        if ($null -eq $result) {
            throw ($script:job.Streams.Error | Select-Object -First 1)
        }
        Show-Result $result
        $ui.StatusText.Text = "Concluído em $([int]((Get-Date) - $script:startedAt).TotalSeconds)s."
    }
    catch {
        # Exceções do runspace chegam embrulhadas em MethodInvocationException.
        $inner = $_.Exception.GetBaseException()
        if ($inner -is [System.Management.Automation.PipelineStoppedException]) {
            $ui.StatusText.Text = 'Varredura cancelada. Resultados parciais na tela; nenhum relatório gravado.'
        }
        else {
            $ui.StatusText.Text = "Erro: $($inner.Message)"
            [Windows.MessageBox]::Show($inner.Message, 'Erro na varredura', 'OK', 'Error') | Out-Null
        }
    }
    finally {
        $script:job.Dispose()
        $script:job = $null
        Set-Busy $false
    }
})

$ui.BrowseButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Escolha a pasta a analisar'
    if ($ui.PathBox.Text -and (Test-Path -LiteralPath $ui.PathBox.Text)) {
        $dialog.SelectedPath = $ui.PathBox.Text
    }
    if ($dialog.ShowDialog() -eq 'OK') {
        $ui.PathBox.Text = $dialog.SelectedPath
    }
})

$ui.ScanButton.Add_Click({
    try {
        $path = $ui.PathBox.Text.Trim()
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
            throw 'Escolha uma pasta existente.'
        }
        $min = Read-PositiveInt $ui.MinSizeBox 'Tamanho mínimo'
        $days = Read-PositiveInt $ui.DaysBox 'Dias'
        $top = Read-PositiveInt $ui.TopBox 'Top diretórios'
    }
    catch {
        [Windows.MessageBox]::Show($_.Exception.Message, 'Parâmetros inválidos', 'OK', 'Warning') | Out-Null
        return
    }

    # Limpa resultados anteriores e liga as tabelas ao vivo.
    $script:large = New-LiveList $ui.LargeGrid 'SizeBytes'
    $script:old = New-LiveList $ui.OldGrid 'SizeBytes'
    $script:errors = New-LiveList $ui.ErrorGrid
    $ui.DirGrid.ItemsSource = $null
    $ui.DirTab.Header = 'Diretórios (ao final)'
    $ui.SummaryText.Text = 'Varredura em andamento. Acompanhe nas abas de arquivos.'
    $ui.OpenReportsButton.IsEnabled = $false
    Update-Headers 0 0 0
    $ui.Tabs.SelectedItem = $ui.LargeTab

    $script:feed = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $script:progress = $null
    $script:stage = $null

    $script:job = [powershell]::Create()
    $null = $script:job.AddScript($scanScript).
        AddArgument($appRoot).AddArgument($path).AddArgument($min).
        AddArgument($days).AddArgument($top).AddArgument($reportsRoot).
        AddArgument($script:feed).AddArgument($displayCap)

    $script:startedAt = Get-Date
    $script:handle = $script:job.BeginInvoke()
    Set-Busy $true
    $ui.StatusText.Text = 'Analisando...'
    $timer.Start()
})

$ui.CancelButton.Add_Click({
    if ($script:job) {
        $ui.StatusText.Text = 'Cancelando...'
        $null = $script:job.BeginStop($null, $null)
    }
})

$ui.OpenReportsButton.Add_Click({
    if ($script:lastReportDir) { Start-Process explorer.exe -ArgumentList "`"$script:lastReportDir`"" }
})

# Duplo clique em uma linha abre o Explorer com o item selecionado.
foreach ($grid in @($ui.DirGrid, $ui.LargeGrid, $ui.OldGrid, $ui.ErrorGrid)) {
    $grid.Add_MouseDoubleClick({
        param($sender)
        $item = $sender.SelectedItem
        if ($item -and $item.Path -and (Test-Path -LiteralPath $item.Path)) {
            Start-Process explorer.exe -ArgumentList "/select,`"$($item.Path)`""
        }
    })
}

$window.Add_Closing({
    if ($script:job) { $script:job.Stop() }
})

$null = $window.ShowDialog()
