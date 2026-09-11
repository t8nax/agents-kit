# agents-kit: то ли получает сессия на старте — в каждом состоянии связи с базой и на
# любой ветке — и молчит ли кит там, где его не звали.
#   pwsh -NoProfile -File scripts\check-session.ps1 [-KeepTemp]
#
# Строит тестовые каталоги во временной папке, гоняет через настоящий хук каждый
# случай, который обязан отличаться от соседнего, и убирает за собой. Проверять
# это руками значит каждый раз заново заводить репозиторий, базу, копию и worktree —
# и на третий раз проверять не всё.
[CmdletBinding()]
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$hook = Join-Path $PSScriptRoot 'session-start.ps1'
$link = Join-Path $PSScriptRoot 'link.ps1'
$init = Join-Path $PSScriptRoot 'base-init.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("agents-kit-check-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

# Первый коммит базы делает base-init.ps1 сам, и без этих переменных он зависел бы
# от глобального конфига машины — проверка стала бы плавающей.
$env:GIT_AUTHOR_NAME = 'agents-kit-check'
$env:GIT_AUTHOR_EMAIL = 'check@local'
$env:GIT_COMMITTER_NAME = 'agents-kit-check'
$env:GIT_COMMITTER_EMAIL = 'check@local'

$script:passed = 0
$script:failed = 0
function Ok  ([string]$m) { Write-Host "[ OK ]   $m"; $script:passed++ }
function Bad ([string]$m) { Write-Host "[ FAIL ] $m" -ForegroundColor Red; $script:failed++ }

# Хук читает stdin и завершает себя exit'ом, поэтому зовётся дочерним процессом,
# а не дот-сорсингом: иначе он унёс бы с собой и самотест.
function Invoke-Hook([string]$Dir) {
    $payload = @{ cwd = $Dir } | ConvertTo-Json -Compress
    $out = $payload | & pwsh -NoProfile -File $hook 2>$null
    if (-not $out) { return '' }
    $text = ($out -join "`n").Trim()
    if (-not $text) { return '' }
    try { return [string](($text | ConvertFrom-Json).hookSpecificOutput.additionalContext) }
    catch { return "!!НЕ-JSON!! $text" }
}

function Check([string]$Name, [scriptblock]$Body) {
    try {
        $problem = & $Body
        if ($problem) { Bad "$Name — $problem" } else { Ok $Name }
    }
    catch { Bad "$Name — исключение: $($_.Exception.Message)" }
}

function ExpectSilent([string]$Dir) {
    $got = Invoke-Hook $Dir
    if ($got) { return "ожидалось молчание, получено: $($got.Split("`n")[0])" }
    return $null
}

function ExpectText([string]$Dir, [string]$Needle) {
    $got = Invoke-Hook $Dir
    if (-not $got) { return "ожидался текст про «$Needle», хук промолчал" }
    if ($got -notmatch [regex]::Escape($Needle)) { return "в ответе нет «$Needle»: $($got.Split("`n")[0])" }
    return $null
}

function ExpectNoText([string]$Dir, [string]$Needle) {
    $got = Invoke-Hook $Dir
    if (-not $got) { return "хук промолчал — проверять нечего" }
    if ($got -match [regex]::Escape($Needle)) { return "в ответе есть «$Needle», хотя его там быть не должно" }
    return $null
}

# Состояние связи одно, а переводят его двое: хук в контекст сессии и link.ps1
# в консоль. Регресс во втором переводчике первый не поймает, поэтому проверяются оба.
function ExpectLinkReport([string]$Dir, [int]$Code, [string]$Needle) {
    $out = & pwsh -NoProfile -File $link -Path $Dir 2>&1
    $code = $LASTEXITCODE
    $text = ($out -join "`n")
    if ($code -ne $Code) { return "код возврата $code, ожидался $Code" }
    if ($Needle -and $text -notmatch [regex]::Escape($Needle)) { return "в отчёте нет «$Needle»" }
    return $null
}

function Invoke-BaseInit([string]$Dir) {
    $out = & pwsh -NoProfile -File $init -Path $Dir 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

function New-TestRepo([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    & git -C $Path init -q
    & git -C $Path config user.email 'check@local'
    & git -C $Path config user.name 'agents-kit-check'
    Set-Content -LiteralPath (Join-Path $Path 'a.txt') -Value 'x'
    & git -C $Path add a.txt
    & git -C $Path commit -qm init | Out-Null
}

$plain   = Join-Path $root 'plain'
$repo    = Join-Path $root 'repo'
$copy    = Join-Path $root 'repo-copy'
$wt      = Join-Path $root 'wt'
$base    = Join-Path $root 'base'
$moved   = Join-Path $root 'base-moved'
$notbase = Join-Path $root 'notbase'
$inrepo  = Join-Path $repo 'knowledge'

try {
    New-Item -ItemType Directory -Force -Path $plain, $notbase | Out-Null
    New-TestRepo $repo
    Write-Host "Временные каталоги: $root"
    Write-Host ''

    Check 'каталог вне git — хук молчит' { ExpectSilent $plain }
    Check 'репозиторий без указателя — хук молчит' { ExpectSilent $repo }

    # База внутри рабочей копии — единственный случай, когда base-init обязан отказать:
    # инвариант про каталог знания в чужом репозитории исполняется, а не объясняется.
    Check 'база внутри рабочей копии — отказ' {
        $r = Invoke-BaseInit $inrepo
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if (Test-Path -LiteralPath $inrepo) { return 'каталог всё-таки создан' }
        return $null
    }

    Check 'база заведена — каркас, репозиторий и коммит' {
        $r = Invoke-BaseInit $base
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        foreach ($f in 'product.md', 'boundaries.md', 'decisions.md', '.gitignore') {
            if (-not (Test-Path -LiteralPath (Join-Path $base $f) -PathType Leaf)) { return "нет файла $f" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $base '.git') -PathType Container)) { return 'нет репозитория базы' }
        & git -C $base rev-parse --verify HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return 'каркас не закоммичен' }
        return $null
    }

    # Повторный прогон — то, чем база потом обновляется: довезти появившийся файл,
    # не тронув заполненный. Ошибка здесь стоит заполненной базы.
    Check 'повторный прогон — заполненное не тронуто, отсутствующее довезено' {
        $product = Join-Path $base 'product.md'
        Set-Content -LiteralPath $product -Value 'заполнено человеком' -Encoding utf8
        Remove-Item -LiteralPath (Join-Path $base 'decisions.md') -Force
        $r = Invoke-BaseInit $base
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath $product -Raw).Trim() -ne 'заполнено человеком') { return 'product.md перезаписан' }
        if (-not (Test-Path -LiteralPath (Join-Path $base 'decisions.md') -PathType Leaf)) { return 'decisions.md не довезён' }
        return $null
    }

    # Дальше — склейка с первым механизмом: базу завёл base-init.ps1, связывает link.ps1.
    & pwsh -NoProfile -File $link -Path $repo -Base $base | Out-Null
    Check 'связанная копия — путь базы в контексте' { ExpectText $repo $base }
    Check 'связанная копия — инварианты в контексте' { ExpectText $repo 'Три слоя' }
    Check 'связанная копия — путь раскладки в контексте' { ExpectText $repo 'base-layout.md' }
    Check 'связанная копия — отчёт link.ps1 зелёный' { ExpectLinkReport $repo 0 'связь двусторонняя' }

    # Знание базы подаётся содержимым: ради этого база и заведена. Проверяется на
    # строке, которой неоткуда взяться нигде, кроме файла базы.
    Check 'связанная копия — содержимое базы в контексте' {
        Set-Content -LiteralPath (Join-Path $base 'product.md') -Encoding utf8 `
            -Value '# Продукт', '', 'сверка остатков идёт ночным прогоном'
        return ExpectText $repo 'сверка остатков идёт ночным прогоном'
    }

    # Закомментированный пример из шаблона — тот случай, ради которого хук режет комментарии.
    Check 'пример из HTML-комментария в контекст не попадает' { ExpectNoText $repo 'EF Core' }

    # Один пропавший файл не должен уносить с собой подачу остальных.
    Check 'файла базы нет — подача остального цела' {
        Remove-Item -LiteralPath (Join-Path $base 'boundaries.md') -Force
        return ExpectText $repo 'сверка остатков идёт ночным прогоном'
    }

    # Память задачи адресуется веткой. Проверяется именно разделение: своя приезжает,
    # соседняя — нет. Ошибка здесь стоит того, что сессия продолжит чужую работу.
    $branch = ((& git -C $repo branch --show-current) | Select-Object -First 1).ToString().Trim()
    $work = Join-Path $base 'work'
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    Check 'памяти нет — сессия получает её адрес' { ExpectText $repo "work\$branch.md" }

    Check 'память своей ветки — в контексте' {
        Set-Content -LiteralPath (Join-Path $work "$branch.md") -Encoding utf8 `
            -Value '# Разбор накладной', '- Следующий шаг: дочитать формат позиции'
        return ExpectText $repo 'дочитать формат позиции'
    }

    Check 'память соседней ветки — не в контексте' {
        Set-Content -LiteralPath (Join-Path $work 'neighbour.md') -Encoding utf8 `
            -Value '- Следующий шаг: это работа соседней ветки'
        return ExpectNoText $repo 'это работа соседней ветки'
    }

    # Слэш в имени ветки — обычное дело, и путь он задаёт настоящим подкаталогом:
    # иначе feature/x и feature-x делят один файл памяти.
    Check 'ветка со слэшем — память в подкаталоге' {
        & git -C $repo checkout -q -b feature/import
        New-Item -ItemType Directory -Force -Path (Join-Path $work 'feature') | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'feature\import.md') -Encoding utf8 `
            -Value '- Следующий шаг: разрезать разбор на части'
        $problem = ExpectText $repo 'разрезать разбор на части'
        & git -C $repo checkout -q $branch
        return $problem
    }

    Copy-Item -LiteralPath $repo -Destination $copy -Recurse -Force
    Check 'копия каталога вместе с .git — остановка' { ExpectText $copy 'не числит эту рабочую копию' }
    Check 'копия каталога вместе с .git — отчёт link.ps1 красный' { ExpectLinkReport $copy 1 'связь односторонняя' }

    # Список копий переписывается заменой поля в прочитанном файле: поле, которого
    # сегодня в схеме нет, обязано пережить добавление копии.
    Check 'добавление копии — прочие поля файла принадлежности целы' {
        $markerPath = Join-Path $base 'agents-kit.json'
        $m = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $m | Add-Member -NotePropertyName 'note' -NotePropertyValue 'поле будущей версии' -Force
        $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8
        & pwsh -NoProfile -File $link -Path $copy -Base $base | Out-Null
        $after = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($after.note -ne 'поле будущей версии') { return 'поле note потеряно' }
        if (@($after.workspaces).Count -ne 2) { return "копий в списке $(@($after.workspaces).Count), ожидалось 2" }
        return $null
    }

    & git -C $repo worktree add -q $wt -b wt 2>$null
    Check 'worktree — работает как основная копия' { ExpectText $wt $repo }

    # Ради этого память и адресуется веткой: у worktree база та же, а работа своя.
    Check 'worktree — память своей ветки, а не основной копии' {
        Set-Content -LiteralPath (Join-Path $work 'wt.md') -Encoding utf8 `
            -Value '- Следующий шаг: работа отдельного worktree'
        $problem = ExpectText $wt 'работа отдельного worktree'
        if ($problem) { return $problem }
        return ExpectNoText $wt 'дочитать формат позиции'
    }

    # Отсоединённый HEAD — не поломка, а состояние без адреса памяти: сессия обязана
    # получить внятный ответ, а не молчание и не чужой файл.
    Check 'отсоединённый HEAD — память не адресуется' {
        & git -C $wt checkout -q --detach
        return ExpectText $wt 'HEAD отсоединён'
    }

    Move-Item -LiteralPath $base -Destination $moved
    Check 'база переименована — указатель разорван' { ExpectText $repo 'указатель разорван' }
    Move-Item -LiteralPath $moved -Destination $base

    & git -C $repo config --local agents-kit.base $notbase
    Check 'каталог без agents-kit.json — не база' { ExpectText $repo 'ведёт не в базу' }

    Write-Host ''
    Write-Host "Пройдено: $script:passed, провалено: $script:failed"
}
finally {
    if ($KeepTemp) {
        Write-Host "Каталоги оставлены: $root"
    }
    else {
        # worktree держит служебные файлы в основном репозитории — сначала он.
        try { & git -C $repo worktree remove --force $wt 2>$null } catch { }
        try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
        catch { Write-Host "Не удалось убрать $root — удалить руками" -ForegroundColor Yellow }
    }
}

exit ([int]($script:failed -gt 0))
