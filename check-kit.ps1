# agents-kit: то ли делает кит на живом стенде — заводит базу, связывает с ней основную
# копию, подаёт сессии её знание, будит ждущую сессию ответом оператора — и молчит ли
# там, где его не звали; после стенда — в порядке ли сам репозиторий кита.
#   pwsh -NoProfile -File check-kit.ps1 [-KeepTemp]
#
# Стенд один на все скрипты — репозиторий, база, копия и worktree во временной папке, —
# поэтому проверки живут в одном файле. Гоняется настоящий хук, а не его пересказ.
[CmdletBinding()]
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$scripts = Join-Path $PSScriptRoot 'plugin\scripts'
$hook = Join-Path $scripts 'session-start.ps1'
$link = Join-Path $scripts 'link.ps1'
$init = Join-Path $scripts 'base-init.ps1'
$script:await = Join-Path $scripts 'await-answer.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("agents-kit-check-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

# Без этих переменных первый коммит base-init.ps1 зависел бы от конфига машины.
$env:GIT_AUTHOR_NAME = 'agents-kit-check'
$env:GIT_AUTHOR_EMAIL = 'check@local'
$env:GIT_COMMITTER_NAME = 'agents-kit-check'
$env:GIT_COMMITTER_EMAIL = 'check@local'

$script:passed = 0
$script:failed = 0
function Ok  ([string]$m) { Write-Host "[ OK ]   $m"; $script:passed++ }
function Bad ([string]$m) { Write-Host "[ FAIL ] $m" -ForegroundColor Red; $script:failed++ }

# Хук читает stdin и выходит exit'ом, поэтому зовётся дочерним процессом.
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

# Адрес памяти берётся из того же текста, что видит сессия: он и есть контракт хука.
function Get-HookMemoryPath([string]$Dir) {
    $got = Invoke-Hook $Dir
    if (-not $got) { return $null }
    $m = [regex]::Match($got, '`([^`]+\\work\\[^`]+\.md)`')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Set-KitMemory([string]$Path, [string]$Worktree, [string]$Step) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    Set-Content -LiteralPath $Path -Encoding utf8 -Value @(
        '# Разбор накладной',
        "рабочая копия: $Worktree",
        '## Агенту',
        '### Шаги',
        '- [ ] ' + $Step)
}

function ExpectNoText([string]$Dir, [string]$Needle) {
    $got = Invoke-Hook $Dir
    if (-not $got) { return "хук промолчал — проверять нечего" }
    if ($got -match [regex]::Escape($Needle)) { return "в ответе есть «$Needle», хотя его там быть не должно" }
    return $null
}

# Состояние связи переводят двое — хук и link.ps1, — и проверяются оба.
function ExpectLinkReport([string]$Dir, [int]$Code, [string]$Needle) {
    $out = & pwsh -NoProfile -File $link -Path $Dir 2>&1
    $code = $LASTEXITCODE
    $text = ($out -join "`n")
    if ($code -ne $Code) { return "код возврата $code, ожидался $Code" }
    if ($Needle -and $text -notmatch [regex]::Escape($Needle)) { return "в отчёте нет «$Needle»" }
    return $null
}

# Ожидание ждётся с пределом: зависни оно — зависла бы и проверка; не вышло — это и есть ответ.
function Start-AwaitAnswer([string]$Memory, [string]$Worktree) {
    $info = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($a in '-NoProfile', '-File', $script:await, '-Memory', $Memory, '-Worktree', $Worktree, '-PollSeconds', '1') { $info.ArgumentList.Add($a) }
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.UseShellExecute = $false
    return [System.Diagnostics.Process]::Start($info)
}

function Wait-AwaitAnswer($Process, [int]$Seconds) {
    if (-not $Process.WaitForExit($Seconds * 1000)) { return $null }
    return $Process.StandardOutput.ReadToEnd().Trim()
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

# Объявленная версия читается и из рабочего дерева, и из выложенного коммита — одной
# функцией: разойдись чтение, проверка сравнивала бы разное с разным.
function Get-KitManifestVersion([string]$Json) {
    if (-not $Json) { return $null }
    try { return [string]((ConvertFrom-Json $Json).version) } catch { return $null }
}

# Файлы кита — отслеживаемые и новые неигнорируемые, пути от корня репозитория с прямыми слешами.
function Get-KitFiles([string]$Kit) {
    return @(& git -C $Kit ls-files --cached --others --exclude-standard 2>$null | Where-Object { $_ } | Sort-Object -Unique)
}

# Строки текста кита для проверок путей и упоминаний файлов: .md целиком, в .ps1 — только
# комментарии, в коде стенда пути — данные проверок. Раздел «Чего в ките нет» в CLAUDE.md
# называет отсутствующее намеренно и пропускается.
function Get-KitTextLines([string]$Kit, [string[]]$Files) {
    foreach ($file in $Files) {
        $isScript = $file -like '*.ps1'
        if (-not $isScript -and $file -notlike '*.md') { continue }
        $lines = @(Get-Content -LiteralPath (Join-Path $Kit $file) -Encoding utf8)
        $skip = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $text = $lines[$i]
            if ($file -eq 'CLAUDE.md' -and $text -match '^## ') { $skip = $text -eq '## Чего в ките нет' }
            if ($skip) { continue }
            if ($isScript -and $text -notmatch '^\s*#') { continue }
            [pscustomobject]@{ file = $file; line = $i + 1; text = $text }
        }
    }
}

$plain   = Join-Path $root 'plain'
$repo    = Join-Path $root 'repo'
$copy    = Join-Path $root 'repo-copy'
$wt      = Join-Path $root 'wt'
$base    = Join-Path $root 'base'
$moved   = Join-Path $root 'base-moved'
$notbase = Join-Path $root 'notbase'
$inrepo  = Join-Path $repo 'knowledge'
$mono    = Join-Path $root 'mono'
$monoWt  = Join-Path $root 'mono-wt'
$modFoo  = Join-Path $mono 'packages\foo'
$modBar  = Join-Path $mono 'packages\bar'
$modSrc  = Join-Path $modFoo 'src'
$modCase = Join-Path $mono 'Mixed\Case'
$baseFoo = Join-Path $root 'base-foo'
$baseBar = Join-Path $root 'base-bar'

try {
    New-Item -ItemType Directory -Force -Path $plain, $notbase | Out-Null
    New-TestRepo $repo
    Write-Host "Временные каталоги: $root"
    Write-Host ''

    Check 'каталог вне git — хук молчит' { ExpectSilent $plain }
    Check 'репозиторий без указателя — хук молчит' { ExpectSilent $repo }

    # Инвариант «В репозиторий проекта знание не пишется, и каталог знания в нём не создаётся» исполняет base-init.
    Check 'база внутри репозитория — отказ' {
        $r = Invoke-BaseInit $inrepo
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if (Test-Path -LiteralPath $inrepo) { return 'каталог всё-таки создан' }
        return $null
    }

    Check 'база заведена — каркас, репозиторий и коммит' {
        $r = Invoke-BaseInit $base
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        foreach ($f in 'product.md', 'boundaries.md', 'flow.md', 'backlog.md', '.gitignore') {
            if (-not (Test-Path -LiteralPath (Join-Path $base $f) -PathType Leaf)) { return "нет файла $f" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $base '.git') -PathType Container)) { return 'нет репозитория базы' }
        & git -C $base rev-parse --verify HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return 'каркас не закоммичен' }
        return $null
    }

    # Повторным прогоном база обновляется; ошибка здесь стоит заполненной базы.
    Check 'повторный прогон — заполненное не тронуто, отсутствующее довезено' {
        $product = Join-Path $base 'product.md'
        Set-Content -LiteralPath $product -Value 'заполнено человеком' -Encoding utf8
        Remove-Item -LiteralPath (Join-Path $base 'backlog.md') -Force
        $r = Invoke-BaseInit $base
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath $product -Raw).Trim() -ne 'заполнено человеком') { return 'product.md перезаписан' }
        if (-not (Test-Path -LiteralPath (Join-Path $base 'backlog.md') -PathType Leaf)) { return 'backlog.md не довезён' }
        return $null
    }

    # Дальше — склейка с первым скриптом: базу завёл base-init.ps1, связывает link.ps1.
    & pwsh -NoProfile -File $link -Path $repo -Base $base | Out-Null
    Check 'связанная копия — путь базы в контексте' { ExpectText $repo $base }
    Check 'связанная копия — инварианты в контексте' { ExpectText $repo 'Три слоя' }
    Check 'связанная копия — путь раскладки в контексте' { ExpectText $repo 'base-layout.md' }
    Check 'связанная копия — путь правил памяти в контексте' { ExpectText $repo 'task-memory.md' }
    Check 'связанная копия — путь правил записи бэклога в контексте' { ExpectText $repo 'backlog-record.md' }
    Check 'связанная копия — путь глоссария в контексте' { ExpectText $repo 'glossary.md' }
    Check 'связанная копия — отчёт link.ps1 зелёный' { ExpectLinkReport $repo 0 'связь двусторонняя' }

    # Строка, которой неоткуда взяться, кроме файла базы.
    Check 'связанная копия — содержимое базы в контексте' {
        Set-Content -LiteralPath (Join-Path $base 'product.md') -Encoding utf8 `
            -Value '# Сверочный сервис — продукт', '', 'сверка остатков идёт ночным прогоном', '<!-- пример в комментарии шаблона -->'
        return ExpectText $repo 'сверка остатков идёт ночным прогоном'
    }

    # Имя проекта — заголовок product.md без хвоста каркаса.
    Check 'связанная копия — имя проекта в шапке подачи' { ExpectText $repo "- Проект: Сверочный сервис`n" }

    Check 'файл в корне базы сверх подаваемых — в контекст не попадает' {
        Set-Content -LiteralPath (Join-Path $base 'extra.md') -Encoding utf8 `
            -Value '# Лишнее', '', 'строка из файла вне подачи'
        $problem = ExpectNoText $repo 'строка из файла вне подачи'
        Remove-Item -LiteralPath (Join-Path $base 'extra.md') -Force
        return $problem
    }

    # Флоу нужен только /drive, и в каждую сессию он не приезжает.
    Check 'флоу базы — в контекст не попадает' {
        $flow = Join-Path $base 'flow.md'
        $saved = Get-Content -LiteralPath $flow -Raw
        Set-Content -LiteralPath $flow -Encoding utf8 -Value '# Флоу', '', '## 1. Метка флоу вне подачи'
        $problem = ExpectNoText $repo 'Метка флоу вне подачи'
        Set-Content -LiteralPath $flow -Encoding utf8 -Value $saved -NoNewline
        return $problem
    }

    Check 'пример из HTML-комментария в контекст не попадает' { ExpectNoText $repo 'пример в комментарии шаблона' }

    # Решения подаются оглавлением: строка «когда:» приезжает, тело файла — нет.
    $decisionsDir = Join-Path $base 'decisions'
    Check 'решений нет — сессии названо, куда их заводить' {
        return ExpectText $repo 'решений пока нет'
    }

    Check 'файл решений — строка «когда:» в контексте, тело — нет' {
        New-Item -ItemType Directory -Force -Path $decisionsDir | Out-Null
        Set-Content -LiteralPath (Join-Path $decisionsDir 'api.md') -Encoding utf8 `
            -Value '# API', 'когда: правка эндпоинтов накладной', '', '## Форма', '- тело решения вне подачи'
        $problem = ExpectText $repo 'правка эндпоинтов накладной'
        if ($problem) { return $problem }
        return ExpectNoText $repo 'тело решения вне подачи'
    }

    Check 'файл решений без «когда:» — в оглавление не попадает' {
        Set-Content -LiteralPath (Join-Path $decisionsDir 'deploy.md') -Encoding utf8 `
            -Value '# Развёртывание', '', '- метка файла без строки когда'
        $problem = ExpectNoText $repo 'decisions/deploy.md` — когда'
        if (-not $problem) { $problem = ExpectText $repo 'нет строки «когда:»' }
        Remove-Item -LiteralPath (Join-Path $decisionsDir 'deploy.md') -Force
        return $problem
    }

    # Один пропавший файл не должен уносить с собой подачу остальных.
    Check 'файла базы нет — подача остального цела' {
        Remove-Item -LiteralPath (Join-Path $base 'boundaries.md') -Force
        return ExpectText $repo 'сверка остатков идёт ночным прогоном'
    }

    # Память: своя приезжает, соседняя — нет. Адрес берётся из вывода хука, а не той же
    # формулой — иначе проверка подтвердила бы ошибку реализации.
    New-Item -ItemType Directory -Force -Path (Join-Path $base 'work') | Out-Null

    Check 'памяти нет — сессия получает её адрес' {
        $script:memRepo = Get-HookMemoryPath $repo
        if (-not $script:memRepo) { return 'хук не назвал адрес памяти' }
        if ($script:memRepo -notmatch [regex]::Escape($base)) { return "адрес вне базы: $script:memRepo" }
        return $null
    }

    Check 'память своей копии — в контексте' {
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
        return ExpectText $repo 'дочитать формат позиции'
    }

    # Файл без объявленной копии не подаётся, но лежит по своему адресу: сессии называется
    # строка починки, иначе она бросит свою работу как чужую.
    Check 'файл без объявленной копии — сессии названа строка, которой чинится' {
        Set-Content -LiteralPath $script:memRepo -Encoding utf8 `
            -Value '# Разбор накладной', '## Агенту', '### Шаги', '- [ ] файл без объявленной копии'
        $problem = ExpectText $repo 'рабочая копия: '
        if ($problem) { return $problem }
        $problem = ExpectNoText $repo 'файл без объявленной копии'
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
        return $problem
    }

    # Ветка память не адресует.
    Check 'ветка переименована — адрес прежний, память на месте' {
        & git -C $repo branch -m razbor-nakladnoy
        $after = Get-HookMemoryPath $repo
        if ($after -ine $script:memRepo) { return "адрес уехал: $after" }
        return ExpectText $repo 'дочитать формат позиции'
    }

    # Защита от совпадения слагов и от файла, положенного руками.
    Check 'файл объявляет чужую копию — содержимое не подано' {
        Set-KitMemory $script:memRepo 'D:\Projects\stranger' 'это работа чужой копии'
        $problem = ExpectText $repo 'объявляет рабочую копию'
        if ($problem) { return $problem }
        $problem = ExpectNoText $repo 'это работа чужой копии'
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
        return $problem
    }

    Copy-Item -LiteralPath $repo -Destination $copy -Recurse -Force
    Check 'копия каталога вместе с .git — остановка' { ExpectText $copy 'не числит эту копию' }
    Check 'копия каталога вместе с .git — отчёт link.ps1 красный' { ExpectLinkReport $copy 1 'связь односторонняя' }

    # Поле, которого в схеме нет, переживает добавление копии.
    Check 'добавление копии — прочие поля списка копий целы' {
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

    # Две копии на ветке с одним именем — адреса разные.
    Check 'вторая копия на ветке с тем же именем — адрес свой' {
        $script:memCopy = Get-HookMemoryPath $copy
        if (-not $script:memCopy) { return 'хук не назвал адрес памяти' }
        if ($script:memCopy -ieq $script:memRepo) { return "адрес тот же, что у первой копии: $script:memCopy" }
        return $null
    }

    Check 'память соседней копии — не в контексте' {
        Set-KitMemory $script:memCopy $copy 'это работа соседней копии'
        $problem = ExpectNoText $repo 'это работа соседней копии'
        if ($problem) { return $problem }
        return ExpectNoText $copy 'дочитать формат позиции'
    }

    & git -C $repo worktree add -q $wt -b wt 2>$null
    Check 'worktree — работает как основная копия' { ExpectText $wt $repo }

    # У worktree база та же, а память своя.
    Check 'worktree — память своя, а не основной копии' {
        $script:memWt = Get-HookMemoryPath $wt
        if (-not $script:memWt) { return 'хук не назвал адрес памяти' }
        if ($script:memWt -ieq $script:memRepo) { return 'адрес тот же, что у основной копии' }
        Set-KitMemory $script:memWt $wt 'работа отдельного worktree'
        $problem = ExpectText $wt 'работа отдельного worktree'
        if ($problem) { return $problem }
        return ExpectNoText $wt 'дочитать формат позиции'
    }

    # Без ветки рабочее дерево на месте, значит и память на месте.
    Check 'отсоединённый HEAD — адрес прежний, память на месте' {
        & git -C $wt checkout -q --detach
        $after = Get-HookMemoryPath $wt
        if ($after -ine $script:memWt) { return "адрес уехал: $after" }
        return ExpectText $wt 'работа отдельного worktree'
    }

    # Ожидание держит, пока ответа нет, и выходит строкой на каждом конечном состоянии.
    # Контекст и варианты не прячут ответ в конце блока, а «ответ:» в строке «Агенту →
    # Вопросы» — не ответ оператора и ожидание не отпускает.
    Check 'ожидание — пустой ответ держит, заполненный в конце блока отпускает' {
        $question = @(
            '## Оператору', '',
            '### Какой стенд дать под сверку?',
            'Сверка накладных гоняется на стенде, доступа к нему у сессии нет.', '',
            'Стенд нужен на неделю, дальше сверка переезжает в ночной прогон.', '',
            '- вариант: общий стенд — сразу, но делится с соседней командой',
            '- вариант: отдельный стенд — день на заведение', '')
        $head = @('# Разбор накладной', "рабочая копия: $wt", '')
        $tail = @('', '## Агенту', '', '### Вопросы',
            '- «Какой стенд дать под сверку?»: ответ: адрес стенда взять из local/, не из ответа', '',
            '### Шаги', '- [ ] прогнать сверку на стенде')
        Set-Content -LiteralPath $script:memWt -Encoding utf8 -Value ($head + $question + @('ответ:') + $tail)
        $p = Start-AwaitAnswer $script:memWt $wt
        try {
            if ($null -ne (Wait-AwaitAnswer $p 4)) { return 'вышло без ответа' }
            Set-Content -LiteralPath $script:memWt -Encoding utf8 -Value ($head + $question + @('ответ: общий') + $tail)
            $out = Wait-AwaitAnswer $p 15
            if ($null -eq $out) { return 'ответ записан, а ожидание не вышло' }
            if ($out -notmatch 'ответ оператора пришёл') { return "вышло не тем: $out" }
            return $null
        }
        finally { if (-not $p.HasExited) { $p.Kill() } }
    }

    Check 'ожидание — чужая память и удалённый файл отпускают строкой' {
        Set-KitMemory $script:memWt 'D:\Projects\stranger' 'чужая'
        $p = Start-AwaitAnswer $script:memWt $wt
        $out = Wait-AwaitAnswer $p 15
        if (-not $p.HasExited) { $p.Kill(); return 'на чужой памяти не вышло' }
        if ($out -notmatch 'не своя') { return "на чужой памяти вышло не тем: $out" }

        Remove-Item -LiteralPath $script:memWt -Force
        $p = Start-AwaitAnswer $script:memWt $wt
        $out = Wait-AwaitAnswer $p 15
        if (-not $p.HasExited) { $p.Kill(); return 'на удалённом файле не вышло' }
        if ($out -notmatch 'задача закрыта или файл удалён') { return "на удалённом файле вышло не тем: $out" }
        return $null
    }

    # Связь по каталогу: под китом модуль монорепы, остальное дерево — нет.
    New-TestRepo $mono
    New-Item -ItemType Directory -Force -Path $modFoo, $modBar, $modSrc, $modCase | Out-Null
    foreach ($dir in $modFoo, $modBar, $modSrc, $modCase) {
        Set-Content -LiteralPath (Join-Path $dir '.keep') -Value 'x'
    }
    & git -C $mono add -A 2>$null
    & git -C $mono commit -qm modules | Out-Null
    Invoke-BaseInit $baseFoo | Out-Null
    Invoke-BaseInit $baseBar | Out-Null
    & pwsh -NoProfile -File $link -Path $modFoo -Base $baseFoo -Scope Directory | Out-Null

    Check 'связанный каталог монорепы — база подана' { ExpectText $modFoo $baseFoo }
    Check 'корень монорепы — хук молчит' { ExpectSilent $mono }
    Check 'несвязанный каталог монорепы — хук молчит' { ExpectSilent $modBar }
    Check 'подкаталог связанного — база та же' { ExpectText $modSrc $baseFoo }

    # В списке копий — каталог, для которого записан указатель, а не корень репозитория.
    Check 'связь по каталогу — база числит каталог, а не репозиторий' {
        $m = Get-Content -LiteralPath (Join-Path $baseFoo 'agents-kit.json') -Raw | ConvertFrom-Json
        $ws = @($m.workspaces)
        if ($ws.Count -ne 1) { return "копий в списке $($ws.Count), ожидалась одна" }
        if ($ws[0] -ine $modFoo) { return "числится «$($ws[0])», ожидался «$modFoo»" }
        return $null
    }

    & pwsh -NoProfile -File $link -Path $modBar -Base $baseBar -Scope Directory | Out-Null
    Check 'два каталога одного репозитория — каждый со своей базой' {
        $problem = ExpectText $modFoo $baseFoo
        if ($problem) { return $problem }
        $problem = ExpectText $modBar $baseBar
        if ($problem) { return $problem }
        return ExpectNoText $modBar $baseFoo
    }

    & pwsh -NoProfile -File $link -Path $modSrc -Base $baseBar -Scope Directory | Out-Null
    Check 'вложенный каталог со своей базой — выигрывает ближайший' {
        $problem = ExpectText $modSrc $baseBar
        if ($problem) { return $problem }
        return ExpectText $modFoo $baseFoo
    }

    # Каталоги Windows регистра не различают, а подсекции git различают.
    & pwsh -NoProfile -File $link -Path (Join-Path $mono 'MIXED\CASE') -Base $baseBar -Scope Directory | Out-Null
    Check 'каталог связан в другом регистре — база находится' { ExpectText $modCase $baseBar }

    & git -C $mono worktree add -q $monoWt -b monowt 2>$null
    Check 'связанный каталог в worktree — база та же, память своя' {
        $wtFoo = Join-Path $monoWt 'packages\foo'
        $problem = ExpectText $wtFoo $baseFoo
        if ($problem) { return $problem }
        $memMain = Get-HookMemoryPath $modFoo
        $memWt = Get-HookMemoryPath $wtFoo
        if (-not $memWt) { return 'хук не назвал адрес памяти' }
        if ($memWt -ieq $memMain) { return 'адрес тот же, что у основной копии' }
        return $null
    }

    Check 'связанный каталог в worktree — рабочая копия названа путём worktree, основная отдельно' {
        $wtFoo = Join-Path $monoWt 'packages\foo'
        $problem = ExpectText $wtFoo "- Рабочая копия: ``$wtFoo``"
        if ($problem) { return $problem }
        $problem = ExpectText $wtFoo "- Основная копия: ``$modFoo``"
        if ($problem) { return $problem }
        return ExpectText $wtFoo "рабочая копия: $wtFoo``"
    }

    Check 'отчёт link.ps1 в корне монорепы — называет связанные каталоги' {
        ExpectLinkReport $mono 0 'packages/foo'
    }

    Move-Item -LiteralPath $base -Destination $moved
    Check 'база переименована — указатель разорван' { ExpectText $repo 'указатель разорван' }
    Move-Item -LiteralPath $moved -Destination $base

    & git -C $repo config --local agents-kit.base $notbase
    Check 'каталог без agents-kit.json — не база' { ExpectText $repo 'ведёт не в базу' }

    # Дальше — не стенд, а сам репозиторий кита.
    $kit = $PSScriptRoot

    Check 'версия кита поднята относительно выложенной' {
        $declared = Get-KitManifestVersion (Get-Content -LiteralPath (Join-Path $kit 'plugin\.claude-plugin\plugin.json') -Raw)
        if (-not $declared) { return 'в plugin\.claude-plugin\plugin.json не читается version' }

        # Выложенное — вышестоящая ветка текущей: именно её несут установленные копии.
        # Нет вышестоящей или файла в ней — кит никуда не выложен, устаревать нечему.
        $upstream = & git -C $kit rev-parse --abbrev-ref '@{u}' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $upstream) { return $null }
        $publishedJson = (& git -C $kit show "${upstream}:plugin/.claude-plugin/plugin.json" 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $null }
        $published = Get-KitManifestVersion $publishedJson
        if (-not $published) { return $null }

        if ($declared -ne $published) { return $null }

        # Незакоммиченное считается наравне с закоммиченным: вопрос не «что уже в истории»,
        # а «доедет ли то, что сейчас в дереве».
        $changed = @(& git -C $kit diff --name-only $upstream 2>$null) +
                   @(& git -C $kit ls-files --others --exclude-standard 2>$null)
        $changed = @($changed | Where-Object { $_ })
        if (-not $changed.Count) { return $null }

        return "дерево разошлось с $upstream, а version прежняя ($declared) — поднять её в plugin\.claude-plugin\plugin.json"
    }

    Check 'версия объявлена одним адресом — запись маркетплейса её не дублирует' {
        $marketplace = Get-Content -LiteralPath (Join-Path $kit '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
        $named = @($marketplace.plugins |
            Where-Object { $_.PSObject.Properties.Name -contains 'version' } |
            ForEach-Object { $_.name })
        if ($named.Count) { return "запись маркетплейса объявляет version: $($named -join ', ') — версию несёт только plugin.json" }
        return $null
    }

    $kitFiles = Get-KitFiles $kit

    # Установка копирует каталог source целиком: что лежит в нём, едет пользователю кита.
    Check 'пользователю едет только plugin — правки кита в нём нет' {
        $marketplace = Get-Content -LiteralPath (Join-Path $kit '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
        $sources = @($marketplace.plugins | ForEach-Object { $_.source } | Where-Object { $_ -ne './plugin' })
        if ($sources.Count) { return "source маркетплейса — $($sources -join ', '), а не ./plugin" }
        $inside = @($kitFiles | Where-Object { $_ -match '^plugin/(?:.*/)?(?:\.claude/|CLAUDE\.md$|check-kit\.ps1$)' })
        if ($inside.Count) { return "в plugin лежит правка кита: $($inside -join ', ')" }
        return $null
    }

    # Таблица адресов retool — единственный перечень ответственностей файлов: файл без строки
    # никто не найдёт по вопросу, строка без файла ведёт в пустоту.
    Check 'каждый файл кита числится в таблице retool, и каждая строка таблицы — существующий файл' {
        $skill = @(Get-Content -LiteralPath (Join-Path $kit '.claude\skills\retool\SKILL.md') -Encoding utf8)
        $inTable = $false
        $rows = foreach ($text in $skill) {
            if ($text -match '^## ') { $inTable = $text -eq '## Куда кладётся правка'; continue }
            if ($inTable -and $text -match '^\| `([^`]+)` \|') { $Matches[1] }
        }
        if (-not $rows) { return 'в .claude\skills\retool\SKILL.md не найдена таблица «Куда кладётся правка»' }

        $patterns = foreach ($row in $rows) {
            $regex = (($row -split '<имя>') | ForEach-Object { [regex]::Escape($_) }) -join '[^/]+'
            [pscustomobject]@{ row = $row; regex = $(if ($row.EndsWith('/')) { "^$regex" } else { "^$regex$" }) }
        }
        $problems = @()
        $unlisted = @($kitFiles | Where-Object { $f = $_; -not ($patterns | Where-Object { $f -match $_.regex }) })
        if ($unlisted.Count) { $problems += "нет строки у: $($unlisted -join ', ')" }
        $empty = @($patterns | Where-Object { $p = $_; -not ($kitFiles | Where-Object { $_ -match $p.regex }) } | ForEach-Object { $_.row })
        if ($empty.Count) { $problems += "строка без файла: $($empty -join ', ')" }
        if ($problems.Count) { return $problems -join '; ' }
        return $null
    }

    $kitText = @(Get-KitTextLines $kit $kitFiles)

    # Только .md: абсолютный путь в комментарии скрипта — пример формы пути, и отличить его
    # от настоящего адреса нельзя; пример в тексте пишется заглушкой <…>.
    Check 'в тексте кита нет машинно-зависимых путей' {
        $found = @($kitText | Where-Object { $_.file -like '*.md' } | Where-Object {
            $_.text -match '(?<![\p{L}\p{Nd}])[A-Za-z]:[\\/][\p{L}\p{Nd}_.-]' -or
            $_.text -match '(?<![\p{L}\p{Nd}_.-])/(?:Users|home)/[\p{L}\p{Nd}_.-]'
        } | ForEach-Object { "$($_.file):$($_.line)" })
        if ($found.Count) { return "абсолютный путь машины в $($found -join ', ') — пример пишется заглушкой <…>" }
        return $null
    }

    Check 'упомянутые в тексте кита файлы кита существуют' {
        $names = @{}
        foreach ($f in $kitFiles) { $names[(Split-Path $f -Leaf)] = $true }
        $found = foreach ($entry in $kitText) {
            # Путь от корня репозитория, а в тексте внутри plugin — от plugin: так его видит
            # пользователь кита. .claude в plugin не лежит — его путь всегда от корня.
            # Файл или каталог должен найтись среди файлов кита.
            $from = if ($entry.file -like 'plugin/*') { 'plugin/' } else { '' }
            foreach ($m in [regex]::Matches($entry.text, '(?<![\p{L}\p{Nd}_./\\-])((?:plugin[/\\])?(?:\.claude[/\\](?:skills|agents)|hooks|reference|scripts|skills|template[/\\]base)[/\\][\p{L}\p{Nd}_./\\-]*)')) {
                $path = $m.Groups[1].Value.Replace('\', '/').TrimEnd('.')
                if (-not $path.StartsWith('plugin/') -and -not $path.StartsWith('.claude/')) { $path = $from + $path }
                if (-not ($kitFiles | Where-Object { $_ -eq $path -or $_.StartsWith($path.TrimEnd('/') + '/') })) {
                    "$($entry.file):$($entry.line) $path"
                }
            }
            # Имя без каталога: такое имя должно быть у одного из файлов кита.
            foreach ($m in [regex]::Matches($entry.text, '(?<![\p{L}\p{Nd}_./\\<>-])([\p{L}\p{Nd}_.-]+\.(?:md|ps1))(?![\p{L}\p{Nd}_-])')) {
                if (-not $names.ContainsKey($m.Groups[1].Value)) { "$($entry.file):$($entry.line) $($m.Groups[1].Value)" }
            }
        }
        $found = @($found)
        if ($found.Count) { return "нет такого файла: $($found -join '; ')" }
        return $null
    }

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
        try { & git -C $mono worktree remove --force $monoWt 2>$null } catch { }
        try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
        catch { Write-Host "Не удалось убрать $root — удалить руками" -ForegroundColor Yellow }
    }
}

exit ([int]($script:failed -gt 0))
