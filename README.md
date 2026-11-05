# Windows Sniffer

Ferramenta para identificar o que ocupa espaço em disco no Windows: varre uma pasta
recursivamente e aponta **arquivos grandes**, **arquivos antigos** e os **diretórios
que mais consomem espaço**. Gera relatórios CSV/JSON/TXT a cada execução.

Funciona em PowerShell 5.1 (já incluso no Windows 10/11). Nenhuma dependência externa.

## Como usar

### Interface gráfica

Dê duplo clique em **`Sniffer.cmd`** (ou rode `powershell -STA -File .\gui.ps1`).

1. Escolha a pasta em **Procurar...**
2. Ajuste os filtros (opcional):
   - **Tamanho mínimo (MB)** — arquivos a partir desse tamanho entram em "Arquivos grandes". Padrão 100.
   - **Antigo após (dias)** — arquivos sem modificação há mais tempo que isso entram em "Arquivos antigos". Padrão 180.
   - **Top diretórios** — quantos diretórios mostrar/exportar no ranking. Padrão 50.
3. Clique **Analisar**. Os resultados aparecem **ao vivo**:
   - arquivos grandes e antigos vão entrando nas abas conforme são encontrados
     (grandes já ordenados por tamanho);
   - a barra de status mostra arquivos lidos, espaço somado, tempo e a pasta atual;
   - as abas mostram a contagem total encontrada até o momento.

   O ranking de **Diretórios** só aparece no final (o tamanho de uma pasta depende de
   todas as subpastas). **Cancelar** interrompe e mantém na tela o que já foi achado.
4. Ao terminar, as abas são trocadas pela versão final: grandes por tamanho, antigos
   **por tamanho** (o que mais libera espaço primeiro). Cada aba mostra no máximo 5.000
   linhas; os CSVs têm tudo. **Duplo clique** abre o Explorer com o item selecionado;
   colunas ordenam clicando no cabeçalho.
5. **Abrir pasta de relatórios** abre os arquivos gerados.

### Linha de comando

```powershell
.\main.ps1 -Path "C:\Users" [-MinimumSizeMB 100] [-OlderThanDays 180] [-TopDirectories 50] [-OutputRoot .\reports]
```

Retorna código de saída `1` em caso de erro (útil para agendamento/automação).

## Relatórios gerados

Cada execução cria `reports\AAAA-MM-DD_HHmmss\` com:

| Arquivo | Conteúdo |
|---|---|
| `summary.txt` / `summary.json` | Totais: arquivos, espaço, grandes, antigos, diretórios, erros |
| `directories-top.csv` | Os N maiores diretórios (tamanho inclui subpastas) |
| `directories-full.csv` | Todos os diretórios com arquivos, por tamanho |
| `large-files.csv` | Arquivos ≥ tamanho mínimo, do maior para o menor |
| `old-files-full.csv` | Arquivos antigos, do mais antigo para o mais novo |
| `old-files-by-folder.csv` | Arquivos antigos agrupados por pasta (quantidade e tamanho) |
| `scan-errors.csv` | Pastas que não puderam ser lidas (`Path`, `Message`) |

Lista vazia gera CSV só com cabeçalho `Path`.

## Estrutura

```
main.ps1                     CLI: valida parâmetros, chama scanner e relatórios
gui.ps1                      Interface WPF; roda a varredura em runspace separado
Sniffer.cmd                  Atalho de duplo clique para a interface
modules\StorageScanner.psm1  Invoke-StorageScan: varredura e agregação
modules\ReportManager.psm1   Invoke-ReportGeneration: normaliza e exporta relatórios
tests\Sniffer.Tests.ps1      Testes Pester
```

Fluxo: `main.ps1` ou `gui.ps1` → `Invoke-StorageScan` → `Invoke-ReportGeneration` → `reports\`.

### `Invoke-StorageScan`

Varredura iterativa (pilha, sem recursão) com `DirectoryInfo.EnumerateFileSystemInfos()`
do .NET. Inclui arquivos ocultos e de sistema.

- Só cria objeto para arquivos que entram em algum relatório (grande ou antigo).
- Tamanho por pasta é somado ao final numa única passada (filhos têm índice maior que o pai).
- `-Feed` (opcional, `ConcurrentQueue[object]`): publica `Large`, `Old`, `Error` conforme
  encontra, e `Progress` (arquivos, bytes, contagens, pasta atual) a cada 250 ms.
  `-FeedLimit` limita quantos itens de cada tipo vão para a fila.

- **Não segue junctions nem links simbólicos** (evita loops e contagem duplicada,
  ex.: `C:\Users\X\Application Data`).
- Pasta sem permissão não aborta a varredura: vai para `Errors` e continua.
- Pastas cuja árvore tem 0 bytes não entram em `LargestDirectories`.

Retorna: `RootPath`, `ScanDate`, `TotalFiles`, `TotalBytes`, `TotalSizeGB`,
`LargeFiles`, `OldFiles`, `LargestDirectories`, `Errors`.

### `Invoke-ReportGeneration`

Usa os objetos do scanner diretamente, já ordenados (sem reconverter item a item).
Parâmetros: `-ScanResult`, `-OutputRoot`, `-TopDirectories` (50), e retenção opcional
`-PruneOldReports -KeepLastRuns 10` (apaga execuções antigas; desligada por padrão,
não exposta na CLI/GUI). Retorna o objeto de resumo.

## Testes

```powershell
Invoke-Pester .\tests
```

Usa Pester 3.4 (já vem no Windows). 24 testes cobrindo scanner (contagem, tamanhos,
filtros, agregação por diretório, ordenação, fila ao vivo, junctions, pasta sem acesso), relatórios (arquivos,
números do resumo, top N, erros, CSV vazio, retenção), CLI (`main.ps1`, código de saída)
e carregamento do XAML da interface.

## Correções feitas no protótipo

- **Espaço ocupado sempre 0**: scanner não exportava `TotalBytes`; relatório lia esse campo.
- **Diretórios sempre 0 / CSVs de diretórios vazios**: scanner exportava `LargestDirectories`,
  relatório procurava `DirectoryTotals`.
- **`scan-errors.csv` só com coluna `Length`**: erros eram strings; `Export-Csv` exporta
  propriedades. Agora são objetos `Path` + `Message`.
- **`-TopDirectories` ignorado**: `main.ps1` não repassava ao relatório.
- **Acentos corrompidos no console**: `main.ps1` estava em UTF-8 sem BOM; PowerShell 5.1
  lê como ANSI. Salvo com BOM.

## Desempenho

Medido nesta máquina (PowerShell 5.1):

| Pasta | Antes | Agora |
|---|---|---|
| `C:\Windows\System32` (29 mil arquivos) | ~28 s (7,7 varredura + 20 relatório) | ~2 s (1,6 + 0,4) |
| `C:\Windows` (328 mil arquivos, 166 mil pastas) | não medido | ~71 s |

O que mudou: enumeração .NET no lugar de `Get-ChildItem`; objeto só para arquivos
filtrados; soma de pastas numa passada; ordenação com `Array.Sort`; relatório sem
reconversão por item (era 75% do tempo) e agrupamento por dicionário.

Armadilha encontrada: `[Array]::Sort(chaves, objetos)` chamado do PowerShell **não move
os objetos** (o PowerShell passa uma cópia do `object[]`). Por isso `Get-SortedArray`
ordena um `int[]` de índices.

## Limitações conhecidas

- Arquivos antigos ficam todos em memória (num C:\ podem ser centenas de milhares).
- A varredura é de uma thread só; o C:\ inteiro ainda leva alguns minutos.
- Campo `Category` existe mas é sempre `Unclassified` — classificação por tipo ainda não implementada.
- Duas execuções no mesmo segundo gravam na mesma pasta de relatório.
