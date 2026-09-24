# agents-kit: где база этого каталога и всё ли со связью в порядке — вместе с нормализацией
# путей и порядком проверок. Дот-сорсится остальными скриптами.
#
# Адрес базы — локальный git config копии: он не попадает в коммит и наследуется каждым worktree.

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

# Корень репозитория: worktree приводится к репозиторию, от которого заведён.
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
# Нижний регистр — подсекции git регистрозависимы, а каталоги Windows нет; прямые слеши —
# отрезок один на любой запуск.
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

# Имя ключа связи: у корня репозитория подсекции нет.
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
# то корневой ключ репозитория. Вне связанного каталога сессия не получает ничего, как без указателя.
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

# Оба ключа пути разом. Свести их нельзя: worktree потерял бы память или каждый worktree
# потребовал бы записи в базе.
#   workspace  ключ связи   что взято под кит, в основной копии: проект, а не линия работы
#   worktree   ключ памяти  то же самое в дереве этой сессии: у worktree оно своё
# Ключ — абсолютный путь, не git remote: у каталога, скопированного с .git, тот же origin,
# и remote пропустил бы ровно тот случай, ради которого проверка заведена.
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

# Субагент базы, разложенный в рабочую копию: где лежит, чем спрятан от git проекта и что
# из лежащего рядом принадлежит проекту. Адрес нужен и тому, кто раскладывает, и сверке,
# поэтому живёт здесь, рядом с адресом памяти.
function Get-KitAgentDir([string]$Worktree) {
    if (-not $Worktree) { return $null }
    return ConvertTo-KitPath (Join-Path (Join-Path $Worktree '.claude') 'agents')
}

# Файл исключений берётся из общего каталога git: у worktree он тот же, что у основной копии,
# и пути в нём — от корня рабочего дерева, одинаковые для всех копий репозитория.
function Get-KitAgentExcludePath([string]$Dir) {
    $common = Invoke-KitGit $Dir @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if (-not $common) { return $null }
    return ConvertTo-KitPath (Join-Path (ConvertTo-KitPath $common) 'info\exclude')
}

# Блок — на каждый связанный каталог репозитория: вторая связь монорепы иначе затирала бы первую.
function Get-KitAgentExcludeMarks([string]$Scope) {
    $key = '.'
    if ($Scope) { $key = $Scope }
    return [pscustomobject]@{ open = "# agents-kit $key"; close = "# /agents-kit $key" }
}

function Get-KitAgentExcludeLine([string]$Scope, [string]$Name) {
    $prefix = ''
    if ($Scope) { $prefix = "$Scope/" }
    return "/$prefix.claude/agents/$Name"
}

# Субагенты, которых кит прятал здесь прошлым прогоном. Файла, которого в блоке нет, кит не
# клал, и трогать его нельзя; но и в блоке не одно его — имя могло быть занято файлом проекта,
# и отслеживаемое спрашивают отдельно.
function Get-KitDeployedAgents([string]$Worktree) {
    $names = [System.Collections.Generic.List[string]]::new()
    $path = Get-KitAgentExcludePath $Worktree
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $names }
    try { $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop) } catch { return $names }
    $marks = Get-KitAgentExcludeMarks (Get-KitScopeSegment (Get-KitTreeRoot $Worktree) $Worktree)
    $inside = $false
    foreach ($line in $lines) {
        $text = $line.Trim()
        if ($text -eq $marks.open) { $inside = $true; continue }
        if ($text -eq $marks.close) { $inside = $false; continue }
        if (-not $inside -or -not $text) { continue }
        $names.Add(($text -split '/')[-1])
    }
    return $names
}

# Что git проекта говорит про каталог субагентов копии: пути от корня дерева, имя — последний
# отрезок. Спрашивают его о разном, а отрезок пути к каталогу один на все вопросы.
function Get-KitAgentGitNames([string]$Worktree, [string[]]$Flags) {
    $names = [System.Collections.Generic.List[string]]::new()
    $tree = Get-KitTreeRoot $Worktree
    if (-not $tree) { return $names }
    $prefix = ''
    $scope = Get-KitScopeSegment $tree $Worktree
    if ($scope) { $prefix = "$scope/" }
    $out = & git -C $tree ls-files @Flags -- "$prefix.claude/agents" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $names }
    foreach ($rel in @($out)) {
        if (-not $rel) { continue }
        $names.Add(($rel -split '/')[-1])
    }
    return $names
}

# Отслеживаемое git рядом принадлежит проекту: такой файл кит не пишет и не удаляет.
function Get-KitTrackedAgents([string]$Worktree) {
    return Get-KitAgentGitNames $Worktree @()
}

# Разложенное, которого git проекта не прячет: укрытие слетело, и такой файл унесёт в историю
# проекта первая же сессия, добавляющая в коммит всё подряд.
function Get-KitUnhiddenAgents([string]$Worktree) {
    return Get-KitAgentGitNames $Worktree @('--others', '--exclude-standard')
}

# Текст субагента для сравнения базы с копией: концы строк и хвостовые пробелы расхождением
# не считаются, остальное — как есть.
function Get-KitAgentText([string]$Path) {
    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return $null }
    if ($null -eq $text) { return '' }
    return ([regex]::Replace($text, "[ `t]*`r?`n", "`n")).TrimEnd()
}

function Get-KitMarkerPath([string]$BaseDir) {
    return (Join-Path $BaseDir 'agents-kit.json')
}

# Шаги перевода базы — plugin\migrations\NNN-<слаг>.ps1, по возрастанию номера. Шаг N переводит
# базу с формата N-1 на N.
function Get-KitMigrations {
    $dir = Join-Path $PSScriptRoot '..\migrations'
    $steps = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
            $m = [regex]::Match($_.Name, '^(\d{3})-(.+)\.ps1$')
            if ($m.Success) { [pscustomobject]@{ number = [int]$m.Groups[1].Value; slug = $m.Groups[2].Value; path = $_.FullName } }
        })
    return @($steps | Sort-Object number)
}

# Формат базы, который ждёт этот кит, — номер последнего шага перевода, без шагов — 1. Числом
# в справке или в коде он разошёлся бы с шагами молча.
function Get-KitFormat {
    $steps = @(Get-KitMigrations)
    if (-not $steps.Count) { return 1 }
    return $steps[-1].number
}

# Список копий базы. Возвращает объект или $null, если файла нет либо он
# не разбирается: список копий отличает базу кита от произвольного каталога, на который
# указатель попал по опечатке. Формат базы — целое «version» от 1: без него переводить
# не с чего, и база не опознаётся.
function Get-KitMarker([string]$BaseDir) {
    $path = Get-KitMarkerPath $BaseDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $marker = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $marker -or $marker.kit -ne 'agents-kit') { return $null }
    $format = $marker.version
    if (-not ($format -is [int] -or $format -is [long]) -or $format -lt 1) { return $null }
    return $marker
}

function Test-KitWorkspaceKnown($Marker, [string]$Workspace) {
    if (-not $Marker -or -not $Marker.workspaces) { return $false }
    $known = @($Marker.workspaces | ForEach-Object { ConvertTo-KitPath $_ })
    return [bool]($known | Where-Object { $_ -ieq $Workspace })
}

# Единственная цепочка состояний связи. Порядок важен: каждое следующее условие
# имеет смысл, только когда предыдущее пройдено, — по несуществующему пути нечего
# читать, а в каталоге без списка копий нечего проверять.
#
#   NotGit      каталог вне git-репозитория
#   NoPointer   ни каталог, ни репозиторий базы не объявили — под китом не числится
#   BaseMissing указатель есть, каталога базы нет
#   NotBase     каталог есть, но списка копий нет, он не читается или в нём нет формата
#   Unlisted    база есть, но эту копию не числит своей
#   Outdated    связь сошлась, а формат базы старше того, что ждёт кит, — перевести
#   Newer       связь сошлась, а базу перевёл кит новее этого — обновить кит
#   Linked      обе стороны сошлись, формат тот, что ждёт кит
function Get-KitLinkState([string]$Dir) {
    $state = [ordered]@{
        status = 'NotGit'; workspace = $null; worktree = $null
        repo = $null; scope = ''; base = $null; marker = $null
        format = $null; kitFormat = $null
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
    $state.format = [int]$marker.version
    $state.kitFormat = Get-KitFormat
    if ($state.format -lt $state.kitFormat) { $state.status = 'Outdated' }
    elseif ($state.format -gt $state.kitFormat) { $state.status = 'Newer' }
    else { $state.status = 'Linked' }
    return [pscustomobject]$state
}

# Что не так с форматом базы и что с этим делать — одной строкой для хука, гейта и скриптов.
# У остальных состояний строки нет.
function Get-KitFormatProblem($State) {
    $migrate = ConvertTo-KitPath (Join-Path $PSScriptRoot 'base-migrate.ps1')
    switch ($State.status) {
        'Outdated' { return "база «$($State.base)» формата $($State.format), а кит ждёт формат $($State.kitFormat) — перевести её: pwsh -NoProfile -File `"$migrate`" -Path `"$($State.worktree)`"" }
        'Newer' { return "базу «$($State.base)» перевёл на формат $($State.format) кит новее этого, а этот знает формат до $($State.kitFormat) — обновить кит" }
    }
    return $null
}
