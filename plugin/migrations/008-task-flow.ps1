# agents-kit: формат 8 — задача идёт по флоу в своей памяти: рядом с work/<машина>/<слаг>.md
# каталог <слаг>/flow/ со сценарием задачи, его этапами и общим текстом scenarios.md.
# Флоу у оператора один на все его машины, поэтому шаг копирует его в память каждой задачи
# личного репозитория, а не только этой машины: память без него сверка в коммит не пустит.
# Сценария из строки «сценарий:» во флоу нет — шаг не угадывает, какой взять, и бросает
# исключение с именем памяти: иначе задача осталась бы без флоу, а её память — без коммита.
# Памяти без строки «сценарий:» копировать нечего: её называет своя находка сверки, шаг — строкой
# вывода. Повтор шага скопированное не трогает.
param([string]$Base)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\base-check.ps1')

$personal = Get-KitPersonalDir $Base
$work = Join-Path $personal 'work'
if (-not (Test-Path -LiteralPath $work -PathType Container)) { return }

foreach ($machine in @(Get-ChildItem -LiteralPath $work -Directory -Force | Sort-Object Name)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $machine.FullName -File -Filter '*.md' -Force | Sort-Object Name)) {
        $memory = ConvertTo-KitPath $file.FullName
        $root = Get-KitMemoryFlowRoot $memory
        if (Test-Path -LiteralPath (Join-Path $root $script:KitScenariosFile) -PathType Leaf) { continue }
        $label = Get-KitRelativePath $Base $memory
        $name = Get-KitMemoryFlow (Read-KitMarkdown $memory)
        if (-not $name) {
            Write-Host "  ${label}: нет строки «сценарий:» — флоу в память не скопирован, по какому сценарию вести задачу, решает оператор"
            continue
        }
        if (-not (Copy-KitTaskFlow $personal $name $root)) {
            throw "${label}: сценария «$name» во флоу нет — по какому сценарию вести задачу, решает оператор: поправить строку «сценарий:» и «Агенту → Сценарий» и закоммитить git из терминала или закрыть задачу, потом повторить перевод"
        }
    }
}
