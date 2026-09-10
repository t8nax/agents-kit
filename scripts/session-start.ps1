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
        # Нечитаемый файл пропускается поодиночке: уронив подачу целиком, хук оставил бы
        # сессию без базы, а молчание в ветке Linked неотличимо от «репозиторий не под китом».
        try { $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop } catch { continue }
        if (-not $text) { continue }
        # Комментарий до сессии не доходит. Иначе закомментированный пример из шаблона
        # приезжает в контекст как факт проекта, и отличить его от факта нечем.
        $text = ([regex]::Replace($text, '(?s)<!--.*?-->', '')).Trim()
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
"@
        }
    }
}
catch {
    # Сломанный хук не должен ломать сессию: молчание безопаснее полуправды.
}
exit 0
