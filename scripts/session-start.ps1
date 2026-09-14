# agents-kit: хук SessionStart — подать сессии базу знаний её проекта.
#
# Состояние связи определяет link-state.ps1. Здесь только перевод состояния в текст
# для сессии: два первых случая обязаны молчать, остальные — назвать, что чинить.
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

# Знание базы подаётся содержимым, а не путём: его читает каждая сессия, а не только
# та, что пишет. Какие файлы подаются, названо в base-check.ps1.
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

Ниже — файлы знания базы целиком. Это знание проекта, и в этой сессии оно действует. Правила ведения этих файлов — по пути раскладки выше.

$($blocks -join "`n`n")
"@
}

# Решения подаются оглавлением, а не содержимым; почему — CLAUDE.md. Оглавление
# собирает base-check.ps1, здесь только перевод.
function Read-KitDecisionIndex([string]$BaseDir) {
    $dir = ConvertTo-KitPath (Join-Path $BaseDir $script:KitDecisionsDir)
    $index = @(Get-KitDecisionIndex $BaseDir)
    if (-not $index.Count) {
        return @"

## Решения базы

В ``$dir`` решений пока нет. Решение заводится файлом по разделу «Решения» раскладки.
"@
    }
    $lines = $index | ForEach-Object { "- ``$($_.file)`` — когда: $($_.when)" }
    return @"

## Решения базы

Решения лежат в ``$dir``, по файлу на область, и содержимым не поданы. До первого шага задачи прочитать те, которых она касается, — когда и как, говорит раздел «Решения» раскладки.

$($lines -join "`n")
"@
}

# Память задачи адресуется рабочим деревом; почему не веткой и не одним файлом на
# базу — CLAUDE.md. Адрес считает link-state.ps1, здесь только подача.
#
# Подаётся и отсутствие файла: адрес нужен той сессии, которая память ещё только заведёт,
# а «файла нет» — сам по себе ответ на вопрос «что сейчас в работе».
function Read-KitWorkMemory([string]$BaseDir, [string]$Dir) {
    $worktree = Get-KitWorktree $Dir
    $path = Get-KitWorkMemoryPath $BaseDir $worktree
    if (-not $path) { return '' }

    $text = Read-KitMarkdown $path
    if (-not $text) {
        return @"

## Рабочая память

Файла ``$path`` нет — задача в работе не числится. Память заводится по этому адресу, когда задача взята; как она ведётся и закрывается — раскладка базы.
"@
    }

    # Файл объявляет свою рабочую копию, и она сверяется. Слаг пути не взаимно однозначен,
    # да и файл могли положить сюда руками: без сверки сессия продолжила бы чужую работу,
    # считая её своей. Неопознанная память не подаётся — подать её опаснее, чем не подать.
    $declared = Get-KitDeclaredWorktree $text

    if (-not $declared) {
        return @"

## Рабочая память — не подана

Файл ``$path`` есть, но строки ``рабочая копия: <путь>`` в нём нет, и сверить его с ``$worktree`` нечем.

**Содержимое не подано.** Файл лежит по адресу этой копии, поэтому чинится одной строкой: дописать в него ``рабочая копия: $worktree`` и продолжить работу.
"@
    }

    if ($declared -ine $worktree) {
        return @"

## Рабочая память — не подана

Файл ``$path`` объявляет рабочую копию ``$declared``, а сессия открыта в ``$worktree``.

**Содержимое не подано: это чужая работа.** Так выглядит файл памяти, положенный в базу руками, или две рабочие копии, чьи пути дали один адрес. Решает человек.
"@
    }

    return @"

## Рабочая память — ``$worktree``

Файл ``$path``, и ведёт его эта сессия.

$text
"@
}

# Сверка подаётся находками, а не отчётом: чистая база не стоит сессии ни строки.
# Правила сверки — base-check.ps1; здесь только перевод. Упала сама сверка — подача
# базы остаётся: база без сверки лучше, чем сессия без базы.
function Read-KitBaseFindings([string]$BaseDir, [string]$Dir) {
    try { $findings = @(Get-KitBaseFindings $BaseDir (Get-KitWorktree $Dir)) } catch { return '' }
    if (-not $findings.Count) { return '' }
    $lines = $findings | ForEach-Object { "- **$($_.severity)** ``$($_.file)`` — $($_.message)" }
    return @"

## Сверка базы

База разошлась с раскладкой. **FAIL** — чинить до записи знания; перерасход, `local/`, память, файл решений и сломанный флоу в коммите остановят и сам коммит в базу. **WARN** — перечитать и решить; похожее на секрет — строкой человеку. Помеченное «решает человек» не трогать, а показать человеку.

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

    switch ($state.status) {
        # Каталог вне git и репозиторий без указателя: кит молчит целиком —
        # в чужом проекте от него не должно быть ни строки контекста.
        'NotGit' { exit 0 }
        'NoPointer' { exit 0 }

        'BaseMissing' {
            Emit @"
# agents-kit — указатель разорван

Рабочая копия ``$($state.workspace)`` объявляет своей базой знаний ``$($state.base)``, но такого каталога нет.

**Работа со знанием остановлена.** Другая база не подставляется, и знание не пишется никуда — в рабочий репозиторий в том числе. Чинит человек: вернуть каталог базы на место или переставить указатель командой ``git config --local agents-kit.base <путь>``.
"@
        }

        'NotBase' {
            Emit @"
# agents-kit — указатель ведёт не в базу

Каталог ``$($state.base)`` существует, но файла принадлежности ``agents-kit.json`` в нём нет или он не читается. Базой знаний кита этот каталог не является.

**Работа со знанием остановлена.** Так выглядит указатель, поставленный на произвольный каталог. Чинит человек: переставить указатель или связать копию с базой заново.
"@
        }

        'Unlisted' {
            Emit @"
# agents-kit — база не числит эту рабочую копию

Указатель ведёт в базу ``$($state.base)``, но её файл принадлежности не перечисляет ``$($state.workspace)``.

Так выглядит каталог репозитория, скопированный вместе с ``.git``: он унаследовал чужой указатель и начал бы писать знание в чужую базу.

**Работа со знанием остановлена.** Решает человек: копия законная — связать её командой ``link.ps1 -Base "$($state.base)"``; копия случайная — снять указатель командой ``git config --local --unset agents-kit.base``.
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
            $findings = Read-KitBaseFindings $state.base $cwd
            # Память задачи подаётся последней: знание базы верно всегда, а это — то,
            # с чего сессия продолжает работу прямо сейчас.
            $work = Read-KitWorkMemory $state.base $cwd
            # Раскладка подаётся путём, а не текстом: правила нужны только той сессии,
            # что пишет в базу. Путь считается в момент запуска и в файлы кита не попадает.
            $layoutLine = ''
            $layoutPath = ConvertTo-KitPath (Join-Path $refDir 'base-layout.md')
            if (Test-Path -LiteralPath $layoutPath -PathType Leaf) {
                $layoutLine = "`n- Раскладка базы: ``$layoutPath``"
            }
            Emit @"
# agents-kit — проект под китом

- База знаний: ``$($state.base)``
- Рабочая копия: ``$($state.workspace)``$layoutLine

Знание этого проекта живёт в базе и только там. Ниже — инварианты кита; они действуют в этой сессии всегда.

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
    # Молчание безопаснее полуправды; почему ошибка гасится здесь — CLAUDE.md.
}
exit 0
