# agents-kit: формат 5 — tracker.md базы держит постоянные разделы, и пишет его /tracker; прежний
# tracker.md уходит.
# До формата 5 tracker.md писался свободным текстом: разложить его по разделам шаг не может, не угадывая,
# а остановиться нельзя — пока база не переведена, /tracker не запишет и не закоммитит новый файл.
# Прежний текст остаётся в истории базы, и /tracker заводит трекер заново.
param([string]$Base)

$ErrorActionPreference = 'Stop'

$tracker = Join-Path $Base 'tracker.md'
if (-not (Test-Path -LiteralPath $tracker)) { return }
if (-not (Test-Path -LiteralPath $tracker -PathType Leaf)) { throw 'tracker.md: это не файл — куда его деть, решает оператор' }
Remove-Item -LiteralPath $tracker -Force
Write-Host '  прежний tracker.md удалён — трекер заводится заново скиллом /tracker, прежний текст — в истории базы'
