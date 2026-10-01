# agents-kit: флоу в памяти задачи — сценарий, которым берут задачу, с его этапами и общим текстом
# scenarios.md копируется из флоу личного репозитория в память задачи этой рабочей копии.
#   pwsh -NoProfile -File scripts\task-flow.ps1 -Scenario <имя сценария> [-Path <копия>]
#
# Задача до закрытия идёт по нему, и правка флоу её не трогает. Копируется закоммиченный флоу,
# а скопированное не коммитится: оно уходит коммитом взятия вместе с файлом памяти, это дело
# сессии.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'base-check.ps1')

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path
switch ($state.status) {
    'NotGit'    { throw "«$Path» не под git — это не рабочая копия проекта под китом" }
    'NoPointer' { throw "каталог «$($state.workspace)» под китом не числится — сначала взять его под кит скиллом onboard" }
    'Linked'    { }
    { $_ -in 'Outdated', 'Newer' } { throw (Get-KitFormatProblem $state) }
    'Unmerged'  { throw (Get-KitUnmergedProblem $state) }
    { $_ -in 'Unnamed', 'NoPersonal' } { throw "места оператора на этой машине нет — завести: $(Get-KitOperatorCommand $state.base $state.operator)" }
    default     { throw "связь копии «$($state.workspace)» с базой разорвана — link.ps1 без аргументов покажет, что именно" }
}
$base = $state.base
$personal = $state.personal
$memory = Get-KitWorkMemoryPath $personal $state.worktree
$root = Get-KitMemoryFlowRoot $memory
if (-not $root) { throw "адрес памяти этой копии не вычисляется — имя машины не прочитано" }
# Незакоммиченный флоу без файла памяти оставило взятие, которое не дошло до памяти: его
# заменяет следующее взятие.
if (Test-Path -LiteralPath $root) {
    $rootRel = Get-KitRelativePath $personal $root
    if ((Test-Path -LiteralPath $memory) -or (Test-KitInHead $personal (Join-Path $rootRel $script:KitScenariosFile))) {
        throw "флоу в памяти задачи уже лежит в «$root» — задача у этой рабочей копии уже взята или он остался от закрытой: решает оператор"
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}

Assert-KitCommitted $personal @($script:KitFlowDir) 'флоу личного репозитория'
$fails = @(Get-KitFlowFindings $base $state.worktree (Get-KitLayoutRules) | Where-Object { $_.severity -eq 'FAIL' })
if ($fails.Count) { throw "во флоу красные находки — задача по такому флоу не берётся, починить скиллом flow:`n$(Get-KitFindingLines $fails)" }

$copy = Copy-KitTaskFlow $personal $Scenario $root
if (-not $copy) {
    $names = @(Get-KitFlowList $base | ForEach-Object { "«$($_.name)»" })
    throw "сценария «$Scenario» во флоу нет; есть: $(if ($names.Count) { $names -join ', ' } else { 'ни одного' })"
}

Write-Host "Флоу в памяти задачи — сценарий «$($copy.name)», этапы: $(($copy.stages | ForEach-Object { "«$_»" }) -join ', ')"
Write-Host "  $root"
Write-Host "В коммит взятия вместе с памятью: $(Get-KitRelativePath $personal $memory) $(Get-KitRelativePath $personal $root)"
