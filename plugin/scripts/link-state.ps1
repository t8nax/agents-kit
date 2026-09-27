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

# Корень дерева этой сессии и корень репозитория — одним вызовом git: вызовы git и есть
# основное время хука на старте каждой сессии. Worktree приводится к репозиторию, от которого заведён.
function Get-KitGitRoots([string]$Dir) {
    $out = & git -C $Dir rev-parse --show-toplevel --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $lines = @($out | Where-Object { $_ } | ForEach-Object { $_.ToString().Trim() })
    if ($lines.Count -lt 2) { return $null }
    $tree = ConvertTo-KitPath $lines[0]
    $repo = $tree
    $common = ConvertTo-KitPath $lines[1]
    if ($common -match '\\.git$') { $repo = ConvertTo-KitPath (Split-Path $common -Parent) }
    return [pscustomobject]@{ tree = $tree; repo = $repo }
}

function Get-KitRepoRoot([string]$Dir) {
    $roots = Get-KitGitRoots $Dir
    if (-not $roots) { return $null }
    return $roots.repo
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

# Все указатели репозитория: отрезок → путь базы, у корневого ключа отрезок пустой. Одним
# вызовом, а не по вызову git на сегмент пути; из повторов ключа действует последний.
function Get-KitPointers([string]$Dir) {
    $map = [ordered]@{}
    $raw = & git -C $Dir config --local --get-regexp --null '^agents-kit\.(.+\.)?base$' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $map }
    foreach ($record in (($raw -join "`n") -split [char]0)) {
        if (-not $record) { continue }
        $break = $record.IndexOf("`n")
        if ($break -lt 1) { continue }
        $key = $record.Substring(0, $break)
        $value = $record.Substring($break + 1).Trim()
        if (-not $value) { continue }
        if ($key -notmatch '^agents-kit\.(?:(.+)\.)?base$') { continue }
        $map[([string]$Matches[1]).ToLowerInvariant()] = ConvertTo-KitPath $value
    }
    return $map
}

# Связанные подкаталоги репозитория — указатели без корневого ключа.
function Get-KitScopedPointers([string]$Dir) {
    $map = Get-KitPointers $Dir
    if ($map.Contains('')) { $map.Remove('') }
    return $map
}

# Указатель этого каталога — ближайший связанный предок внутри дерева, а нет такого,
# то корневой ключ репозитория. Вне связанного каталога сессия не получает ничего, как без указателя.
function Resolve-KitPointer([string]$Dir, [string]$Scope) {
    $pointers = Get-KitPointers $Dir
    $candidate = $Scope
    while ($candidate) {
        if ($pointers.Contains($candidate)) {
            return [pscustomobject]@{ scope = $candidate; base = $pointers[$candidate] }
        }
        $cut = $candidate.LastIndexOf('/')
        if ($cut -lt 0) { break }
        $candidate = $candidate.Substring(0, $cut)
    }
    if (-not $pointers.Contains('')) { return $null }
    return [pscustomobject]@{ scope = ''; base = $pointers[''] }
}

# Оба ключа пути разом. Свести их нельзя: worktree потерял бы память или каждый worktree
# потребовал бы записи в базе.
#   workspace  ключ связи   что взято под кит, в основной копии: проект, а не линия работы
#   worktree   ключ памяти  то же самое в дереве этой сессии: у worktree оно своё
# Ключ — абсолютный путь, не git remote: у каталога, скопированного с .git, тот же origin,
# и remote пропустил бы ровно тот случай, ради которого проверка заведена.
function Get-KitRoots([string]$Dir) {
    $git = Get-KitGitRoots $Dir
    if (-not $git) { return $null }
    $tree = $git.tree
    $repo = $git.repo
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

function ConvertTo-KitSlug([string]$Text) {
    if (-not $Text) { return $null }
    $slug = ([regex]::Replace($Text.ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-')).Trim('-')
    if (-not $slug) { return $null }
    return $slug
}

# Имя машины — считается при каждом запуске и нигде не хранится: файл кита с ним уехал бы
# к следующему, кто поставит кит, а файл базы — на соседнюю машину. COMPUTERNAME берётся первым:
# его наследует дочерний процесс, и стенд им подменяет машину.
function Get-KitMachine {
    $name = $env:COMPUTERNAME
    if (-not $name) { try { $name = [Environment]::MachineName } catch { $name = $null } }
    return ConvertTo-KitSlug $name
}

# Каталог памяти этой машины. Машина — каталогом, а не частью имени файла: имя машины
# с дефисом неотличимо от начала слага пути, а каталог отделяет свою память от чужой целиком.
# Root — репозиторий, где лежит work\: личный репозиторий, а у шага перевода с прежнего
# формата — сама база.
function Get-KitMemoryDir([string]$Root) {
    $machine = Get-KitMachine
    if (-not $Root -or -not $machine) { return $null }
    return ConvertTo-KitPath (Join-Path $Root ('work\' + $machine))
}

# Адрес памяти — каталог машины и слаг полного пути: одинаковые пути на двух машинах не делят
# файл, одноимённые каталоги в разных родителях тоже; нижний регистр — NTFS его не различает.
# Неоднозначность слага («a\b» и «a-b») ловит строка «рабочая копия» внутри файла.
function Get-KitWorkMemoryPath([string]$Root, [string]$Worktree) {
    $dir = Get-KitMemoryDir $Root
    $slug = ConvertTo-KitSlug $Worktree
    if (-not $dir -or -not $slug) { return $null }
    return ConvertTo-KitPath (Join-Path $dir ($slug + '.md'))
}

# Личный репозиторий оператора — local\me базы, свой git: бэклог, память задач и их артефакты.
# В local\, чтобы общая база его не видела: коллегам память и бэклог не нужны, а коммит памяти
# на каждом шаге шёл бы в общий remote.
function Get-KitPersonalDir([string]$BaseDir) {
    if (-not $BaseDir) { return $null }
    return ConvertTo-KitPath (Join-Path $BaseDir 'local\me')
}

# Личный репозиторий — корень своего git: без своего .git коммит памяти ушёл бы в общую базу,
# где local\ игнорируется, и молча не случился бы. Смотрится .git, а не git: вызовы git — основное
# время хука на старте каждой сессии.
function Test-KitPersonalRepo([string]$BaseDir) {
    $dir = Get-KitPersonalDir $BaseDir
    return [bool]($dir -and (Test-Path -LiteralPath (Join-Path $dir '.git')))
}

# Репозиторий, где не закончено сведение с remote: rebase или merge встал на конфликте. Смотрятся
# файлы в .git, а не git: проверка идёт на старте каждой сессии.
function Test-KitUnmerged([string]$Repo) {
    if (-not $Repo) { return $false }
    $git = Join-Path $Repo '.git'
    foreach ($mark in 'rebase-merge', 'rebase-apply', 'MERGE_HEAD') {
        if (Test-Path -LiteralPath (Join-Path $git $mark)) { return $true }
    }
    return $false
}

# Имя оператора — латиница в нижнем регистре, цифры и дефис между ними: оно же имя его папки
# в people\, и форма одна на любой диск и любой git.
function Test-KitOperatorName([string]$Name) {
    return [bool]($Name -and $Name -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$')
}

# Папка оператора в общей базе — его флоу и субагенты.
function Get-KitOperatorDir([string]$BaseDir, [string]$Name) {
    if (-not $BaseDir -or -not (Test-KitOperatorName $Name)) { return $null }
    return ConvertTo-KitPath (Join-Path $BaseDir ('people\' + $Name))
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

# agents-kit.json базы. Возвращает объект или $null, если файла нет либо он
# не разбирается: этот файл отличает базу кита от произвольного каталога, на который
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

# Что эта машина знает о базе — local\me.json, вне git: список копий машины (workspaces) и имя
# оператора (operator). Пути копий у каждой машины свои, и общий файл давал бы каждой машине
# висящие записи соседней; имя — одно на машину и базу, как и личный репозиторий рядом.
function Get-KitWorkspacesPath([string]$BaseDir) {
    return (Join-Path $BaseDir 'local\me.json')
}

# Файл машины — объект; кто пишет одно поле, переписывает его целиком и сохраняет другое.
# Файла нет — пустой объект; файл не разбирается — $null: «пусто» от «файл испорчен» отличает
# тот, кто его перепишет.
function Get-KitWorkspaceList([string]$BaseDir) {
    $path = Get-KitWorkspacesPath $BaseDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ workspaces = @() } }
    try { $list = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
    if ($list -isnot [pscustomobject]) { return $null }
    return $list
}

function Save-KitWorkspaceList([string]$BaseDir, $List) {
    $path = Get-KitWorkspacesPath $BaseDir
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    $List | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
}

# Имя оператора этой машины; не названо или не по форме — $null.
function Get-KitOperatorName([string]$BaseDir) {
    $list = Get-KitWorkspaceList $BaseDir
    if (-not $list -or -not ($list.PSObject.Properties.Name -contains 'operator')) { return $null }
    $name = [string]$list.operator
    if (-not (Test-KitOperatorName $name)) { return $null }
    return $name
}

# Имя пишется один раз на машину: другое имя поверх названного подменило бы, чьи флоу
# и субагенты видит каждая копия этой машины.
function Set-KitOperatorName([string]$BaseDir, [string]$Name) {
    if (-not (Test-KitOperatorName $Name)) { throw "имя оператора «$Name» не по форме — латиница в нижнем регистре, цифры и дефис между ними: b-ignatyev" }
    $list = Get-KitWorkspaceList $BaseDir
    if (-not $list) { throw "$(Get-KitWorkspacesPath $BaseDir) не разбирается — разобраться должен оператор" }
    $current = $null
    if ($list.PSObject.Properties.Name -contains 'operator') { $current = [string]$list.operator }
    if ($current -ceq $Name) { return }
    if ($current) { throw "на этой машине оператор базы уже назван «$current» — другое имя поверх него не пишется" }
    $list | Add-Member -NotePropertyName 'operator' -NotePropertyValue $Name -Force
    Save-KitWorkspaceList $BaseDir $list
}

function Get-KitWorkspaces([string]$BaseDir) {
    $list = Get-KitWorkspaceList $BaseDir
    if (-not $list -or -not $list.workspaces) { return @() }
    return @($list.workspaces | Where-Object { $_ } | ForEach-Object { ConvertTo-KitPath $_ })
}

function Test-KitWorkspaceKnown([string]$BaseDir, [string]$Workspace) {
    return [bool](@(Get-KitWorkspaces $BaseDir) | Where-Object { $_ -ieq $Workspace })
}

# Единственная цепочка состояний связи. Порядок важен: каждое следующее условие
# имеет смысл, только когда предыдущее пройдено, — по несуществующему пути нечего
# читать, а в каталоге без формата нечего проверять. Формат — до списка копий: где лежит
# список, решает формат, и базу прежнего формата кит иначе не смог бы даже перевести.
#
#   NotGit      каталог вне git-репозитория
#   NoPointer   ни каталог, ни репозиторий базы не объявили — под китом не числится
#   BaseMissing указатель есть, каталога базы нет
#   Unmerged    в базе или в личном репозитории не закончено сведение с remote — до формата: посреди
#               конфликта метки могут стоять в любом файле, и в agents-kit.json тоже
#   NotBase    каталог есть, но agents-kit.json нет, он не читается или в нём нет формата
#   Outdated    формат базы старше того, что ждёт кит, — перевести
#   Newer       базу перевёл кит новее этого — обновить кит
#   Unlisted    база есть, но на этой машине эту копию не числит своей
#   Unnamed     на этой машине оператор базы не назван — чьи флоу и субагенты, не опознать
#   NoPersonal  личного репозитория оператора на этой машине нет — памяти и бэклогу негде жить
#   Linked      всё сошлось, формат тот, что ждёт кит
function Get-KitLinkState([string]$Dir) {
    $state = [ordered]@{
        status = 'NotGit'; workspace = $null; worktree = $null
        repo = $null; scope = ''; base = $null; marker = $null
        format = $null; kitFormat = $null
        operator = $null; personal = $null; people = $null; unmerged = $null
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
    foreach ($candidate in $state.base, (Get-KitPersonalDir $state.base)) {
        if (Test-KitUnmerged $candidate) {
            $state.unmerged = $candidate
            $state.status = 'Unmerged'
            return [pscustomobject]$state
        }
    }
    $state.status = 'NotBase'

    $marker = Get-KitMarker $state.base
    if (-not $marker) { return [pscustomobject]$state }
    $state.marker = $marker
    $state.format = [int]$marker.version
    $state.kitFormat = Get-KitFormat
    if ($state.format -lt $state.kitFormat) { $state.status = 'Outdated'; return [pscustomobject]$state }
    if ($state.format -gt $state.kitFormat) { $state.status = 'Newer'; return [pscustomobject]$state }
    $state.status = 'Unlisted'

    if (-not (Test-KitWorkspaceKnown $state.base $state.workspace)) { return [pscustomobject]$state }
    $state.status = 'Unnamed'

    $state.operator = Get-KitOperatorName $state.base
    if (-not $state.operator) { return [pscustomobject]$state }
    $state.people = Get-KitOperatorDir $state.base $state.operator
    $state.personal = Get-KitPersonalDir $state.base
    $state.status = 'NoPersonal'

    if (-not (Test-KitPersonalRepo $state.base)) { return [pscustomobject]$state }
    $state.status = 'Linked'
    return [pscustomobject]$state
}

# Команда, которой заводят место оператора на этой машине, — одна для хука, отчёта связи
# и сверки: имя и личный репозиторий заводит base-init.ps1.
function Get-KitOperatorCommand([string]$BaseDir, [string]$Name) {
    $init = ConvertTo-KitPath (Join-Path $PSScriptRoot 'base-init.ps1')
    if (-not $Name) { $Name = '<имя оператора>' }
    return "pwsh -NoProfile -File `"$init`" -Path `"$BaseDir`" -Operator $Name"
}

# Что не так с форматом базы и что с этим делать — одной строкой для хука, гейта и скриптов.
# У остальных состояний строки нет.
function Get-KitFormatProblem($State) {
    $migrate = ConvertTo-KitPath (Join-Path $PSScriptRoot 'base-migrate.ps1')
    switch ($State.status) {
        'Outdated' {
            $operator = Get-KitOperatorName $State.base
            if (-not $operator) { $operator = '<имя оператора>' }
            return "база «$($State.base)» формата $($State.format), а кит ждёт формат $($State.kitFormat) — перевести её: pwsh -NoProfile -File `"$migrate`" -Path `"$($State.worktree)`" -Operator $operator"
        }
        'Newer' { return "базу «$($State.base)» перевёл на формат $($State.format) кит новее этого, а этот знает формат до $($State.kitFormat) — обновить кит" }
    }
    return $null
}

# Команда сведения с remote — одна для хука, скиллов и отчёта: базу или личный репозиторий
# называет -Repo.
function Get-KitSyncCommand([string]$Worktree, [string]$Repo, [string]$Action) {
    $sync = ConvertTo-KitPath (Join-Path $PSScriptRoot 'sync.ps1')
    return "pwsh -NoProfile -File `"$sync`" -Path `"$Worktree`" -Repo $Repo -Action $Action"
}

# Что с незаконченным сведением и чем его доделать — одной строкой для хука, гейта, link.ps1
# и sync.ps1. Файлы конфликта спрашиваются у git только в этом состоянии.
function Get-KitUnmergedProblem($State) {
    if ($State.status -ne 'Unmerged') { return $null }
    $repo = 'Base'
    $what = 'базе'
    if ($State.unmerged -ine $State.base) { $repo = 'Personal'; $what = 'личном репозитории' }
    $files = @(& git -C $State.unmerged diff --name-only --diff-filter=U 2>$null | Where-Object { $_ })
    $named = 'файлы не названы git'
    if ($files.Count) { $named = ($files | ForEach-Object { "``$_``" }) -join ', ' }
    $layout = ConvertTo-KitPath (Join-Path $PSScriptRoot '..\reference\base-layout.md')
    return "в $what «$($State.unmerged)» не закончено сведение с remote, конфликт: $named — свести по разделу «Когда параллельные задачи сходятся» раскладки базы ``$layout`` и доделать: $(Get-KitSyncCommand $State.worktree $repo 'Continue')"
}
