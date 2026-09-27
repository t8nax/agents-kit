# agents-kit: формат 6 — рамки агента, флоу и субагенты оператора живут в его личном репозитории
# local\me\; папка people\<имя>\ базы держит флоу и субагентов, выложенных для коллег.
# Рамки уезжают из базы, флоу и субагенты копируются: в базе они и есть выложенное, коллеги их
# уже видели. Папку другого оператора шаг не переносит: её рамки и флоу уехали бы в личный
# репозиторий того, кто переводит, — на ней он останавливается.
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
$others = @(Get-ChildItem -LiteralPath (Join-Path $Base 'people') -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { (ConvertTo-KitPath $_.FullName) -ine $people } | ForEach-Object { "people\$($_.Name)" })
if ($others.Count) {
    throw "в базе папки других операторов: $($others -join ', ') — их рамки и флоу шаг не переносит, они уехали бы в личный репозиторий переводящего; решает оператор"
}

# Лежащий в личном репозитории одинаковый файл — повтор шага; разный — чужое, и шаг его
# не перетирает.
$copies = @()
function Add-KitCopy([string]$From, [string]$To) {
    if (Test-Path -LiteralPath $To -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $To).Hash -eq (Get-FileHash -LiteralPath $From).Hash) { return }
        throw "$(Get-KitRelativePath $Base (ConvertTo-KitPath $To)): уже лежит другой файл — какой верен, решает оператор"
    }
    $script:copies += [pscustomobject]@{ from = $From; to = $To }
}

$autonomy = Join-Path $people 'autonomy.md'
if (Test-Path -LiteralPath $autonomy -PathType Leaf) { Add-KitCopy $autonomy (Join-Path $personal 'autonomy.md') }
foreach ($dir in 'flow', 'agents') {
    $from = ConvertTo-KitPath (Join-Path $people $dir)
    foreach ($file in @(Get-ChildItem -LiteralPath $from -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = (ConvertTo-KitPath $file.FullName).Substring($from.Length).TrimStart('\')
        Add-KitCopy $file.FullName (Join-Path (Join-Path $personal $dir) $rel)
    }
}

# Запись.
if (-not (Test-Path -LiteralPath $personal)) {
    New-Item -ItemType Directory -Force -Path $personal | Out-Null
    & git -C $personal init -q
    if ($LASTEXITCODE -ne 0) { throw "не удалось завести личный репозиторий «$personal»" }
}
foreach ($copy in $copies) {
    New-Item -ItemType Directory -Force -Path (Split-Path $copy.to -Parent) | Out-Null
    Copy-Item -LiteralPath $copy.from -Destination $copy.to -Force
}
if (Test-Path -LiteralPath $autonomy -PathType Leaf) { Remove-Item -LiteralPath $autonomy -Force }
