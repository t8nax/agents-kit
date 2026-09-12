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

# Файл базы, как его видит сессия. Нечитаемый файл — пустая строка, а не исключение:
# уронив подачу целиком, хук оставил бы сессию без базы, а молчание в ветке Linked
# неотличимо от «репозиторий не под китом».
#
# Комментарий до сессии не доходит, и режется он здесь один раз на все подачи. Иначе
# закомментированный пример из шаблона приезжает в контекст как факт проекта, и отличить
# его от факта нечем.
function Read-KitMarkdown([string]$Path) {
    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return '' }
    if (-not $text) { return '' }
    return ([regex]::Replace($text, '(?s)<!--.*?-->', '')).Trim()
}

# Знание базы подаётся содержимым, а не путём: его читает каждая сессия, а не только
# та, что пишет. Списка файлов здесь нет намеренно — он стал бы вторыми правилами
# раскладки рядом с base-layout.md и разъехался бы с ней молча; берётся то, что лежит
# в корне базы. Подкаталоги не трогаются: в корне и лежит обязательное к прочтению.
function Read-KitBaseKnowledge([string]$BaseDir) {
    try {
        $files = @(Get-ChildItem -LiteralPath $BaseDir -File -ErrorAction Stop |
            Where-Object { $_.Extension -ieq '.md' } | Sort-Object Name)
    }
    catch { return '' }

    $blocks = @()
    foreach ($file in $files) {
        $text = Read-KitMarkdown $file.FullName
        if (-not $text) { continue }
        $blocks += "**$($file.Name)**`n`n$text"
    }
    if (-not $blocks) { return '' }

    return @"

---

Ниже — файлы базы целиком. Это знание проекта, и в этой сессии оно действует. Правила ведения этих файлов — по пути раскладки выше.

$($blocks -join "`n`n")
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

Файла ``$path`` нет — задача в работе не числится. Память заводится первым шагом работы по этому адресу и им же удаляется, когда задача закрыта.
"@
    }

    # Файл объявляет свою рабочую копию, и она сверяется. Слаг пути не взаимно однозначен,
    # да и файл могли положить сюда руками: без сверки сессия продолжила бы чужую работу,
    # считая её своей. Неопознанная память не подаётся — подать её опаснее, чем не подать.
    $declared = $null
    $match = [regex]::Match($text, '(?im)^\s*рабочая\s+копия\s*:\s*(.+?)\s*$')
    if ($match.Success) { $declared = ConvertTo-KitPath $match.Groups[1].Value }

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

try {
    . (Join-Path $PSScriptRoot 'link-state.ps1')

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
$work
"@
        }
    }
}
catch {
    # Молчание безопаснее полуправды; почему ошибка гасится здесь — CLAUDE.md.
}
exit 0
