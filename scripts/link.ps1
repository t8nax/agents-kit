# agents-kit: завести связь рабочей копии с базой знаний — обе стороны одной командой.
#   pwsh -NoProfile -File scripts\link.ps1 -Base <каталог базы>   связать репозиторий
#   pwsh -NoProfile -File scripts\link.ps1 -Base <база> -Scope Directory   связать каталог
#   pwsh -NoProfile -File scripts\link.ps1                        показать состояние связи
#
# Состояние связи определяет link-state.ps1; здесь — запись обеих сторон и показ
# состояния оператору. Сторон две, потому что односторонний указатель врёт молча: каталог,
# скопированный вместе с .git, писал бы знание в чужую базу, и всё выглядело бы рабочим.
# Пишет их одна команда: руками забытая вторая запись даёт ровно то, что хук блокирует.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Base,
    [string]$Path,
    [ValidateSet('Repository', 'Directory')]
    [string]$Scope = 'Repository'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'link-state.ps1')

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path
if ($state.status -eq 'NotGit') { throw "«$Path» не является рабочей копией git — связывать нечего" }

if (-not $Base) {
    Write-Host "Рабочая копия: $($state.workspace)"
    if ($state.scope) { Write-Host "Каталог:       $($state.scope) в репозитории $($state.repo)" }
    if ($state.base) { Write-Host "Указатель:     $($state.base) (ключ $(Get-KitPointerKey $state.scope))" }
    # Связанные каталоги репозитория называются всегда: сессия в несвязанном каталоге
    # монорепы молчит, и по одному её молчанию не видно, связан ли вообще кто-то.
    $scoped = Get-KitScopedPointers $Path
    if ($scoped.Count) {
        Write-Host "Каталоги репозитория под китом:"
        foreach ($key in $scoped.Keys) { Write-Host "               $key → $($scoped[$key])" }
    }
    switch ($state.status) {
        'NoPointer' {
            Write-Host "Указатель:     не поставлен — этот каталог под китом не числится"
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
            $scopeArg = ''
            if ($state.scope) { $scopeArg = ' -Scope Directory' }
            Write-Host "               связать: link.ps1$scopeArg -Base `"$($state.base)`""
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
    throw "каталога базы «$baseN» не существует — завести её base-init.ps1; link.ps1 базу не заводит и не угадывает, где ей быть"
}

# Что связывается, решает -Scope, а не то, откуда запустили: иначе запуск из
# случайного подкаталога молча связал бы его вместо репозитория.
$segment = ''
if ($Scope -eq 'Directory') {
    $tree = Get-KitTreeRoot $Path
    $segment = Get-KitScopeSegment $tree $Path
    if ($null -eq $segment) { throw "«$Path» лежит вне рабочего дерева «$tree» — связывать нечего" }
    if (-not $segment) { Write-Host "Каталог и есть корень репозитория — связывается репозиторий." }
}
$pointerKey = Get-KitPointerKey $segment
# В список базы идёт каталог, для которого записан указатель: иначе две базы числили бы
# своим один путь.
$workspace = Join-KitScope (Get-KitRepoRoot $Path) $segment

# Файл принадлежности заводится, только когда его нет вовсе. Нечитаемый или чужой
# файл не перетирается: под ним может лежать список копий, который дороже удобства.
$markerPath = Get-KitMarkerPath $baseN
$marker = Get-KitMarker $baseN
if (-not $marker) {
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        throw "«$markerPath» существует, но не разбирается как файл принадлежности базы — разобраться должен оператор"
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
if ($PSCmdlet.ShouldProcess($workspace, "указатель $pointerKey → $baseN")) {
    & git -C $Path config --local $pointerKey $baseN
    if ($LASTEXITCODE -ne 0) { throw "не удалось записать указатель в git config копии «$workspace»" }
}
Write-Host "Указатель поставлен: $workspace → $baseN (ключ $pointerKey)"
if ($state.base -and $state.base -ine $baseN) {
    Write-Host "Прежний указатель вёл в $($state.base) — если та база больше не нужна, её запись об этой копии стоит убрать руками." -ForegroundColor Yellow
}
# Связь репозитория подкаталог перебивает: без этой строки оператор считал бы, что
# связал всё дерево, а сессия в подкаталоге брала бы другую базу.
if (-not $segment) {
    $scoped = Get-KitScopedPointers $Path
    if ($scoped.Count) {
        Write-Host "В репозитории есть каталоги со своей базой — для них связь репозитория не действует:" -ForegroundColor Yellow
        foreach ($key in $scoped.Keys) { Write-Host "  $key → $($scoped[$key])" -ForegroundColor Yellow }
    }
}
