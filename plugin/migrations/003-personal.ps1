# agents-kit: формат 3 — бэклог, память задач и их артефакты — в личном репозитории оператора
# local\me\, флоу и субагенты — в его папке people\<имя>\, буквы бэклога — в agents-kit.json,
# список копий — в local\me.json рядом с именем оператора.
# До этого формата база вела одного оператора, поэтому бэклог и вся память, с любой машины, —
# его, и уходят в личный репозиторий того, кто переводит.
param([string]$Base)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\base-check.ps1')

$operator = Get-KitOperatorName $Base
if (-not $operator) {
    throw 'имя оператора не названо — перевести с -Operator <имя>: латиница в нижнем регистре, цифры и дефис между ними'
}
$personal = Get-KitPersonalDir $Base
$people = Get-KitOperatorDir $Base $operator
if ((Test-Path -LiteralPath $personal) -and -not (Test-KitPersonalRepo $Base)) {
    throw "local\me: есть, но это не git-репозиторий — разобраться должен оператор"
}

# Всё разбирается до первой записи: отказ не оставляет полупереложенной базы.

# Список копий прежнего формата.
$oldList = Join-Path $Base 'local\workspaces.json'
$oldWorkspaces = @()
if (Test-Path -LiteralPath $oldList -PathType Leaf) {
    try { $parsed = Get-Content -LiteralPath $oldList -Raw | ConvertFrom-Json } catch { $parsed = $null }
    if ($parsed -isnot [pscustomobject]) { throw 'local\workspaces.json не разбирается — разобраться должен оператор' }
    $oldWorkspaces = @($parsed.workspaces | Where-Object { $_ } | ForEach-Object { ConvertTo-KitPath $_ })
}
$list = Get-KitWorkspaceList $Base
if (-not $list) { throw 'local\me.json не разбирается — разобраться должен оператор' }

# Буквы бэклога — из его счётчика, нет счётчика — из первой записи с номером.
$marker = Get-KitMarker $Base
$backlog = Join-Path $Base 'backlog.md'
$prefix = [string]$marker.prefix
if (-not $prefix) {
    if (Test-Path -LiteralPath $backlog -PathType Leaf) { $prefix = Get-KitBacklogPrefix (Read-KitMarkdown $backlog) }
    if (-not $prefix) { throw 'backlog.md: букв номеров нет ни в счётчике, ни в записях — дописать строку «следующий номер: <буквы>-1», решает оператор' }
    $prefix = $prefix.ToUpperInvariant()
}

# Файлы для личного репозитория: бэклог и вся память. Лежащий там же одинаковый файл —
# повтор шага; разный — чужое, и шаг его не перетирает.
$copies = @()
function Add-KitCopy([string]$From, [string]$To) {
    if (Test-Path -LiteralPath $To -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $To).Hash -eq (Get-FileHash -LiteralPath $From).Hash) {
            $script:copies += [pscustomobject]@{ from = $From; to = $To; skip = $true }
            return
        }
        throw "$(Get-KitRelativePath $Base (ConvertTo-KitPath $To)): уже лежит другой файл — какой верен, решает оператор"
    }
    $script:copies += [pscustomobject]@{ from = $From; to = $To; skip = $false }
}

$personalMd = @()
if (Test-Path -LiteralPath $backlog -PathType Leaf) {
    Add-KitCopy $backlog (Join-Path $personal 'backlog.md')
    $personalMd += $backlog
}
$work = Join-Path $Base 'work'
foreach ($file in @(Get-ChildItem -LiteralPath $work -File -Recurse -Force -ErrorAction SilentlyContinue)) {
    $rel = (ConvertTo-KitPath $file.FullName).Substring($Base.Length).TrimStart('\')
    Add-KitCopy $file.FullName (Join-Path $personal $rel)
    if ($file.Extension -ieq '.md') { $personalMd += $file.FullName }
}

# Артефакт уходит за бэклогом и памятью, когда на него ссылаются только они; ссылаются и файлы
# знания — копия остаётся в базе.
$personalRefs = @{}
foreach ($path in $personalMd) { foreach ($key in (Get-KitArtifactRefs (Read-KitMarkdown $path)).Keys) { $personalRefs[$key] = $true } }
$knowledgeRefs = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $Base -Recurse -File -Filter '*.md' -Force -ErrorAction SilentlyContinue)) {
    $rel = (ConvertTo-KitPath $file.FullName).Substring($Base.Length).TrimStart('\')
    if ($rel -match '^(\.git|local|work)\\' -or $rel -ieq 'backlog.md') { continue }
    foreach ($key in (Get-KitArtifactRefs (Read-KitMarkdown $file.FullName)).Keys) { $knowledgeRefs[$key] = $true }
}
$artifactsGone = @()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Base 'artifacts') -File -Force -ErrorAction SilentlyContinue)) {
    $key = $file.Name.ToLowerInvariant()
    if (-not $personalRefs.ContainsKey($key)) { continue }
    Add-KitCopy $file.FullName (Join-Path $personal "artifacts\$($file.Name)")
    if (-not $knowledgeRefs.ContainsKey($key)) { $artifactsGone += $file.FullName }
}

# Флоу и субагенты — в папку оператора. Папки оператора до этого формата не было, и лежащее
# там чужое шаг не перетирает.
$moves = @()
foreach ($dir in 'flow', 'agents') {
    $from = Join-Path $Base $dir
    if (-not (Test-Path -LiteralPath $from -PathType Container)) { continue }
    $to = Join-Path $people $dir
    if (Test-Path -LiteralPath $to) { throw "people\$operator\$dir уже есть — какой флоу верен, решает оператор" }
    $moves += [pscustomobject]@{ from = $from; to = $to }
}

# Запись. local\ — объединением, повтор даёт то же самое.
if ($oldWorkspaces.Count -or ($list.PSObject.Properties.Name -notcontains 'workspaces')) {
    $known = @(Get-KitWorkspaces $Base)
    $add = @($oldWorkspaces | Where-Object { $ws = $_; -not ($known | Where-Object { $_ -ieq $ws }) })
    $list | Add-Member -NotePropertyName 'workspaces' -NotePropertyValue @($known + $add) -Force
    Save-KitWorkspaceList $Base $list
}
if (Test-Path -LiteralPath $oldList -PathType Leaf) { Remove-Item -LiteralPath $oldList -Force }

if (-not (Test-Path -LiteralPath $personal)) {
    New-Item -ItemType Directory -Force -Path $personal | Out-Null
    & git -C $personal init -q
    if ($LASTEXITCODE -ne 0) { throw "не удалось завести личный репозиторий «$personal»" }
}
foreach ($copy in @($copies | Where-Object { -not $_.skip })) {
    New-Item -ItemType Directory -Force -Path (Split-Path $copy.to -Parent) | Out-Null
    Copy-Item -LiteralPath $copy.from -Destination $copy.to -Force
}

if (-not $marker.prefix) {
    $marker | Add-Member -NotePropertyName 'prefix' -NotePropertyValue $prefix -Force
    $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-KitMarkerPath $Base) -Encoding utf8
}

foreach ($move in $moves) {
    New-Item -ItemType Directory -Force -Path (Split-Path $move.to -Parent) | Out-Null
    Move-Item -LiteralPath $move.from -Destination $move.to
}
if (Test-Path -LiteralPath $backlog -PathType Leaf) { Remove-Item -LiteralPath $backlog -Force }
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
foreach ($path in $artifactsGone) { Remove-Item -LiteralPath $path -Force }
