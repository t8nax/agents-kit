# agents-kit: формат 2 — список копий в local\ базы, у каждой машины свой; память — в каталоге машины.
# Шаг переносит то, что принадлежит этой машине: копии из agents-kit.json, которые есть на её диске,
# и память этих копий. Память копии, которой здесь нет, вела другая машина — какая, шаг не угадывает.
param([string]$Base)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\base-check.ps1')

# Память разбирается целиком до первой записи: отказ на ней не оставляет полупереложенного work\.
$moves = @()
$targets = @{}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Base 'work') -File -Force -ErrorAction SilentlyContinue)) {
    $label = "work\$($file.Name)"
    if ($file.Extension -ine '.md') { throw "${label}: не память задачи — убрать файл, решает оператор" }
    $declared = Get-KitDeclaredWorktree (Read-KitMarkdown $file.FullName)
    if (-not $declared) { throw "${label}: нет строки «рабочая копия» — чья это память, не опознать: дописать строку или удалить файл, решает оператор" }
    if (-not (Test-Path -LiteralPath $declared -PathType Container)) {
        throw "${label}: копии «$declared» на этой машине нет — память вела другая машина: закрыть задачу там или удалить файл, решает оператор"
    }
    $to = Get-KitWorkMemoryPath $Base $declared
    if (-not $to) { throw 'имя этой машины не прочитано — адреса памяти нет' }
    if ($targets.ContainsKey($to.ToLowerInvariant())) { throw "${label}: копию «$declared» объявляет и другой файл — какой из них её память, решает оператор" }
    if (Test-Path -LiteralPath $to) { throw "${label}: по новому адресу «$to» уже лежит файл" }
    $targets[$to.ToLowerInvariant()] = $true
    $moves += [pscustomobject]@{ from = $file.FullName; to = $to }
}

$markerPath = Get-KitMarkerPath $Base
$marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
$list = Get-KitWorkspaceList $Base
if (-not $list) { throw "$(Get-KitWorkspacesPath $Base) не разбирается — разобраться должен оператор" }

foreach ($move in $moves) {
    New-Item -ItemType Directory -Force -Path (Split-Path $move.to -Parent) | Out-Null
    Move-Item -LiteralPath $move.from -Destination $move.to
}

# Список пишется объединением: local\ git не видит, откат упавшего перевода его не вернёт,
# и повтор шага должен дать тот же список.
$known = @(Get-KitWorkspaces $Base)
$mine = @($marker.workspaces | Where-Object { $_ } | ForEach-Object { ConvertTo-KitPath $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container })
$add = @($mine | Where-Object { $ws = $_; -not ($known | Where-Object { $_ -ieq $ws }) })
if ($add.Count) {
    $list | Add-Member -NotePropertyName 'workspaces' -NotePropertyValue @($known + $add) -Force
    $listPath = Get-KitWorkspacesPath $Base
    New-Item -ItemType Directory -Force -Path (Split-Path $listPath -Parent) | Out-Null
    $list | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $listPath -Encoding utf8
}

if ($marker.PSObject.Properties.Name -contains 'workspaces') {
    $marker.PSObject.Properties.Remove('workspaces')
    $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8
}
