# agents-kit: то ли делает кит на живом стенде — заводит базу, связывает с ней рабочую
# копию, подаёт сессии её знание, будит ждущую сессию ответом оператора — и молчит ли
# там, где его не звали.
#   pwsh -NoProfile -File scripts\check-kit.ps1 [-KeepTemp]
#
# Стенд один на все механизмы: репозиторий, база, копия и worktree строятся во
# временной папке разом, и каждая проверка требует его целиком — потому проверки и
# живут в одном файле, а не в нескольких со своей сборкой стенда в каждом. Гоняется
# настоящий хук, а не его пересказ. Проверять это руками значит каждый раз заводить
# стенд заново — и на третий раз проверять не всё.
[CmdletBinding()]
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$hook = Join-Path $PSScriptRoot 'session-start.ps1'
$link = Join-Path $PSScriptRoot 'link.ps1'
$init = Join-Path $PSScriptRoot 'base-init.ps1'
$script:await = Join-Path $PSScriptRoot 'await-answer.ps1'
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
        '## Шаги',
        '- [ ] ' + $Step)
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

# Ожидание ответа живёт отдельным процессом, и зависни он — зависла бы и сверка.
# Поэтому процесс ждётся с пределом, а не до конца: не вышел — это и есть ответ.
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
        foreach ($f in 'product.md', 'boundaries.md', 'flow.md', 'backlog.md', '.gitignore') {
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
        Remove-Item -LiteralPath (Join-Path $base 'backlog.md') -Force
        $r = Invoke-BaseInit $base
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath $product -Raw).Trim() -ne 'заполнено человеком') { return 'product.md перезаписан' }
        if (-not (Test-Path -LiteralPath (Join-Path $base 'backlog.md') -PathType Leaf)) { return 'backlog.md не довезён' }
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
            -Value '# Продукт', '', 'сверка остатков идёт ночным прогоном', '<!-- пример в комментарии шаблона -->'
        return ExpectText $repo 'сверка остатков идёт ночным прогоном'
    }

    # Подаются два названных файла, а не корень базы: лишний .md до сессии не доходит.
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

    # Закомментированный пример из шаблона — тот случай, ради которого хук режет комментарии.
    Check 'пример из HTML-комментария в контекст не попадает' { ExpectNoText $repo 'пример в комментарии шаблона' }

    # Решения подаются оглавлением: строка «когда:» приезжает, тело файла — нет.
    # Ошибка в одну сторону возвращает цену прежнего decisions.md, в другую — сессия
    # не узнает, что решение есть.
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

    # Прежний decisions.md в корне базы — наследство старой раскладки: подаваться он
    # больше не должен, а сверка обязана его назвать.
    Check 'decisions.md в корне — не подаётся, сверка его называет' {
        Set-Content -LiteralPath (Join-Path $base 'decisions.md') -Encoding utf8 `
            -Value '# Решения', '', '## Тема', '- метка прежнего decisions'
        $problem = ExpectNoText $repo 'метка прежнего decisions'
        if (-not $problem) { $problem = ExpectText $repo 'разложить решения по файлам decisions/' }
        Remove-Item -LiteralPath (Join-Path $base 'decisions.md') -Force
        return $problem
    }

    # Один пропавший файл не должен уносить с собой подачу остальных.
    Check 'файла базы нет — подача остального цела' {
        Remove-Item -LiteralPath (Join-Path $base 'boundaries.md') -Force
        return ExpectText $repo 'сверка остатков идёт ночным прогоном'
    }

    # Память задачи адресуется рабочим деревом. Проверяется именно разделение: своя
    # приезжает, соседняя — нет. Ошибка здесь стоит того, что сессия продолжит чужую работу.
    #
    # Адрес сверка не вычисляет заново, а берёт из вывода самого хука: посчитай она его
    # той же формулой, проверка повторила бы реализацию и подтвердила бы её же ошибку.
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

    # Файл без объявленной копии опознать нечем, и подавать его нельзя. Но лежит он
    # по своему адресу, поэтому сессии называется не «разбирается человек», а строка,
    # которой чинится: иначе она бросит собственную работу как чужую.
    Check 'файл без объявленной копии — сессии названа строка, которой чинится' {
        Set-Content -LiteralPath $script:memRepo -Encoding utf8 `
            -Value '# Разбор накладной', '## Шаги', '- [ ] файл без объявленной копии'
        $problem = ExpectText $repo 'рабочая копия: '
        if ($problem) { return $problem }
        $problem = ExpectNoText $repo 'файл без объявленной копии'
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
        return $problem
    }

    # Ветка больше не адресует память, и это ровно то, что здесь проверяется:
    # переименование ветки прежде осиротило бы файл молча.
    Check 'ветка переименована — адрес прежний, память на месте' {
        & git -C $repo branch -m razbor-nakladnoy
        $after = Get-HookMemoryPath $repo
        if ($after -ine $script:memRepo) { return "адрес уехал: $after" }
        return ExpectText $repo 'дочитать формат позиции'
    }

    # Файл, объявивший чужую копию, — единственная защита от совпадения слагов
    # и от файла, положенного в базу руками.
    Check 'файл объявляет чужую копию — содержимое не подано' {
        Set-KitMemory $script:memRepo 'D:\Projects\stranger' 'это работа чужой копии'
        $problem = ExpectText $repo 'объявляет рабочую копию'
        if ($problem) { return $problem }
        $problem = ExpectNoText $repo 'это работа чужой копии'
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
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

    # Копия сделана с репозитория и стоит на ветке с тем же именем. Прежняя схема
    # выдавала обеим один адрес, и работа одной затиралась молча.
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

    # Ради этого память и адресуется рабочим деревом: у worktree база та же, а работа своя.
    Check 'worktree — память своя, а не основной копии' {
        $script:memWt = Get-HookMemoryPath $wt
        if (-not $script:memWt) { return 'хук не назвал адрес памяти' }
        if ($script:memWt -ieq $script:memRepo) { return 'адрес тот же, что у основной копии' }
        Set-KitMemory $script:memWt $wt 'работа отдельного worktree'
        $problem = ExpectText $wt 'работа отдельного worktree'
        if ($problem) { return $problem }
        return ExpectNoText $wt 'дочитать формат позиции'
    }

    # Отсоединённый HEAD прежде оставлял работу вовсе без памяти: адресом была ветка,
    # а её нет. Рабочее дерево на месте, значит и память на месте.
    Check 'отсоединённый HEAD — адрес прежний, память на месте' {
        & git -C $wt checkout -q --detach
        $after = Get-HookMemoryPath $wt
        if ($after -ine $script:memWt) { return "адрес уехал: $after" }
        return ExpectText $wt 'работа отдельного worktree'
    }

    # Ожидание — то, чем ждущая сессия просыпается. Проверяется, что оно ждёт, пока
    # ответа нет, и выходит строкой на каждом конечном состоянии: промолчи оно,
    # сессия спала бы вечно, и выглядело бы это как «ответа пока нет».
    Check 'ожидание — вопрос без ответа держит, ответ под вопросом отпускает' {
        Set-Content -LiteralPath $script:memWt -Encoding utf8 -Value @(
            '# Разбор накладной', "рабочая копия: $wt", '',
            '- Оператору: дать доступ к стенду', '', '## Шаги', '- [ ] прогнать сверку на стенде')
        $p = Start-AwaitAnswer $script:memWt $wt
        try {
            if ($null -ne (Wait-AwaitAnswer $p 4)) { return 'вышло без ответа' }
            Set-Content -LiteralPath $script:memWt -Encoding utf8 -Value @(
                '# Разбор накладной', "рабочая копия: $wt", '',
                '- Оператору: дать доступ к стенду', '  - ответ: доступ выдан', '', '## Шаги', '- [ ] прогнать сверку на стенде')
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
