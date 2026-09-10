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
"@
        }
    }
}
catch {
    # Сломанный хук не должен ломать сессию: молчание безопаснее полуправды.
}
exit 0
