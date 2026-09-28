# agents-kit: формат 7 — раздел «## Где задачи» tracker.md начинается строками трекера, сервера
# и проекта.
# Файлов шаг не меняет: вывести значения из прозы он может только угадывая, а удалять файл, как
# шаг 005, незачем — разделы правильные, не хватает трёх строк. Номер формата поднимается всё
# равно: кит прежней версии правил бы tracker.md новой базы, не зная строк.
param([string]$Base)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\base-check.ps1')

$tracker = Join-Path $Base 'tracker.md'
if (-not (Test-Path -LiteralPath $tracker)) { return }
if (-not (Test-Path -LiteralPath $tracker -PathType Leaf)) { throw 'tracker.md: это не файл — куда его деть, решает оператор' }

$keys = @(Get-KitTrackerKeys (Read-KitMarkdown $tracker) | ForEach-Object { $_.key })
if (@('трекер', 'сервер', 'проект' | Where-Object { $keys -notcontains $_ }).Count) {
    Write-Host '  в tracker.md нет строк трекера, сервера и проекта — дописать скиллом /tracker; до тех пор сессии в трекер не ходят'
}
