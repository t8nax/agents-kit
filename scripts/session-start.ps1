# agents-kit: хук SessionStart — подать сессии базу знаний её проекта.
#
# Перевод состояния связи из link-state.ps1 в текст для сессии: вне кита — молчание,
# при разрыве — что чинить. Инварианты подаёт этот хук, а не user-level CLAUDE.md: так они
# приходят только под китом.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

function Emit([string]$Text) {
    $payload = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName     = 'SessionStart'
            additionalContext = $Text
        }
    }
    $payload | ConvertTo-Json -Depth 5 -Compress
}

# Знание базы подаётся содержимым: его читает каждая сессия. Список — base-check.ps1.
function Read-KitBaseKnowledge([string]$BaseDir) {
    $blocks = @()
    foreach ($name in $script:KitServedFiles) {
        $text = Read-KitMarkdown (Join-Path $BaseDir $name)
        if (-not $text) { continue }
        $blocks += "**$name**`n`n$text"
    }
    if (-not $blocks) { return '' }

    return @"

---

Файлы знания базы целиком; в этой сессии они действуют.

$($blocks -join "`n`n")
"@
}

# Решения подаются оглавлением, собирает его base-check.ps1. Содержимым один файл решений рос
# числом тем, и каждая сессия платила за все; оглавление подаёт хук, иначе сессия выбирала бы
# по памяти и пропуск прошёл бы молча.
function Read-KitDecisionIndex([string]$BaseDir) {
    $dir = ConvertTo-KitPath (Join-Path $BaseDir $script:KitDecisionsDir)
    $index = @(Get-KitDecisionIndex $BaseDir)
    if (-not $index.Count) {
        return @"

## Решения базы

В ``$dir`` решений пока нет; заводятся по разделу «Решения» раскладки.
"@
    }
    $lines = $index | ForEach-Object { "- ``$($_.file)`` — когда: $($_.when)" }
    return @"

## Решения базы

``$dir``, по файлу на область, содержимым не поданы; когда читать — раздел «Решения» раскладки.

$($lines -join "`n")
"@
}

# Память задачи адресуется рабочей копией в дереве сессии: она держит ровно одну линию работы;
# взяты под кит два каталога одного дерева — это две копии и две памяти.
# Общий файл на копию затирали бы молча; ветка не уникальна (две копии на master), уходит при
# переименовании, а на постоянной ветке «файл есть» не значит «задача в работе».
# Подаётся и отсутствие файла: адрес нужен сессии, которая память заведёт, а «файла нет» —
# ответ «в работе ничего».
function Read-KitWorkMemory([string]$BaseDir, [string]$Worktree) {
    $worktree = $Worktree
    $path = Get-KitWorkMemoryPath $BaseDir $worktree
    if (-not $path) { return '' }

    $text = Read-KitMarkdown $path
    if (-not $text) {
        return @"

## Рабочая память

Файла ``$path`` нет — задача в работе не числится. Память заводится по этому адресу, когда задача взята, — по правилам памяти задачи.
"@
    }

    # Неопознанная память не подаётся: получив чужую, сессия продолжила бы чужую работу как свою.
    # Опознание — строкой внутри, не именем: слаг не взаимно однозначен, файл могли положить руками.
    $declared = Get-KitDeclaredWorktree $text

    if (-not $declared) {
        return @"

## Рабочая память — не подана

В файле ``$path`` нет строки ``рабочая копия: <путь>``, и **содержимое не подано.** Файл лежит по адресу этой копии: дописать в него ``рабочая копия: $worktree`` и продолжить работу.
"@
    }

    if ($declared -ine $worktree) {
        return @"

## Рабочая память — не подана

Файл ``$path`` объявляет рабочую копию ``$declared``, а сессия открыта в ``$worktree``. **Содержимое не подано: это чужая работа** — файл, положенный руками, или две копии с одним адресом. Решает оператор.
"@
    }

    return @"

## Рабочая память — ``$worktree``

Файл ``$path``, и ведёт его эта сессия.

$text
"@
}

# Сверка подаётся находками: чистая база не стоит ни строки. Упала сверка — подача базы
# остаётся: база без сверки лучше, чем сессия без базы.
function Read-KitBaseFindings([string]$BaseDir, [string]$Worktree) {
    try { $findings = @(Get-KitBaseFindings $BaseDir $Worktree) } catch { return '' }
    if (-not $findings.Count) { return '' }
    $lines = $findings | ForEach-Object { "- **$($_.severity)** ``$($_.file)`` — $($_.message)" }
    return @"

## Сверка базы

**FAIL** — чинить до записи знания. **WARN** — перечитать и решить. Похожее на секрет и помеченное «решает оператор» не трогать, а назвать вопросом оператору.

$($lines -join "`n")
"@
}

try {
    . (Join-Path $PSScriptRoot 'link-state.ps1')
    . (Join-Path $PSScriptRoot 'base-check.ps1')

    $raw = [Console]::In.ReadToEnd()
    $cwd = $null
    if ($raw) { try { $cwd = (ConvertFrom-Json $raw).cwd } catch { } }
    if (-not $cwd) { $cwd = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }

    $state = Get-KitLinkState $cwd

    # Ключом связи назван тот каталог, для которого она записана: у связи по подкаталогу
    # это подсекция, и командой ремонта оператору нужна именно она.
    $pointerKey = Get-KitPointerKey $state.scope
    $linkScopeArg = ''
    if ($state.scope) { $linkScopeArg = ' -Scope Directory' }

    switch ($state.status) {
        # Каталог вне git, а также каталог, для которого базы не объявил ни он сам,
        # ни его репозиторий: кит молчит целиком.
        'NotGit' { exit 0 }
        'NoPointer' { exit 0 }

        'BaseMissing' {
            Emit @"
# agents-kit — указатель разорван

Рабочая копия ``$($state.workspace)`` объявляет базой ``$($state.base)``, но такого каталога нет.

**Работа со знанием остановлена:** другая база не подставляется, знание не пишется никуда. Чинит оператор — вернуть каталог базы или переставить указатель: ``git config --local $pointerKey <путь>``.
"@
        }

        'NotBase' {
            Emit @"
# agents-kit — указатель ведёт не в базу

В каталоге ``$($state.base)`` нет читаемого ``agents-kit.json`` — это не база кита, а указатель на произвольный каталог.

**Работа со знанием остановлена.** Чинит оператор: переставить указатель или связать копию заново.
"@
        }

        'Unlisted' {
            Emit @"
# agents-kit — база не числит эту рабочую копию

Указатель ведёт в базу ``$($state.base)``, но она не числит ``$($state.workspace)``. Так выглядит каталог, скопированный вместе с ``.git``.

**Работа со знанием остановлена.** Решает оператор: копия законная — ``link.ps1$linkScopeArg -Base "$($state.base)"``; случайная — ``git config --local --unset $pointerKey``.
"@
        }

        'Linked' {
            $refDir = Join-Path $PSScriptRoot '..\reference'
            $invPath = Join-Path $refDir 'invariants.md'
            $invariants = ''
            if (Test-Path -LiteralPath $invPath -PathType Leaf) {
                $invariants = (Get-Content -LiteralPath $invPath -Raw).Trim()
            }
            $knowledge = Read-KitBaseKnowledge $state.base
            $decisions = Read-KitDecisionIndex $state.base
            $findings = Read-KitBaseFindings $state.base $state.worktree
            # Память — последней: с неё сессия продолжает работу прямо сейчас.
            $work = Read-KitWorkMemory $state.base $state.worktree
            # Справки подаются путём: нужны они только пишущей сессии.
            $layoutLine = ''
            foreach ($ref in @(@('base-layout.md', 'Раскладка базы'), @('task-memory.md', 'Правила памяти задачи'), @('backlog-record.md', 'Правила записи бэклога'))) {
                $refPath = ConvertTo-KitPath (Join-Path $refDir $ref[0])
                if (Test-Path -LiteralPath $refPath -PathType Leaf) {
                    $layoutLine += "`n- $($ref[1]): ``$refPath``"
                }
            }
            $nameLine = ''
            $name = Get-KitProjectName $state.base
            if ($name) { $nameLine = "- Проект: $name`n" }
            # Связан подкаталог — репозиторий назван отдельной строкой: под китом часть
            # его, и сессия не должна считать своим всё дерево.
            $repoLine = ''
            if ($state.scope) { $repoLine = "`n- Репозиторий: ``$($state.repo)`` — под китом только каталог выше" }
            Emit @"
# agents-kit — проект под китом

$nameLine- База знаний: ``$($state.base)``
- Рабочая копия: ``$($state.workspace)``$repoLine$layoutLine

Знание проекта живёт только в базе. Ниже — инварианты кита, они действуют всегда.

$invariants
$knowledge
$decisions
$findings
$work
"@
        }
    }
}
catch {
}
exit 0
