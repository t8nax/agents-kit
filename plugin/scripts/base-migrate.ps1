# agents-kit: перевести базу знаний на формат, который ждёт кит, — шагами plugin\migrations\,
# по коммиту на шаг.
#   pwsh -NoProfile -File scripts\base-migrate.ps1 [-Path <копия>] [-Operator <имя оператора>]
#
# Шаг перевода — plugin\migrations\NNN-<слаг>.ps1: переводит базу с формата NNN-1 на NNN.
# Формат 1 — начальный, переводить на него не с чего, и первый шаг — 002.
# Принимает -Base, пишет только файлы базы и личного репозитория оператора и git не трогает,
# кроме git init личного репозитория: номер формата и коммиты — здесь. Повторный прогон шага
# безвреден. В local\ шаг пишет так, чтобы повтор давал то же самое: git базы его не видит, и откат
# упавшего шага записанное туда уберёт только в личном репозитории. Чего шаг не опознал, он не угадывает, а бросает исключение
# с именем файла: молча пропущенный файл остался бы в прежнем формате под новым номером.
# Имя оператора шаг берёт из файла машины: -Operator записывает его туда до шагов.
#
# Незакоммиченное в базе и личном репозитории — работа соседних сессий: перевод его не коммитит
# и не откатывает. Требуй он чистого дерева — вышел бы тупик: гейт не пускает коммит памяти, пока
# база прежнего формата, и живая задача не дала бы перевести базу. Сделанное шагом отличается
# по снимку незакоммиченного до шага; задел шаг файл из снимка — правку соседа от своей не
# отделить, и шаг откатывается.
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
# базы прячет, и сюда он не попадает. У переименования в индексе за записью идёт прежний путь —
# он пропускается.
function Get-KitRepoChanges([string]$Repo) {
    $raw = & git -C $Repo status --porcelain=v1 -z --untracked-files=all 2>$null
    if ($LASTEXITCODE -ne 0) { throw "git не прочитал состояние «$Repo»" }
    $entries = @(($raw -join '') -split [char]0)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        if ($entry.Length -lt 4) { continue }
        if ($entry[0] -in 'R', 'C') { $i++ }
        [pscustomobject]@{ path = $entry.Substring(3); untracked = $entry.StartsWith('??') }
    }
}

# Снимок незакоммиченного: путь → содержимое, $null — файла нет. Нет репозитория — снимок пуст.
function Get-KitRepoSnapshot([string]$Repo) {
    $snapshot = @{}
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { return $snapshot }
    foreach ($change in @(Get-KitRepoChanges $Repo)) {
        $file = Join-Path $Repo $change.path
        $snapshot[$change.path] = $null
        if (Test-Path -LiteralPath $file -PathType Leaf) { $snapshot[$change.path] = [System.IO.File]::ReadAllBytes($file) }
    }
    return $snapshot
}

function Test-KitSameContent([string]$File, $Bytes) {
    $exists = Test-Path -LiteralPath $File -PathType Leaf
    if ($null -eq $Bytes) { return -not $exists }
    if (-not $exists) { return $false }
    $now = [System.IO.File]::ReadAllBytes($File)
    return $now.Length -eq $Bytes.Length -and [System.Linq.Enumerable]::SequenceEqual($now, [byte[]]$Bytes)
}

# Что сделал шаг в репозитории: paths — изменённое сверх снимка, touched — файлы снимка,
# которые шаг изменил.
function Get-KitStepChanges([string]$Repo, $Snapshot) {
    $paths = [System.Collections.Generic.List[object]]::new()
    $touched = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($change in @(Get-KitRepoChanges $Repo)) {
        $seen[$change.path] = $true
        if (-not $Snapshot.ContainsKey($change.path)) { $paths.Add($change); continue }
        if (-not (Test-KitSameContent (Join-Path $Repo $change.path) $Snapshot[$change.path])) { $touched.Add($change.path) }
    }
    foreach ($path in $Snapshot.Keys) {
        if (-not $seen.ContainsKey($path)) { $touched.Add($path) }
    }
    return [pscustomobject]@{ paths = $paths; touched = $touched }
}

# Откат недоделанного шага: изменённое сверх снимка — к HEAD, файлы снимка — к содержимому
# из снимка.
function Undo-KitStep([string]$Repo, $Snapshot) {
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { return }
    $step = Get-KitStepChanges $Repo $Snapshot
    $tracked = @($step.paths | Where-Object { -not $_.untracked } | ForEach-Object { $_.path })
    $fresh = @($step.paths | Where-Object { $_.untracked } | ForEach-Object { $_.path })
    if ($tracked.Count) { & git -C $Repo restore --source=HEAD --staged --worktree -- @tracked 2>$null | Out-Null }
    if ($fresh.Count) { & git -C $Repo clean -fdq -- @fresh 2>$null | Out-Null }
    foreach ($path in $step.touched) {
        $file = Join-Path $Repo $path
        if ($null -eq $Snapshot[$path]) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; continue }
        New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
        [System.IO.File]::WriteAllBytes($file, [byte[]]$Snapshot[$path])
    }
}

# Коммит сделанного шагом: сперва git add — новые файлы, потом коммит явными путями — чужое
# проиндексированное в него не попадает.
function Save-KitStepCommit([string]$Repo, $Snapshot, [string]$Message) {
    $step = Get-KitStepChanges $Repo $Snapshot
    if ($step.touched.Count) {
        $named = (@($step.touched | Select-Object -First 3)) -join ', '
        throw "шаг задел незакоммиченное соседней сессии в «$Repo»: $named — сессии его не закоммитят, пока база прежнего формата: закоммитить его git из терминала и повторить перевод решает оператор"
    }
    $paths = @($step.paths | ForEach-Object { $_.path })
    if (-not $paths.Count) { return }
    & git -C $Repo add -- @paths
    if ($LASTEXITCODE -ne 0) { throw "git не добавил изменённое шагом в «$Repo»" }
    & git -C $Repo commit -q -m $Message -- @paths
    if ($LASTEXITCODE -ne 0) { throw "git не закоммитил перевод в «$Repo»" }
}

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
    $baseSnapshot = Get-KitRepoSnapshot $base
    $personalSnapshot = Get-KitRepoSnapshot $personal
    $personalSaved = $false
    try {
        & $step.path -Base $base

        # Пишется прочитанный файл с заменённым номером: прочие поля переживают перевод.
        $marker = Get-KitMarker $base
        if (-not $marker) { throw "шаг сделал agents-kit.json нечитаемым" }
        $marker | Add-Member -NotePropertyName 'version' -NotePropertyValue $n -Force
        $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8

        # Личный репозиторий коммитится первым: закоммиченное в нём откат шага не возвращает,
        # а скопированное туда повтор шага узнаёт и не копирует заново.
        if (Test-KitPersonalRepo $base) { Save-KitStepCommit $personal $personalSnapshot $message }
        $personalSaved = $true
        Save-KitStepCommit $base $baseSnapshot $message
    }
    catch {
        Undo-KitStep $base $baseSnapshot
        if (-not $personalSaved) { Undo-KitStep $personal $personalSnapshot }
        throw "шаг перевода на формат $n ($($step.slug)) не прошёл: $($_.Exception.Message) — его правки в базе откачены, база осталась формата $($n - 1)"
    }
    $sha = Invoke-KitGit $base @('rev-parse', '--short', 'HEAD')
    Write-Host "  формат ${n}: $($step.slug) — коммит $sha"
}

Write-Host "База переведена на формат $($state.kitFormat). Работа со знанием — с новой сессии: /clear." -ForegroundColor Green
