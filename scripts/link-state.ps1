# agents-kit: состояние связи рабочей копии с базой знаний — единственный ответ на
# вопрос «где база этого каталога и всё ли с ней в порядке». Дот-сорсится хуком и
# link.ps1; сами они только переводят полученное состояние в свой формат вывода.
#
# Здесь лежит и нормализация путей, и порядок проверок; почему резолв
# не раздваивается — CLAUDE.md.

# Провал git-команды здесь не исключение, а ответ «нет»: каталог вне репозитория,
# ключа в конфиге нет. Оба случая означают одно — этот каталог киту не принадлежит.
function Invoke-KitGit([string]$Dir, [string[]]$GitArgs) {
    $out = & git -C $Dir @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return $null }
    return ($out | Select-Object -First 1).ToString().Trim()
}

function ConvertTo-KitPath([string]$Path) {
    if (-not $Path) { return $null }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    return $full.Replace('/', '\').TrimEnd('\')
}

# Путь основной рабочей копии: worktree приводится к репозиторию, от которого заведён.
# Указатель у них общий, и в базе им положена одна запись — иначе каждый временный
# worktree требовал бы правки базы, а он на то и временный.
function Get-KitWorkspace([string]$Dir) {
    $top = Invoke-KitGit $Dir @('rev-parse', '--show-toplevel')
    if (-not $top) { return $null }
    $workspace = ConvertTo-KitPath $top
    $common = Invoke-KitGit $Dir @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if ($common) {
        $commonN = ConvertTo-KitPath $common
        if ($commonN -match '\\.git$') { $workspace = ConvertTo-KitPath (Split-Path $commonN -Parent) }
    }
    return $workspace
}

function Get-KitBasePointer([string]$Dir) {
    $base = Invoke-KitGit $Dir @('config', '--local', '--get', 'agents-kit.base')
    if (-not $base) { return $null }
    return ConvertTo-KitPath $base
}

function Get-KitMarkerPath([string]$BaseDir) {
    return (Join-Path $BaseDir 'agents-kit.json')
}

# Файл принадлежности базы. Возвращает объект или $null, если файла нет либо он
# не разбирается: маркер отличает базу кита от произвольного каталога, на который
# указатель попал по опечатке.
function Get-KitMarker([string]$BaseDir) {
    $path = Get-KitMarkerPath $BaseDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $marker = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $marker -or $marker.kit -ne 'agents-kit') { return $null }
    return $marker
}

function Test-KitWorkspaceKnown($Marker, [string]$Workspace) {
    if (-not $Marker -or -not $Marker.workspaces) { return $false }
    $known = @($Marker.workspaces | ForEach-Object { ConvertTo-KitPath $_ })
    return [bool]($known | Where-Object { $_ -ieq $Workspace })
}

# Единственная цепочка состояний связи. Порядок важен: каждое следующее условие
# имеет смысл, только когда предыдущее пройдено, — по несуществующему пути нечего
# читать, а в каталоге без файла принадлежности нечего сверять.
#
#   NotGit      каталог вне git-репозитория
#   NoPointer   репозиторий не объявил базу — под китом не числится
#   BaseMissing указатель есть, каталога базы нет
#   NotBase     каталог есть, но файла принадлежности нет или он не читается
#   Unlisted    база есть, но эту рабочую копию не числит своей
#   Linked      обе стороны сошлись
function Get-KitLinkState([string]$Dir) {
    $state = [ordered]@{ status = 'NotGit'; workspace = $null; base = $null; marker = $null }

    $workspace = Get-KitWorkspace $Dir
    if (-not $workspace) { return [pscustomobject]$state }
    $state.workspace = $workspace
    $state.status = 'NoPointer'

    $base = Get-KitBasePointer $Dir
    if (-not $base) { return [pscustomobject]$state }
    $state.base = $base
    $state.status = 'BaseMissing'

    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return [pscustomobject]$state }
    $state.status = 'NotBase'

    $marker = Get-KitMarker $base
    if (-not $marker) { return [pscustomobject]$state }
    $state.marker = $marker
    $state.status = 'Unlisted'

    if (-not (Test-KitWorkspaceKnown $marker $workspace)) { return [pscustomobject]$state }
    $state.status = 'Linked'
    return [pscustomobject]$state
}
