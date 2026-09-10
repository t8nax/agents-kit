# agents-kit: завести связь рабочей копии с базой знаний — обе стороны одной командой.
#   pwsh -NoProfile -File scripts\link.ps1 -Base <каталог базы>   связать
#   pwsh -NoProfile -File scripts\link.ps1                        показать состояние связи
#
# Состояние связи определяет link-state.ps1; здесь — запись обеих сторон и показ
# состояния человеку. Указатель ставится в локальный git config копии, встречная
# запись — в файл принадлежности базы; почему сторон именно две — CLAUDE.md.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Base,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'link-state.ps1')

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path
if ($state.status -eq 'NotGit') { throw "«$Path» не является рабочей копией git — связывать нечего" }
$workspace = $state.workspace

if (-not $Base) {
    Write-Host "Рабочая копия: $workspace"
    if ($state.base) { Write-Host "Указатель:     $($state.base)" }
    switch ($state.status) {
        'NoPointer' {
            Write-Host "Указатель:     не поставлен — репозиторий под китом не числится"
            exit 0
        }
        'BaseMissing' {
            Write-Host "База:          каталога нет — указатель разорван" -ForegroundColor Red
            exit 1
        }
        'NotBase' {
            Write-Host "База:          файла принадлежности нет или он не читается — это не база кита" -ForegroundColor Red
            exit 1
        }
        'Unlisted' {
            Write-Host "База:          есть, но эту копию не числит — связь односторонняя" -ForegroundColor Red
            Write-Host "               связать: link.ps1 -Base `"$($state.base)`""
            exit 1
        }
        'Linked' {
            Write-Host "База:          связь двусторонняя" -ForegroundColor Green
            exit 0
        }
    }
}

$baseN = ConvertTo-KitPath $Base
if (-not (Test-Path -LiteralPath $baseN -PathType Container)) {
    throw "каталога базы «$baseN» не существует — создать его должен человек, скрипт не угадывает, где ей быть"
}

# Файл принадлежности заводится, только когда его нет вовсе. Нечитаемый или чужой
# файл не перетирается: под ним может лежать список копий, который дороже удобства.
$markerPath = Get-KitMarkerPath $baseN
$marker = Get-KitMarker $baseN
if (-not $marker) {
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        throw "«$markerPath» существует, но не разбирается как файл принадлежности базы — разобраться должен человек"
    }
    $marker = [pscustomobject][ordered]@{ kit = 'agents-kit'; version = 1; workspaces = @() }
    Write-Host "Заведён файл принадлежности базы: $markerPath"
}

$known = @()
if ($marker.workspaces) { $known = @($marker.workspaces | ForEach-Object { ConvertTo-KitPath $_ }) }
if ($known | Where-Object { $_ -ieq $workspace }) {
    Write-Host "База уже числит эту копию: $workspace"
}
else {
    # Пишется прочитанный файл с заменённым списком, а не собранный заново: поле,
    # заведённое будущей версией, переживает добавление копии, а не исчезает молча.
    $marker | Add-Member -NotePropertyName 'workspaces' -NotePropertyValue @($known + $workspace) -Force
    if ($PSCmdlet.ShouldProcess($markerPath, 'записать список рабочих копий')) {
        $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8
    }
    Write-Host "База теперь числит копию: $workspace"
}

# Указатель ставится последним: упади запись в базу, связь осталась бы односторонней
# ровно в ту сторону, которую сессия принимает за рабочую.
if ($PSCmdlet.ShouldProcess($workspace, "указатель agents-kit.base → $baseN")) {
    & git -C $Path config --local agents-kit.base $baseN
    if ($LASTEXITCODE -ne 0) { throw "не удалось записать указатель в git config копии «$workspace»" }
}
Write-Host "Указатель поставлен: $workspace → $baseN"
if ($state.base -and $state.base -ine $baseN) {
    Write-Host "Прежний указатель вёл в $($state.base) — если та база больше не нужна, её запись об этой копии стоит убрать руками." -ForegroundColor Yellow
}
