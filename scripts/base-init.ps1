# agents-kit: завести каталог базы знаний проекта.
#   pwsh -NoProfile -File scripts\base-init.ps1 -Path <каталог базы> [-Name <имя проекта>]
#
# Только заведение. Связывание рабочей копии с базой и файл принадлежности — link.ps1.
# Что лежит в базе и по каким правилам — reference\base-layout.md.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Name
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# Путь приводится link-state.ps1, как и в link.ps1: напечатанный здесь путь копируют в него.
. (Join-Path $PSScriptRoot 'link-state.ps1')

$template = Join-Path $PSScriptRoot '..\template\base'
if (-not (Test-Path -LiteralPath $template -PathType Container)) {
    throw "каталога шаблона «$template» нет — клон кита неполон"
}

$baseN = ConvertTo-KitPath $Path
if (Test-Path -LiteralPath $baseN -PathType Leaf) {
    throw "«$baseN» — файл, а не каталог"
}

# Инвариант «В рабочий репозиторий знание не пишется, и каталог знания в нём не создаётся»
# исполняется здесь, а не объясняется потом. Проверяется ближайший существующий
# родитель: самого каталога базы может ещё не быть.
#
# Собственный репозиторий базы под запрет не подпадает: его завёл прошлый прогон
# этого же скрипта, и повторный прогон обязан довозить файлы, а не отказывать.
$probe = $baseN
while ($probe -and -not (Test-Path -LiteralPath $probe -PathType Container)) {
    $probe = Split-Path $probe -Parent
}
if ($probe) {
    $inside = Invoke-KitGit $probe @('rev-parse', '--show-toplevel')
    if ($inside) {
        $insideN = ConvertTo-KitPath $inside
        if ($insideN -ine $baseN) {
            throw "«$baseN» лежит внутри рабочей копии «$insideN» — база знаний в репозиторий проекта не заводится"
        }
    }
}

if (-not $Name) { $Name = Split-Path $baseN -Leaf }

if (-not (Test-Path -LiteralPath $baseN -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($baseN, 'создать каталог базы')) {
        New-Item -ItemType Directory -Force -Path $baseN | Out-Null
    }
    Write-Host "Каталог базы создан: $baseN"
}
else {
    Write-Host "Каталог базы уже существует: $baseN"
}

# Отсутствующий файл заводится, существующий не трогается никогда. Так повторный
# прогон довозит файл, появившийся в шаблоне позже, и не может съесть заполненный.
$added = 0
$kept = 0
foreach ($src in Get-ChildItem -LiteralPath $template -File -Force) {
    $dst = Join-Path $baseN $src.Name
    if (Test-Path -LiteralPath $dst -PathType Leaf) {
        Write-Host "  уже есть, не тронут: $($src.Name)"
        $kept++
        continue
    }
    $text = Get-Content -LiteralPath $src.FullName -Raw
    $text = $text.Replace('<PROJECT>', $Name)
    if ($PSCmdlet.ShouldProcess($dst, 'записать файл каркаса')) {
        Set-Content -LiteralPath $dst -Value $text -Encoding utf8 -NoNewline
    }
    Write-Host "  заведён: $($src.Name)"
    $added++
}

if (-not (Test-Path -LiteralPath (Join-Path $baseN '.git') -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($baseN, 'git init')) {
        & git -C $baseN init -q
        if ($LASTEXITCODE -ne 0) { throw "не удалось завести git-репозиторий в «$baseN»" }
    }
    Write-Host "Заведён git-репозиторий базы"
}

# Первый коммит делается только в репозитории без коммитов: в чужую историю
# скрипт не пишет. Нет идентичности git — каркас всё равно на диске, ронять нечего.
$head = Invoke-KitGit $baseN @('rev-parse', '--verify', 'HEAD')
if (-not $head -and $PSCmdlet.ShouldProcess($baseN, 'первый коммит каркаса')) {
    & git -C $baseN add -A 2>$null | Out-Null
    & git -C $baseN commit -qm 'agents-kit: каркас базы знаний' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Каркас закоммичен"
    }
    else {
        Write-Host "Каркас не закоммичен — вероятно, не задан user.name или user.email; закоммитить руками" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host "Заведено файлов: $added, оставлено нетронутыми: $kept"
Write-Host "Дальше — связать рабочую копию, из её каталога:"
Write-Host "  pwsh -NoProfile -File `"$(Join-Path $PSScriptRoot 'link.ps1')`" -Base `"$baseN`""
