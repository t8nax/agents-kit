# agents-kit: где база этого каталога и всё ли со связью в порядке — единственный ответ,
# вместе с нормализацией путей и порядком проверок; почему единственный — CLAUDE.md.
# Дот-сорсится хуками и link.ps1, они только переводят состояние.

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

# Корень репозитория: worktree приводится к основной копии, от которой заведён.
function Get-KitRepoRoot([string]$Dir) {
    $top = Invoke-KitGit $Dir @('rev-parse', '--show-toplevel')
    if (-not $top) { return $null }
    $repo = ConvertTo-KitPath $top
    $common = Invoke-KitGit $Dir @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if ($common) {
        $commonN = ConvertTo-KitPath $common
        if ($commonN -match '\\.git$') { $repo = ConvertTo-KitPath (Split-Path $commonN -Parent) }
    }
    return $repo
}

# Корень дерева этой сессии: worktree остаётся собой.
function Get-KitTreeRoot([string]$Dir) {
    $top = Invoke-KitGit $Dir @('rev-parse', '--show-toplevel')
    if (-not $top) { return $null }
    return ConvertTo-KitPath $top
}

# Отрезок пути от корня дерева до каталога — им адресуется связь подкаталога.
# Почему он в нижнем регистре и с прямыми слешами — CLAUDE.md.
function Get-KitScopeSegment([string]$TreeRoot, [string]$Dir) {
    $dir = ConvertTo-KitPath $Dir
    if (-not $TreeRoot -or -not $dir) { return $null }
    if ($dir -ieq $TreeRoot) { return '' }
    if (-not $dir.StartsWith($TreeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $dir.Substring($TreeRoot.Length + 1).Replace('\', '/').ToLowerInvariant()
}

function Join-KitScope([string]$Root, [string]$Scope) {
    if (-not $Root) { return $null }
    if (-not $Scope) { return $Root }
    return ConvertTo-KitPath (Join-Path $Root ($Scope -replace '/', '\'))
}

# Имя ключа связи: у корня репозитория подсекции нет, и ключ остаётся прежним —
# копия, связанная до подкаталогов, читается как читалась.
function Get-KitPointerKey([string]$Scope) {
    if (-not $Scope) { return 'agents-kit.base' }
    return "agents-kit.$Scope.base"
}

# Все связанные подкаталоги репозитория: отрезок → путь базы. Одним вызовом, а не по
# вызову git на сегмент пути; корневой ключ сюда не попадает — у него нет подсекции.
function Get-KitScopedPointers([string]$Dir) {
    $map = [ordered]@{}
    $raw = & git -C $Dir config --local --get-regexp --null '^agents-kit\..+\.base$' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $map }
    foreach ($record in (($raw -join "`n") -split [char]0)) {
        if (-not $record) { continue }
        $break = $record.IndexOf("`n")
        if ($break -lt 1) { continue }
        $key = $record.Substring(0, $break)
        $value = $record.Substring($break + 1).Trim()
        if (-not $value) { continue }
        if ($key -notmatch '^agents-kit\.(.+)\.base$') { continue }
        $map[$Matches[1].ToLowerInvariant()] = ConvertTo-KitPath $value
    }
    return $map
}

# Указатель этого каталога — ближайший связанный предок внутри дерева, а нет такого,
# то корневой ключ репозитория; почему так и что из этого следует — CLAUDE.md.
function Resolve-KitPointer([string]$Dir, [string]$Scope) {
    if ($Scope) {
        $scoped = Get-KitScopedPointers $Dir
        if ($scoped.Count) {
            $candidate = $Scope
            while ($candidate) {
                if ($scoped.Contains($candidate)) {
                    return [pscustomobject]@{ scope = $candidate; base = $scoped[$candidate] }
                }
                $cut = $candidate.LastIndexOf('/')
                if ($cut -lt 0) { break }
                $candidate = $candidate.Substring(0, $cut)
            }
        }
    }
    $base = Invoke-KitGit $Dir @('config', '--local', '--get', 'agents-kit.base')
    if (-not $base) { return $null }
    return [pscustomobject]@{ scope = ''; base = (ConvertTo-KitPath $base) }
}

# Оба ключа пути разом: свести их в один нельзя — CLAUDE.md.
#   workspace  ключ связи   что взято под кит, в основной копии: проект, а не линия работы
#   worktree   ключ памяти  то же самое в дереве этой сессии: у worktree оно своё
function Get-KitRoots([string]$Dir) {
    $tree = Get-KitTreeRoot $Dir
    if (-not $tree) { return $null }
    $repo = Get-KitRepoRoot $Dir
    $pointer = Resolve-KitPointer $Dir (Get-KitScopeSegment $tree $Dir)
    $scope = ''
    if ($pointer) { $scope = $pointer.scope }
    return [pscustomobject]@{
        tree      = $tree
        repo      = $repo
        scope     = $scope
        pointer   = $pointer
        workspace = (Join-KitScope $repo $scope)
        worktree  = (Join-KitScope $tree $scope)
    }
}

# Адрес памяти этой сессии; отдельным вызовом он нужен тому, у кого состояния связи
# на руках нет.
function Get-KitMemoryRoot([string]$Dir) {
    $roots = Get-KitRoots $Dir
    if (-not $roots) { return $null }
    return $roots.worktree
}

# Адрес памяти — слаг полного пути: одноимённые каталоги в разных родителях не делят
# файл; нижний регистр — NTFS его не различает. Неоднозначность слага («a\b» и «a-b»)
# ловит строка «рабочая копия» внутри файла.
function Get-KitWorkMemoryPath([string]$BaseDir, [string]$Worktree) {
    if (-not $BaseDir -or -not $Worktree) { return $null }
    $slug = ([regex]::Replace($Worktree.ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-')).Trim('-')
    if (-not $slug) { return $null }
    return ConvertTo-KitPath (Join-Path $BaseDir ('work\' + $slug + '.md'))
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
#   NoPointer   ни каталог, ни репозиторий базы не объявили — под китом не числится
#   BaseMissing указатель есть, каталога базы нет
#   NotBase     каталог есть, но файла принадлежности нет или он не читается
#   Unlisted    база есть, но этот рабочий корень не числит своим
#   Linked      обе стороны сошлись
function Get-KitLinkState([string]$Dir) {
    $state = [ordered]@{
        status = 'NotGit'; workspace = $null; worktree = $null
        repo = $null; scope = ''; base = $null; marker = $null
    }

    $roots = Get-KitRoots $Dir
    if (-not $roots) { return [pscustomobject]$state }
    $state.workspace = $roots.workspace
    $state.worktree = $roots.worktree
    $state.repo = $roots.repo
    $state.scope = $roots.scope
    $state.status = 'NoPointer'

    if (-not $roots.pointer) { return [pscustomobject]$state }
    $state.base = $roots.pointer.base
    $state.status = 'BaseMissing'

    if (-not (Test-Path -LiteralPath $state.base -PathType Container)) { return [pscustomobject]$state }
    $state.status = 'NotBase'

    $marker = Get-KitMarker $state.base
    if (-not $marker) { return [pscustomobject]$state }
    $state.marker = $marker
    $state.status = 'Unlisted'

    if (-not (Test-KitWorkspaceKnown $marker $state.workspace)) { return [pscustomobject]$state }
    $state.status = 'Linked'
    return [pscustomobject]$state
}
