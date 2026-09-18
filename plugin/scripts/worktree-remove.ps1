# agents-kit: убрать рабочую копию, заведённую рядом с репозиторием, — git worktree вместе с
# каталогом; ветка остаётся.
#   pwsh -NoProfile -File scripts\worktree-remove.ps1 -Path <удаляемая копия>
#
# Копия называется путём — тем же, каким её называет кит: подача хука, строка «рабочая копия»
# памяти, вывод worktree-add.ps1. Имя ветки адресом не бывает: у отсоединённого HEAD его нет.
# Каталог по текущему не подставляется: удаление необратимо, а «здесь» слишком легко получить
# случайным запуском.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'link-state.ps1')

if (-not $Path) { throw "не названа удаляемая копия — её путь в -Path" }
$target = ConvertTo-KitPath $Path
if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "каталога «$target» не существует — удалять нечего" }

# Разрыв останавливает удаление, потому что базы на руках нет, а без неё не видно, не идёт ли
# в копии задача.
$state = Get-KitLinkState $target
switch ($state.status) {
    'NotGit'    { throw "«$target» не под git — это не рабочая копия проекта под китом" }
    'NoPointer' { throw "каталог «$($state.workspace)» под китом не числится — удалять его киту нечем" }
    'Linked'    { }
    default     { throw "связь копии «$($state.workspace)» с базой разорвана — link.ps1 без аргументов покажет, что именно" }
}

$tree = Get-KitTreeRoot $target
$repo = $state.repo
if ($tree -ieq $repo) { throw "«$tree» — основная копия проекта, а не заведённая рядом: убирать её киту нечем" }

# Windows не отдаёт каталог, в котором стоит процесс, а процесс здесь — сам скрипт.
$here = ConvertTo-KitPath (Get-Location).Path
if ($here -ieq $tree -or $here.StartsWith($tree + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "скрипт запущен внутри «$tree» — удалять эту копию из другой"
}

# Память ищется у каждого связанного каталога дерева, а не у одного названного: под кит взято
# может быть несколько каталогов монорепы с разными базами, и удаление унесло бы чужую задачу.
$linked = @()
$rootBase = Invoke-KitGit $tree @('config', '--local', '--get', 'agents-kit.base')
if ($rootBase) { $linked += [pscustomobject]@{ scope = ''; base = (ConvertTo-KitPath $rootBase) } }
$scoped = Get-KitScopedPointers $tree
foreach ($scope in $scoped.Keys) {
    $linked += [pscustomobject]@{ scope = $scope; base = $scoped[$scope] }
}
foreach ($pointer in $linked) {
    $copy = Join-KitScope $tree $pointer.scope
    $memory = Get-KitWorkMemoryPath $pointer.base $copy
    if ($memory -and (Test-Path -LiteralPath $memory -PathType Leaf)) {
        throw "в копии «$copy» задача в работе: память «$memory» — сначала закрыть задачу"
    }
}

# Ветка остаётся, поэтому коммиты переживают удаление, а незакоммиченное — нет.
$dirty = @(& git -C $tree status --porcelain --untracked-files=all 2>$null | Where-Object { $_ })
if ($LASTEXITCODE -ne 0) { throw "git не прочитал состояние копии «$tree»" }
if ($dirty.Count) {
    $named = (@($dirty | Select-Object -First 3) | ForEach-Object { $_.Substring(3) }) -join ', '
    if ($dirty.Count -gt 3) { $named += " и ещё $($dirty.Count - 3)" }
    throw "в копии «$tree» незакоммиченное: $named — сначала закоммитить"
}

$branch = Invoke-KitGit $tree @('rev-parse', '--abbrev-ref', 'HEAD')
if ($PSCmdlet.ShouldProcess($tree, 'git worktree remove')) {
    $out = & git -C $repo worktree remove $tree 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git не убрал копию «$tree»: $(($out | Out-String).Trim())" }
}

Write-Host "Рабочая копия удалена: $tree"
if ($branch -and $branch -ne 'HEAD') { Write-Host "Ветка осталась:        $branch в репозитории $repo" }
else { Write-Host "Ветки у копии не было: отсоединён" }
