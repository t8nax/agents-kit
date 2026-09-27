# agents-kit: перевести базу знаний на формат, который ждёт кит, — шагами plugin\migrations\,
# по коммиту на шаг.
#   pwsh -NoProfile -File scripts\base-migrate.ps1 [-Path <копия>] [-Operator <имя оператора>]
#
# Шаг перевода — plugin\migrations\NNN-<слаг>.ps1: переводит базу с формата NNN-1 на NNN.
# Формат 1 — начальный, переводить на него не с чего, и первый шаг — 002.
# Принимает -Base, пишет только файлы базы и личного репозитория оператора и git не трогает,
# кроме git init личного репозитория: номер формата и коммиты — здесь. Повторный прогон шага
# безвреден. В local\ шаг пишет так, чтобы повтор давал то же самое: git базы его не видит, и откат
# упавшего шага записанное туда не уберёт. Чего шаг не опознал, он не угадывает, а бросает исключение
# с именем файла: молча пропущенный файл остался бы в прежнем формате под новым номером.
# Имя оператора шаг берёт из файла машины: -Operator записывает его туда до шагов.
#
# Перевод идёт только от чистого дерева базы и личного репозитория: незакоммиченное в них может
# быть работой соседней копии, а всё, что изменилось после шага, коммит берёт как сделанное шагом.
[CmdletBinding()]
param(
    [string]$Path,
    [string]$Operator
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'link-state.ps1')

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path
switch ($state.status) {
    'NotGit'    { throw "«$Path» не под git — это не рабочая копия проекта под китом" }
    'NoPointer' { throw "каталог «$($state.workspace)» под китом не числится — переводить нечего" }
    'Newer'     { throw (Get-KitFormatProblem $state) }
    'Unmerged'  { throw (Get-KitUnmergedProblem $state) }
    { $_ -in 'Linked', 'Unnamed', 'NoPersonal' } {
        Write-Host "База «$($state.base)» уже формата $($state.format) — переводить нечего."
        exit 0
    }
    'Outdated'  { }
    default     { throw "связь копии «$($state.workspace)» с базой разорвана — link.ps1 без аргументов покажет, что именно" }
}
$base = $state.base
$personal = Get-KitPersonalDir $base

# Изменённое в дереве репозитория: путь от корня и признак, что git его ещё не знает. local/ git
# базы прячет, и сюда он не попадает.
function Get-KitRepoChanges([string]$Repo) {
    $raw = & git -C $Repo status --porcelain=v1 -z --untracked-files=all 2>$null
    if ($LASTEXITCODE -ne 0) { throw "git не прочитал состояние «$Repo»" }
    foreach ($entry in (($raw -join '') -split [char]0)) {
        if ($entry.Length -lt 4) { continue }
        [pscustomobject]@{ path = $entry.Substring(3); untracked = $entry.StartsWith('??') }
    }
}

# Откат недоделанного шага: дерево до шага было чистым, поэтому всё изменённое — его.
function Undo-KitStep {
    $changes = @(Get-KitRepoChanges $base)
    $tracked = @($changes | Where-Object { -not $_.untracked } | ForEach-Object { $_.path })
    $fresh = @($changes | Where-Object { $_.untracked } | ForEach-Object { $_.path })
    if ($tracked.Count) { & git -C $base restore --source=HEAD --staged --worktree -- @tracked 2>$null | Out-Null }
    if ($fresh.Count) { & git -C $base clean -fdq -- @fresh 2>$null | Out-Null }
}

function Assert-KitClean([string]$Repo, [string]$What) {
    $dirty = @(Get-KitRepoChanges $Repo)
    if (-not $dirty.Count) { return }
    $named = (@($dirty | Select-Object -First 3) | ForEach-Object { $_.path }) -join ', '
    if ($dirty.Count -gt 3) { $named += " и ещё $($dirty.Count - 3)" }
    throw "в $What «$Repo» незакоммиченное: $named — это может быть работа соседней копии; перевод ждёт, пока его закоммитят или уберут, решает оператор"
}

# Коммит изменённого шагом: сперва git add — новые файлы, потом коммит явными путями.
function Save-KitStepCommit([string]$Repo, [string]$Message) {
    $paths = @(Get-KitRepoChanges $Repo | ForEach-Object { $_.path })
    if (-not $paths.Count) { return }
    & git -C $Repo add -- @paths
    if ($LASTEXITCODE -ne 0) { throw "git не добавил изменённое шагом в «$Repo»" }
    & git -C $Repo commit -q -m $Message -- @paths
    if ($LASTEXITCODE -ne 0) { throw "git не закоммитил перевод в «$Repo»" }
}

Assert-KitClean $base 'базе'
if (Test-KitPersonalRepo $base) { Assert-KitClean $personal 'личном репозитории' }

# Имя пишется до шагов: шагу, который раскладывает по папке оператора, спросить его не у кого.
# Формат, который ждёт кит, без оператора не работает — нет имени, перевод не начинается.
if ($Operator) { Set-KitOperatorName $base $Operator }
if (-not (Get-KitOperatorName $base)) {
    throw 'имя оператора на этой машине не названо — перевести с -Operator <имя>: латиница в нижнем регистре, цифры и дефис между ними'
}

$steps = @(Get-KitMigrations)
$markerPath = Get-KitMarkerPath $base
Write-Host "База «$base»: формат $($state.format) → $($state.kitFormat)"
for ($n = $state.format + 1; $n -le $state.kitFormat; $n++) {
    $step = @($steps | Where-Object { $_.number -eq $n })
    if ($step.Count -ne 1) { throw "шагов перевода на формат $n в ките $($step.Count), а нужен один — кит собран с ошибкой; база осталась формата $($n - 1)" }
    $step = $step[0]
    $message = "agents-kit: перевод базы на формат $n — $($step.slug)"
    try {
        & $step.path -Base $base

        # Пишется прочитанный файл с заменённым номером: прочие поля переживают перевод.
        $marker = Get-KitMarker $base
        if (-not $marker) { throw "шаг сделал agents-kit.json нечитаемым" }
        $marker | Add-Member -NotePropertyName 'version' -NotePropertyValue $n -Force
        $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8

        # Личный репозиторий коммитится первым: откат шага возвращает только базу, а скопированное
        # в личный повтор шага узнаёт и не копирует заново.
        if (Test-KitPersonalRepo $base) { Save-KitStepCommit $personal $message }
        Save-KitStepCommit $base $message
    }
    catch {
        Undo-KitStep
        throw "шаг перевода на формат $n ($($step.slug)) не прошёл: $($_.Exception.Message) — его правки в базе откачены, база осталась формата $($n - 1)"
    }
    $sha = Invoke-KitGit $base @('rev-parse', '--short', 'HEAD')
    Write-Host "  формат ${n}: $($step.slug) — коммит $sha"
}

Write-Host "База переведена на формат $($state.kitFormat). Работа со знанием — с новой сессии: /clear." -ForegroundColor Green
