# agents-kit: формат 4 — рамки агента у каждого оператора свои, people\<имя>\autonomy.md; общее
# для всех — team.md в корне базы; <база>\boundaries.md уходит.
# Прежний <база>\boundaries.md был общим, и каждый коллега работал по нему: копию целиком получает папка
# каждого оператора в people\, а не только того, кто переводит, — иначе у коллег рамки пропали бы
# молча. Командное из копий операторы переносят в team.md сами: какая строка чья, шаг не угадывает.
param([string]$Base)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\base-check.ps1')

$operator = Get-KitOperatorName $Base
if (-not $operator) {
    throw 'имя оператора не названо — перевести с -Operator <имя>: латиница в нижнем регистре, цифры и дефис между ними'
}

# Каркас формата 4 — здесь, а не из template\: шаг переводит на формат 4 и тогда, когда каркас
# кита уже сменится.
$project = Get-KitProjectName $Base
if (-not $project) { $project = Split-Path $Base -Leaf }
$teamText = "# $project — правила команды`n`n## Любой работе`n`n<!-- Что обязательно в работе любого оператора: «без ревью не мержим». -->`n`n## Политика данных`n`n<!-- Что проект хранит открыто, что обезличивает и почему. -->`n"
$autonomyText = "# $project — рамки`n`n## Решает сам`n`n<!-- Что агент решает без оператора. -->`n`n## Несёт оператору`n`n<!-- Что агент не решает сам и кому это несёт. -->`n"

$boundaries = Join-Path $Base 'boundaries.md'
if (Test-Path -LiteralPath $boundaries -PathType Leaf) { $autonomyText = [string](Get-Content -LiteralPath $boundaries -Raw) }

# Всё разбирается до первой записи: отказ не оставляет полупереложенной базы. Лежащий по адресу
# такой же файл — повтор шага; другой — чужое, и шаг его не перетирает.
function Test-KitSameText([string]$Path, [string]$Text) {
    return ([string](Get-Content -LiteralPath $Path -Raw)).Replace("`r`n", "`n") -ceq $Text.Replace("`r`n", "`n")
}

$writes = @()
$dirs = @(Get-ChildItem -LiteralPath (Join-Path $Base 'people') -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { ConvertTo-KitPath $_.FullName })
$own = Get-KitOperatorDir $Base $operator
if (-not ($dirs | Where-Object { $_ -ieq $own })) { $dirs += $own }
foreach ($dir in $dirs) {
    $to = Join-Path $dir 'autonomy.md'
    if (Test-Path -LiteralPath $to) {
        if ((Test-Path -LiteralPath $to -PathType Leaf) -and (Test-KitSameText $to $autonomyText)) { continue }
        throw "$(Get-KitRelativePath $Base (ConvertTo-KitPath $to)): уже лежит другой файл — какие рамки верны, решает оператор"
    }
    $writes += [pscustomobject]@{ path = $to; text = $autonomyText }
}

$team = Join-Path $Base 'team.md'
if (Test-Path -LiteralPath $team) {
    if (-not (Test-Path -LiteralPath $team -PathType Leaf) -or -not (Test-KitSameText $team $teamText)) {
        throw 'team.md: уже лежит другой файл — он не из кита, куда его деть, решает оператор'
    }
}
else { $writes += [pscustomobject]@{ path = $team; text = $teamText } }

foreach ($write in $writes) {
    New-Item -ItemType Directory -Force -Path (Split-Path $write.path -Parent) | Out-Null
    Set-Content -LiteralPath $write.path -Value $write.text -Encoding utf8 -NoNewline
}
if (Test-Path -LiteralPath $boundaries -PathType Leaf) { Remove-Item -LiteralPath $boundaries -Force }
