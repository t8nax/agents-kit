# agents-kit: то ли делает кит на живом стенде — заводит базу, связывает с ней основную
# копию, подаёт сессии её знание, сверяет коммит в базу, будит ждущую сессию ответом
# оператора — и молчит ли там, где его не звали; после стенда — в порядке ли сам репозиторий кита.
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
$script:remove = Join-Path $scripts 'worktree-remove.ps1'
$script:await = Join-Path $scripts 'await-answer.ps1'
$script:deploy = Join-Path $scripts 'agents-deploy.ps1'
$script:wtAdd = Join-Path $scripts 'worktree-add.ps1'
$script:gate = Join-Path $scripts 'commit-gate.ps1'
$script:sync = Join-Path $scripts 'sync.ps1'
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

# Хук зовётся дочерним процессом, как его зовёт Claude Code: читает stdin и выходит exit'ом.
function Invoke-Hook([string]$Dir, [string]$Hook = $hook) {
    $payload = @{ cwd = $Dir } | ConvertTo-Json -Compress
    $out = $payload | & pwsh -NoProfile -File $Hook 2>$null
    if (-not $out) { return '' }
    $text = ($out -join "`n").Trim()
    if (-not $text) { return '' }
    try { return [string](($text | ConvertFrom-Json).hookSpecificOutput.additionalContext) }
    catch { return "!!НЕ-JSON!! $text" }
}

# Гейт коммита получает команду и каталог в stdin, как от Claude Code. Ответ — причина отказа
# или пустая строка, если коммит идёт.
function Invoke-CommitGate([string]$Dir, [string]$Command, [string]$Gate = $script:gate) {
    $payload = @{ cwd = $Dir; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress
    $out = $payload | & pwsh -NoProfile -File $Gate 2>$null
    $text = ($out -join "`n").Trim()
    if (-not $text) { return '' }
    try { return [string](($text | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason) }
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

# Ответ хука проверяется отдельно от вызова: на одно состояние стенда хук зовётся один раз,
# сколько бы строк ни ждали от этого ответа проверки.
function Test-HookText([string]$Got, [string[]]$Has = @(), [string[]]$Lacks = @()) {
    if (-not $Got) {
        if ($Has.Count) { return "ожидался текст про «$($Has[0])», хук промолчал" }
        return 'хук промолчал — проверять нечего'
    }
    foreach ($needle in $Has) {
        if ($Got -notmatch [regex]::Escape($needle)) { return "в ответе нет «$needle»: $($Got.Split("`n")[0])" }
    }
    foreach ($needle in $Lacks) {
        if ($Got -match [regex]::Escape($needle)) { return "в ответе есть «$needle», хотя его там быть не должно" }
    }
    return $null
}

function ExpectText([string]$Dir, [string[]]$Needle, [string[]]$Lacks = @()) {
    return Test-HookText (Invoke-Hook $Dir) $Needle $Lacks
}

# Адрес памяти берётся из того же текста, что видит сессия: он и есть контракт хука.
function Find-HookMemoryPath([string]$Got) {
    if (-not $Got) { return $null }
    $m = [regex]::Match($Got, '`([A-Za-z]:\\[^`]*\\work\\[^`]+\.md)`')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Get-HookMemoryPath([string]$Dir) {
    return Find-HookMemoryPath (Invoke-Hook $Dir)
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

function ExpectNoText([string]$Dir, [string[]]$Needle) {
    return Test-HookText (Invoke-Hook $Dir) -Lacks $Needle
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

function Invoke-WorktreeRemove([string]$Dir) {
    $out = & pwsh -NoProfile -File $script:remove -Path $Dir 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

# Оператор стенда — один на все базы, кроме проверок, которые сами называют другого.
$script:op = 'op'

function Invoke-BaseInit([string]$Dir, [string]$Prefix = 'ORD', [string]$Operator = $script:op, [string]$Remote, [string]$Script = $init) {
    $callArgs = @('-NoProfile', '-File', $Script, '-Path', $Dir)
    if ($Operator) { $callArgs += @('-Operator', $Operator) }
    if ($Prefix) { $callArgs += @('-Prefix', $Prefix) }
    if ($Remote) { $callArgs += @('-Remote', $Remote) }
    $out = & pwsh @callArgs 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

# Где стенд держит рамки, флоу и субагентов оператора — личный репозиторий; папка оператора
# в базе — выложенное для коллег.
function Get-OpDir([string]$Base) { return (Join-Path $Base 'local\me') }
function Get-PeopleDir([string]$Base, [string]$Name = $script:op) { return (Join-Path $Base "people\$Name") }
function Get-MeDir([string]$Base) { return (Join-Path $Base 'local\me') }

function Commit-All([string]$Repo, [string]$Message) {
    & git -C $Repo add -A 2>$null
    & git -C $Repo commit -qm $Message | Out-Null
}

function Invoke-AgentsDeploy([string]$Dir) {
    $out = & pwsh -NoProfile -File $script:deploy -Path $Dir 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

function Invoke-BaseMigrate([string]$Script, [string]$Dir, [string]$Operator = $script:op) {
    $callArgs = @('-NoProfile', '-File', $Script, '-Path', $Dir)
    if ($Operator) { $callArgs += @('-Operator', $Operator) }
    $out = & pwsh @callArgs 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

function Invoke-Sync([string]$Dir, [string]$Repo, [string]$Action) {
    $out = & pwsh -NoProfile -File $script:sync -Path $Dir -Repo $Repo -Action $Action 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

function Get-Head([string]$Dir) {
    return [string](& git -C $Dir rev-parse HEAD 2>$null)
}

function Get-MarkerFormat([string]$Base) {
    return (Get-Content -LiteralPath (Join-Path $Base 'agents-kit.json') -Raw | ConvertFrom-Json).version
}

function Set-MarkerFormat([string]$Base, $Format) {
    $path = Join-Path $Base 'agents-kit.json'
    $m = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $m | Add-Member -NotePropertyName 'version' -NotePropertyValue $Format -Force
    $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
}

function Get-CommitCount([string]$Dir) {
    return [int](& git -C $Dir rev-list --count HEAD)
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
$gone    = Join-Path $root 'gone'
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
$basePfx = Join-Path $root 'base-prefix'
$renRepo = Join-Path $root 'rename'
$renBase = Join-Path $root 'base-rename'
$artRepo = Join-Path $root 'art'
$artBase = Join-Path $root 'base-art'
$migRepo = Join-Path $root 'mig'
$migBase = Join-Path $root 'base-mig'
$newRepo = Join-Path $root 'mig-new'
$newBase = Join-Path $root 'base-mig-new'
$kitCopy = Join-Path $root 'kit-copy'
$v1Repo  = Join-Path $root 'v1'
$v1Base  = Join-Path $root 'base-v1'
$syncRepoA = Join-Path $root 'sync-a'
$syncBaseA = Join-Path $root 'base-sync-a'
$syncRepoB = Join-Path $root 'sync-b'
$syncBaseB = Join-Path $root 'base-sync-b'
$syncBare  = Join-Path $root 'base-sync.git'
$syncMe    = Join-Path $root 'me-sync.git'

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

    Check 'база заведена — каркас, папка оператора, личный репозиторий и коммиты' {
        $r = Invoke-BaseInit $base
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        foreach ($f in 'product.md', 'team.md', '.gitignore', 'agents-kit.json', "people\$script:op\flow\scenarios.md", 'local\me\autonomy.md', 'local\me\flow\scenarios.md', 'local\me\backlog.md', 'local\me.json') {
            if (-not (Test-Path -LiteralPath (Join-Path $base $f) -PathType Leaf)) { return "нет файла $f" }
        }
        foreach ($f in 'backlog.md', 'flow', 'autonomy.md', 'boundaries.md') {
            if (Test-Path -LiteralPath (Join-Path $base $f)) { return "в корне базы лежит $f — ему место не там" }
        }
        foreach ($r2 in $base, (Get-MeDir $base)) {
            if (-not (Test-Path -LiteralPath (Join-Path $r2 '.git') -PathType Container)) { return "нет репозитория в $r2" }
            & git -C $r2 rev-parse --verify HEAD 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return "каркас не закоммичен в $r2" }
        }
        if ((Get-Content -LiteralPath (Join-Path $base 'local\me.json') -Raw | ConvertFrom-Json).operator -ne $script:op) { return 'имя оператора не записано' }
        return $null
    }

    # Повторным прогоном база обновляется; ошибка здесь стоит заполненной базы.
    Check 'повторный прогон — заполненное не тронуто, отсутствующее довезено' {
        $product = Join-Path $base 'product.md'
        $backlog = Join-Path (Get-MeDir $base) 'backlog.md'
        Set-Content -LiteralPath $product -Value 'заполнено человеком' -Encoding utf8
        Remove-Item -LiteralPath $backlog -Force
        $r = Invoke-BaseInit $base ''
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath $product -Raw).Trim() -ne 'заполнено человеком') { return 'product.md перезаписан' }
        if (-not (Test-Path -LiteralPath $backlog -PathType Leaf)) { return 'бэклог не довезён' }
        if ((Get-Content -LiteralPath $backlog -Raw) -notmatch 'ORD-1') { return 'довезённый бэклог без букв базы' }
        return $null
    }

    # Имя оператора — одно на машину: второе поверх подменило бы, чьи флоу и субагенты видит копия.
    Check 'другое имя оператора на той же машине — отказ' {
        $r = Invoke-BaseInit $base '' 'other'
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'уже назван «op»') { return "отказ не про имя: $($r.text)" }
        if (Test-Path -LiteralPath (Join-Path $base 'people\other')) { return 'папка другого оператора всё-таки заведена' }
        return $null
    }

    Check 'имя оператора не по форме — отказ' {
        $r = Invoke-BaseInit $basePfx 'ORD' 'B.Ignatyev'
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if (Test-Path -LiteralPath $basePfx) { return 'каталог базы всё-таки создан' }
        return $null
    }

    # Буквы номеров бэклога называет проект. Отказ стоит дешевле базы, заведённой с чужими
    # буквами: номера записей уже розданы, когда расхождение заметят.
    Check 'заведение без букв номеров — отказ, каркас не тронут' {
        $r = Invoke-BaseInit $basePfx ''
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if (Test-Path -LiteralPath $basePfx) { return 'каталог базы всё-таки создан' }
        return $null
    }

    Check 'буквы номеров встали в agents-kit.json и в счётчик бэклога' {
        $r = Invoke-BaseInit $basePfx 'ord'
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        $text = Get-Content -LiteralPath (Join-Path (Get-MeDir $basePfx) 'backlog.md') -Raw
        if ($text -notmatch '(?m)^следующий номер: ORD-1\s*$') { return "в счётчике не «ORD-1»: $text" }
        if ((Get-Content -LiteralPath (Join-Path $basePfx 'agents-kit.json') -Raw | ConvertFrom-Json).prefix -cne 'ORD') { return 'в agents-kit.json нет букв ORD' }
        return $null
    }

    # Имя занято тем, что папку видят коллеги: в базе с историей новая папка оператора коммитится сразу.
    Check 'новый оператор в базе с коммитами — его папка закоммичена' {
        $mePath = Join-Path $basePfx 'local\me.json'
        $saved = Get-Content -LiteralPath $mePath -Raw
        $m = $saved | ConvertFrom-Json
        $m.PSObject.Properties.Remove('operator')
        $m | ConvertTo-Json | Set-Content -LiteralPath $mePath -Encoding utf8
        try {
            $r = Invoke-BaseInit $basePfx '' 'second'
            if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
            $log = @(& git -C $basePfx log --oneline -- 'people/second' 2>$null | Where-Object { $_ })
            if (-not $log.Count) { return 'папка оператора не закоммичена' }
            $dirty = @(& git -C $basePfx status --porcelain | Where-Object { $_ })
            if ($dirty.Count) { return "в базе осталось незакоммиченное: $($dirty -join '; ')" }
            return $null
        }
        finally { Set-Content -LiteralPath $mePath -Value $saved -Encoding utf8 -NoNewline }
    }

    # Второй оператор на своей машине: личный репозиторий с приватным remote приезжает клоном,
    # а занятую папку оператора скрипт не переписывает.
    Check 'личный репозиторий с -Remote — клон; папка оператора уже есть — не тронута' {
        $remote = Join-Path $root 'me-remote.git'
        & git clone -q --bare (Get-MeDir $basePfx) $remote 2>$null
        $baseRemote = Join-Path $root 'base-remote'
        $taken = Join-Path $baseRemote "people\$script:op\flow\scenarios.md"
        New-Item -ItemType Directory -Force -Path (Split-Path $taken -Parent) | Out-Null
        Set-Content -LiteralPath $taken -Value 'сценарии оператора' -Encoding utf8
        $r = Invoke-BaseInit $baseRemote 'ORD' $script:op $remote
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        $origin = & git -C (Get-MeDir $baseRemote) remote get-url origin 2>$null
        if (-not $origin -or ([System.IO.Path]::GetFullPath($origin)).TrimEnd('\') -ine ([System.IO.Path]::GetFullPath($remote)).TrimEnd('\')) { return "origin личного репозитория «$origin», ожидался «$remote»" }
        if ((Get-Content -LiteralPath $taken -Raw).Trim() -ne 'сценарии оператора') { return 'папка оператора переписана' }
        if ($r.text -notmatch 'взята как есть') { return 'скрипт не сказал, что папка оператора уже есть' }
        return $null
    }

    # Дальше — склейка с первым скриптом: базу завёл base-init.ps1, связывает link.ps1.
    & pwsh -NoProfile -File $link -Path $repo -Base $base | Out-Null
    # Строка, которой неоткуда взяться, кроме файла базы.
    Set-Content -LiteralPath (Join-Path $base 'product.md') -Encoding utf8 `
        -Value '# Сверочный сервис — продукт', '', 'сверка остатков идёт ночным прогоном', '<!-- пример в комментарии шаблона -->'
    $linked = Invoke-Hook $repo
    Check 'связанная копия — путь базы в контексте' { Test-HookText $linked $base }
    Check 'связанная копия — инварианты в контексте' { Test-HookText $linked 'Три слоя' }
    Check 'связанная копия — путь раскладки в контексте' { Test-HookText $linked 'base-layout.md' }
    Check 'связанная копия — путь правил памяти в контексте' { Test-HookText $linked 'task-memory.md' }
    Check 'связанная копия — путь правил записи бэклога в контексте' { Test-HookText $linked 'backlog-record.md' }
    Check 'связанная копия — путь глоссария в контексте' { Test-HookText $linked 'glossary.md' }
    Check 'связанная копия — отчёт link.ps1 зелёный' { ExpectLinkReport $repo 0 'связь двусторонняя' }
    Check 'связанная копия — содержимое базы в контексте' { Test-HookText $linked 'сверка остатков идёт ночным прогоном' }

    # Имя проекта — заголовок product.md без хвоста каркаса.
    Check 'связанная копия — имя проекта в шапке подачи' { Test-HookText $linked "- Проект: Сверочный сервис`n" }
    Check 'пример из HTML-комментария в контекст не попадает' { Test-HookText $linked -Lacks 'пример в комментарии шаблона' }

    # Решения подаются оглавлением: строка «когда:» приезжает, тело файла — нет.
    $decisionsDir = Join-Path $base 'decisions'
    Check 'решений нет — сессии названо, куда их заводить' { Test-HookText $linked 'решений пока нет' }

    # Рамки — свои: подаются из личного репозитория, а лежащее в people\ не подаётся.
    Check 'правила команды и рамки своего оператора — в контексте, рамки из people\ — нет' {
        $team = Join-Path $base 'team.md'
        $own = Join-Path (Get-OpDir $base) 'autonomy.md'
        $other = Join-Path (Get-PeopleDir $base) 'autonomy.md'
        $saved = @{}
        foreach ($f in $team, $own) { $saved[$f] = Get-Content -LiteralPath $f -Raw }
        Set-Content -LiteralPath $team -Encoding utf8 -Value '# Правила команды', '', 'без ревью не мержим'
        Set-Content -LiteralPath $own -Encoding utf8 -Value '# Рамки', '', 'миграции схемы решает сам'
        New-Item -ItemType Directory -Force -Path (Split-Path $other -Parent) | Out-Null
        Set-Content -LiteralPath $other -Encoding utf8 -Value '# Рамки', '', 'рамка коллеги вне подачи'
        try { return ExpectText $repo 'без ревью не мержим', 'миграции схемы решает сам', 'local/me/autonomy.md' -Lacks 'рамка коллеги вне подачи' }
        finally {
            foreach ($f in $team, $own) { Set-Content -LiteralPath $f -Value $saved[$f] -Encoding utf8 -NoNewline }
            Remove-Item -LiteralPath $other -Force
        }
    }

    # Потолок рамок считается и на старте, и в коммите: файл лежит не в корне базы.
    Check 'рамки оператора больше потолка — сверка и гейт называют' {
        $own = Join-Path (Get-OpDir $base) 'autonomy.md'
        $saved = Get-Content -LiteralPath $own -Raw
        Set-Content -LiteralPath $own -Encoding utf8 -Value (@('# Рамки') + @(1..31 | ForEach-Object { "- строка $_" }))
        try {
            $problem = ExpectText $repo 'local/me/autonomy.md', 'при потолке 30'
            if ($problem) { return $problem }
            $reason = Invoke-CommitGate $repo "git -C `"$(Get-MeDir $base)`" commit -m x -- `"$own`""
            if ($reason -notmatch 'при потолке 30') { return "гейт не остановил: «$reason»" }
            return $null
        }
        finally { Set-Content -LiteralPath $own -Value $saved -Encoding utf8 -NoNewline }
    }

    Check 'файл в корне базы сверх подаваемых — в контекст не попадает' {
        Set-Content -LiteralPath (Join-Path $base 'extra.md') -Encoding utf8 `
            -Value '# Лишнее', '', 'строка из файла вне подачи'
        $problem = ExpectNoText $repo 'строка из файла вне подачи'
        Remove-Item -LiteralPath (Join-Path $base 'extra.md') -Force
        return $problem
    }

    # Разделы tracker.md сверка берёт из таблицы раскладки: разбор не сошёлся — отказ и целому файлу.
    Check 'tracker.md — все разделы гейт пускает, без раздела — отказ с /tracker' {
        $tracker = Join-Path $base 'tracker.md'
        $sections = 'Где задачи', 'Показ бэклога', 'Взятие задачи', 'Задача закрыта', 'Вынос записи бэклога'
        try {
            Set-Content -LiteralPath $tracker -Encoding utf8 -Value (@('# Проект — трекер') + @($sections | ForEach-Object { '', "## $_", 'слова' }))
            $reason = Invoke-CommitGate $repo "git -C `"$base`" commit -m x -- tracker.md"
            if ($reason) { return "гейт остановил полный файл: «$reason»" }
            Set-Content -LiteralPath $tracker -Encoding utf8 -Value (@('# Проект — трекер') + @($sections | Select-Object -First 4 | ForEach-Object { '', "## $_", 'слова' }))
            $reason = Invoke-CommitGate $repo "git -C `"$base`" commit -m x -- tracker.md"
            if ($reason -notmatch 'Вынос записи бэклога' -or $reason -notmatch '/tracker') { return "гейт не назвал раздел и /tracker: «$reason»" }
            return $null
        }
        finally { Remove-Item -LiteralPath $tracker -Force -ErrorAction SilentlyContinue }
    }

    # Флоу нужен только /flow и /drive, и в каждую сессию он не приезжает.
    Check 'сценарии и этапы базы — в контекст не попадают' {
        $flow = Join-Path (Get-OpDir $base) 'flow\scenarios.md'
        $stages = Join-Path (Get-OpDir $base) 'flow\stages'
        $saved = Get-Content -LiteralPath $flow -Raw
        New-Item -ItemType Directory -Force -Path $stages | Out-Null
        Set-Content -LiteralPath $flow -Encoding utf8 -Value '# Сценарии', '', '## Метка сценария вне подачи', '1. [Ветка](stages/branch.md)'
        Set-Content -LiteralPath (Join-Path $stages 'branch.md') -Encoding utf8 `
            -Value '# Ветка', '', 'исполнитель: оркестратор', 'выход: ветка', '', '1. Метка этапа вне подачи.'
        $problem = ExpectNoText $repo 'Метка сценария вне подачи', 'Метка этапа вне подачи'
        Set-Content -LiteralPath $flow -Encoding utf8 -Value $saved -NoNewline
        Remove-Item -LiteralPath $stages -Recurse -Force
        return $problem
    }

    # Пункт сценария адресует этап файлом: оборванная ссылка оставила бы сценарий без этапа молча.
    Check 'сценарий ведёт на файл этапа, которого нет, — сверка называет' {
        $flow = Join-Path (Get-OpDir $base) 'flow\scenarios.md'
        $saved = Get-Content -LiteralPath $flow -Raw
        Set-Content -LiteralPath $flow -Encoding utf8 -Value '# Сценарии', '', '## полный', '1. [Ветка](stages/branch.md)'
        $problem = ExpectText $repo 'такого файла нет'
        Set-Content -LiteralPath $flow -Encoding utf8 -Value $saved -NoNewline
        return $problem
    }

    # Возврат пишет сценарий: один этап «Ревью» возвращает в каждом сценарии на своё. Лишний этап
    # вне сценариев показывает, что сверка флоу дошла до подачи.
    Check 'возврат под пунктом сценария на этап раньше — сверка проходит' {
        $flow = Join-Path (Get-OpDir $base) 'flow\scenarios.md'
        $stages = Join-Path (Get-OpDir $base) 'flow\stages'
        $saved = Get-Content -LiteralPath $flow -Raw
        New-Item -ItemType Directory -Force -Path $stages | Out-Null
        Set-Content -LiteralPath $flow -Encoding utf8 -Value '# Сценарии', '',
            '## полный', 'когда: новая возможность', '1. [Реализация](stages/impl.md)', '2. [Ревью](stages/review.md)', '   - возврат: замечания — этап «Реализация»', '     - кругов: 3', '',
            '## документация', 'когда: правка текстов', '1. [Написание](stages/writing.md)', '2. [Ревью](stages/review.md)', '   - возврат: замечания — этап «Написание»'
        foreach ($s in @(@('impl', 'Реализация'), @('review', 'Ревью'), @('writing', 'Написание'), @('spare', 'Запасная'))) {
            Set-Content -LiteralPath (Join-Path $stages "$($s[0]).md") -Encoding utf8 `
                -Value "# $($s[1])", '', 'исполнитель: оркестратор', 'выход: коммит'
        }
        $problem = ExpectText $repo 'этап не входит ни в один сценарий' -Lacks 'пункт 2: возврат', 'не возврат', 'предел кругов'
        Set-Content -LiteralPath $flow -Encoding utf8 -Value $saved -NoNewline
        Remove-Item -LiteralPath $stages -Recurse -Force
        return $problem
    }

    Check 'возврат на этап, которого нет в этом сценарии, — сверка называет' {
        $flow = Join-Path (Get-OpDir $base) 'flow\scenarios.md'
        $stages = Join-Path (Get-OpDir $base) 'flow\stages'
        $saved = Get-Content -LiteralPath $flow -Raw
        New-Item -ItemType Directory -Force -Path $stages | Out-Null
        Set-Content -LiteralPath $flow -Encoding utf8 -Value '# Сценарии', '',
            '## полный', 'когда: новая возможность', '1. [Реализация](stages/impl.md)', '2. [Ревью](stages/review.md)', '',
            '## документация', 'когда: правка текстов', '1. [Ревью](stages/review.md)', '   - возврат: замечания — этап «Реализация»'
        foreach ($s in @(@('impl', 'Реализация'), @('review', 'Ревью'))) {
            Set-Content -LiteralPath (Join-Path $stages "$($s[0]).md") -Encoding utf8 `
                -Value "# $($s[1])", '', 'исполнитель: оркестратор', 'выход: коммит'
        }
        $problem = ExpectText $repo 'в этом сценарии его нет'
        Set-Content -LiteralPath $flow -Encoding utf8 -Value $saved -NoNewline
        Remove-Item -LiteralPath $stages -Recurse -Force
        return $problem
    }

    Check 'файл решений — строка «когда:» в контексте, тело — нет' {
        New-Item -ItemType Directory -Force -Path $decisionsDir | Out-Null
        Set-Content -LiteralPath (Join-Path $decisionsDir 'api.md') -Encoding utf8 `
            -Value '# API', 'когда: правка эндпоинтов накладной', '', '## Форма', '- тело решения вне подачи'
        return ExpectText $repo 'правка эндпоинтов накладной' -Lacks 'тело решения вне подачи'
    }

    Check 'файл решений без «когда:» — в оглавление не попадает' {
        Set-Content -LiteralPath (Join-Path $decisionsDir 'deploy.md') -Encoding utf8 `
            -Value '# Развёртывание', '', '- метка файла без строки когда'
        $problem = ExpectText $repo 'нет строки «когда:»' -Lacks 'decisions/deploy.md` — когда'
        Remove-Item -LiteralPath (Join-Path $decisionsDir 'deploy.md') -Force
        return $problem
    }

    # Один пропавший файл не должен уносить с собой подачу остальных. Этим же ответом хука
    # назван адрес памяти, которой ещё нет.
    Remove-Item -LiteralPath (Join-Path (Get-OpDir $base) 'autonomy.md') -Force
    New-Item -ItemType Directory -Force -Path (Join-Path (Get-MeDir $base) 'work') | Out-Null
    $noMemory = Invoke-Hook $repo
    Check 'файла базы нет — подача остального цела' { Test-HookText $noMemory 'сверка остатков идёт ночным прогоном' }

    # Память: своя приезжает, соседняя — нет. Адрес берётся из вывода хука, а не той же
    # формулой — иначе проверка подтвердила бы ошибку реализации.
    Check 'памяти нет — сессия получает её адрес' {
        $script:memRepo = Find-HookMemoryPath $noMemory
        if (-not $script:memRepo) { return 'хук не назвал адрес памяти' }
        if ($script:memRepo -notmatch [regex]::Escape($base)) { return "адрес вне базы: $script:memRepo" }
        return $null
    }

    # Сценарий задачи сверка сводит со строкой памяти: без неё не видно, по какому списку идёт задача.
    $withMemory = $null
    if ($script:memRepo) {
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
        $withMemory = Invoke-Hook $repo
    }
    Check 'память своей копии — в контексте' {
        if (-not $script:memRepo) { return 'хук не назвал адрес памяти — положить её некуда' }
        return Test-HookText $withMemory 'дочитать формат позиции'
    }
    Check 'память без строки «сценарий:» — сверка называет' {
        if (-not $script:memRepo) { return 'хук не назвал адрес памяти — положить её некуда' }
        return Test-HookText $withMemory 'нет строки «сценарий:»'
    }

    # Файл без объявленной копии не подаётся, но лежит по своему адресу: сессии называется
    # строка починки, иначе она бросит свою работу как чужую.
    Check 'файл без объявленной копии — сессии названа строка, которой чинится' {
        Set-Content -LiteralPath $script:memRepo -Encoding utf8 `
            -Value '# Разбор накладной', '## Агенту', '### Шаги', '- [ ] файл без объявленной копии'
        $problem = ExpectText $repo 'рабочая копия: ' -Lacks 'файл без объявленной копии'
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
        return $problem
    }

    # Ветка память не адресует.
    Check 'ветка переименована — адрес прежний, память на месте' {
        & git -C $repo branch -m razbor-nakladnoy
        $got = Invoke-Hook $repo
        $after = Find-HookMemoryPath $got
        if ($after -ine $script:memRepo) { return "адрес уехал: $after" }
        return Test-HookText $got 'дочитать формат позиции'
    }

    # Защита от совпадения слагов и от файла, положенного руками.
    Check 'файл объявляет чужую копию — содержимое не подано' {
        Set-KitMemory $script:memRepo 'D:\Projects\stranger' 'это работа чужой копии'
        $problem = ExpectText $repo 'объявляет рабочую копию' -Lacks 'это работа чужой копии'
        Set-KitMemory $script:memRepo $repo 'дочитать формат позиции'
        return $problem
    }

    # Переименование сценария посреди задачи: своя база, чтобы коммит памяти не сдвинул историю
    # основной. Гейт гоняется настоящий, а коммит не делается — он только судит.
    New-TestRepo $renRepo
    Invoke-BaseInit $renBase | Out-Null
    & pwsh -NoProfile -File $link -Path $renRepo -Base $renBase | Out-Null
    $renFlow = Join-Path (Get-OpDir $renBase) 'flow\scenarios.md'
    $renStages = Join-Path (Get-OpDir $renBase) 'flow\stages'
    New-Item -ItemType Directory -Force -Path $renStages | Out-Null
    foreach ($s in @(@('impl', 'Реализация'), @('review', 'Ревью'), @('writing', 'Написание'))) {
        Set-Content -LiteralPath (Join-Path $renStages "$($s[0]).md") -Encoding utf8 `
            -Value "# $($s[1])", '', 'исполнитель: оркестратор', 'выход: коммит'
    }
    $renFull = @('## полный', 'когда: новая возможность', '1. [Реализация](stages/impl.md)', '2. [Ревью](stages/review.md)', '')
    $renDocs = @('## документация', 'когда: правка текстов', '1. [Написание](stages/writing.md)', '2. [Ревью](stages/review.md)', '')
    $renFeature = @('## фича', 'когда: новая возможность', '1. [Реализация](stages/impl.md)', '2. [Ревью](stages/review.md)', '')
    $renMem = Get-HookMemoryPath $renRepo
    $renMemory = {
        param([string]$Flow)
        New-Item -ItemType Directory -Force -Path (Split-Path $renMem -Parent) | Out-Null
        Set-Content -LiteralPath $renMem -Encoding utf8 -Value @(
            '# Разбор накладной', "рабочая копия: $renRepo", "сценарий: $Flow", '',
            '## Агенту', '', '### Сценарий', '- [ ] 1. Реализация', '- [ ] 2. Ревью', '',
            '### Шаги', '- [ ] дочитать формат позиции')
    }
    Set-Content -LiteralPath $renFlow -Encoding utf8 -Value (@('# Сценарии', '') + $renFull + $renDocs)
    & $renMemory 'полный'
    $renMe = Get-MeDir $renBase
    Commit-All $renBase 'флоу'
    Commit-All $renMe 'задача взята'
    $renCommit = "git -C `"$renMe`" commit -m память -- `"$renMem`""

    Check 'сценария памяти нет, этапы те же у одного сценария — сверка называет его' {
        Set-Content -LiteralPath $renFlow -Encoding utf8 -Value (@('# Сценарии', '') + $renFeature + $renDocs)
        return ExpectText $renRepo 'переименован в «фича»'
    }

    Check 'сценария памяти нет, сценария с теми же этапами нет — переименован или удалён' {
        Set-Content -LiteralPath $renFlow -Encoding utf8 -Value (@('# Сценарии', '') + $renDocs)
        return ExpectText $renRepo 'переименован — поправить строку «сценарий:» на новое имя' -Lacks 'переименован в «'
    }

    Check 'коммит памяти: сценарий переименован, строка поправлена, этапы те же — гейт пускает' {
        Set-Content -LiteralPath $renFlow -Encoding utf8 -Value (@('# Сценарии', '') + $renFeature + $renDocs)
        & $renMemory 'фича'
        $reason = Invoke-CommitGate $renRepo $renCommit
        if ($reason -match 'сценарий задачи не меняется') { return "гейт остановил переименование: $reason" }
        return $null
    }

    Check 'коммит памяти: строка сменена на другой сценарий, прежний на месте — гейт останавливает' {
        Set-Content -LiteralPath $renFlow -Encoding utf8 -Value (@('# Сценарии', '') + $renFull + $renDocs)
        & $renMemory 'документация'
        $reason = Invoke-CommitGate $renRepo $renCommit
        if ($reason -notmatch 'сценарий задачи не меняется') { return "гейт не остановил: «$reason»" }
        return $null
    }

    Check 'коммит памяти: прежний сценарий удалён, у нового другие этапы — гейт останавливает' {
        Set-Content -LiteralPath $renFlow -Encoding utf8 -Value (@('# Сценарии', '') + $renDocs)
        & $renMemory 'документация'
        $reason = Invoke-CommitGate $renRepo $renCommit
        if ($reason -notmatch 'сценарий задачи не меняется') { return "гейт не остановил: «$reason»" }
        return $null
    }

    # Потерянный раздел этапов выключил бы сверку хода задачи молча. Строки этапов без заголовка
    # уходят в предыдущий подраздел.
    Set-Content -LiteralPath $renFlow -Encoding utf8 -Value (@('# Сценарии', '') + $renFull + $renDocs)
    $renHead = @('# Разбор накладной', "рабочая копия: $renRepo", 'сценарий: полный', '', '## Агенту', '')
    $renStageLines = @('- [ ] 1. Реализация', '- [ ] 2. Ревью', '')
    $renSteps = @('### Шаги', '- [ ] дочитать формат позиции')
    $renNoFlow = $renHead + @('### Факты', '- формат позиции известен') + $renStageLines + $renSteps

    Check 'память без «### Сценарий», этапы под «Фактами» — красная находка называет, где они' {
        Set-Content -LiteralPath $renMem -Encoding utf8 -Value $renNoFlow
        return ExpectText $renRepo 'нет подраздела «### Сценарий» в «Агенту» — строки этапов стоят в «### Факты»' -Lacks 'разошлось со списком сценария'
    }

    Check 'в «Сценарии» памяти ни одного этапа — красная находка' {
        Set-Content -LiteralPath $renMem -Encoding utf8 -Value ($renHead + @('### Сценарий', '') + $renSteps)
        return ExpectText $renRepo 'нет ни одного этапа' -Lacks 'разошлось со списком сценария'
    }

    Check 'память без «### Шаги» — одна красная находка, о подразделе' {
        Set-Content -LiteralPath $renMem -Encoding utf8 -Value ($renHead + @('### Сценарий') + $renStageLines)
        return ExpectText $renRepo 'нет подраздела «### Шаги»' -Lacks '«Шаги» пусты'
    }

    # Пропажа и возврат раздела этапов меняют отметки, но переходом не считаются.
    Check 'коммит памяти: заголовок «Сценарий» стёрт, шаги уцелели — не переход' {
        & $renMemory 'полный'
        & git -C $renMe add -A 2>$null
        & git -C $renMe commit -qm 'сценарий памяти' | Out-Null
        Set-Content -LiteralPath $renMem -Encoding utf8 -Value $renNoFlow
        $reason = Invoke-CommitGate $renRepo $renCommit
        if ($reason -match 'прежнего этапа') { return "гейт принял пропажу за переход: $reason" }
        if ($reason -notmatch 'нет подраздела «### Сценарий»') { return "гейт не назвал пропажу: «$reason»" }
        return $null
    }

    Check 'коммит памяти: заголовок «Сценарий» вернули — не переход' {
        & git -C $renMe add -A 2>$null
        & git -C $renMe commit -qm 'заголовок потерян' | Out-Null
        & $renMemory 'полный'
        $reason = Invoke-CommitGate $renRepo $renCommit
        if ($reason -match 'прежнего этапа') { return "гейт принял возврат заголовка за переход: $reason" }
        return $null
    }

    Check 'коммит памяти: заголовок «Шаги» вернули над закрытым шагом — не новые шаги' {
        Set-Content -LiteralPath $renMem -Encoding utf8 -Value ($renHead + @('### Сценарий') + $renStageLines + @('- [ ] дочитать формат позиции'))
        & git -C $renMe add -A 2>$null
        & git -C $renMe commit -qm 'заголовок шагов потерян' | Out-Null
        Set-Content -LiteralPath $renMem -Encoding utf8 -Value ($renHead + @('### Сценарий') + $renStageLines +
            @('### Шаги', '- [x] дочитать формат позиции — результат: формат в a.txt — проверен: прочитан файл'))
        $reason = Invoke-CommitGate $renRepo $renCommit
        if ($reason -match 'появилась уже закрытой') { return "гейт принял возврат заголовка за новые шаги: $reason" }
        return $null
    }

    # Память живёт в личном репозитории, и гейт судит коммит туда так же, как коммит в базу.
    Check 'коммит в личный репозиторий с невобранным ответом — гейт останавливает' {
        & $renMemory 'полный'
        Add-Content -LiteralPath $renMem -Encoding utf8 -Value '', '## Оператору', '', '### Какой стенд дать?', 'Стенд нужен под сверку.', '', 'ответ: общий'
        $reason = Invoke-CommitGate $renRepo $renCommit
        & $renMemory 'полный'
        if ($reason -notmatch 'ответ не вобран') { return "гейт не остановил: «$reason»" }
        return $null
    }

    # Папка коллеги — его работа: ни сверка, ни гейт её не судят.
    $renAlien = Join-Path $renBase 'people\x\flow\scenarios.md'
    New-Item -ItemType Directory -Force -Path (Split-Path $renAlien -Parent) | Out-Null
    Set-Content -LiteralPath $renAlien -Encoding utf8 -Value '# Сценарии', '', '## чужой', '1. [Нет такого](stages/none.md)'

    Check 'флоу в папке другого оператора — сверка молчит, гейт коммита в базу пускает' {
        $problem = ExpectNoText $renRepo 'people/x', 'stages/none.md'
        if ($problem) { return $problem }
        $reason = Invoke-CommitGate $renRepo "git -C `"$renBase`" commit -m чужой -- `"$renAlien`""
        if ($reason) { return "гейт остановил: $reason" }
        return $null
    }

    Check 'свой флоу с той же ошибкой — гейт коммита в личный репозиторий останавливает' {
        $own = Join-Path (Get-OpDir $renBase) 'flow\scenarios.md'
        $saved = Get-Content -LiteralPath $own -Raw
        Set-Content -LiteralPath $own -Encoding utf8 -Value '# Сценарии', '', '## свой', '1. [Нет такого](stages/none.md)'
        $reason = Invoke-CommitGate $renRepo "git -C `"$(Get-MeDir $renBase)`" commit -m свой -- `"$own`""
        Set-Content -LiteralPath $own -Encoding utf8 -Value $saved -NoNewline
        if ($reason -notmatch 'такого файла нет') { return "гейт не остановил: «$reason»" }
        return $null
    }

    # Артефакты: файл живёт, пока на него ссылается .md его репозитория. Своя база — закрытие задачи
    # коммитом гейт судит по HEAD, и чужие коммиты стенда его сдвигали бы.
    New-TestRepo $artRepo
    Invoke-BaseInit $artBase | Out-Null
    & pwsh -NoProfile -File $link -Path $artRepo -Base $artBase | Out-Null
    $artMe = Get-MeDir $artBase
    $artDir = Join-Path $artMe 'artifacts'
    $artFile = Join-Path $artDir 'ORD-1-макет.png'
    $artMem = Get-HookMemoryPath $artRepo
    $artBacklog = Join-Path $artMe 'backlog.md'
    $artBacklogSaved = Get-Content -LiteralPath $artBacklog -Raw
    New-Item -ItemType Directory -Force -Path $artDir | Out-Null
    Set-Content -LiteralPath $artFile -Value 'png'
    Set-KitMemory $artMem $artRepo 'сверить макет'
    Add-Content -LiteralPath $artMem -Encoding utf8 -Value '', '## Артефакты', '- макет: artifacts/ORD-1-макет.png.'
    & git -C $artMe add -A 2>$null
    & git -C $artMe commit -qm 'задача с артефактом' | Out-Null
    $artHook = Invoke-Hook $artRepo

    Check 'артефакт со ссылкой из памяти — сверка молчит о нём' {
        return Test-HookText $artHook -Lacks 'ORD-1-макет.png` —', 'такого файла в его репозитории нет'
    }

    Check 'на артефакт никто не ссылается — сверка называет' {
        Set-Content -LiteralPath (Join-Path $artDir 'лишний.log') -Value 'x'
        $problem = ExpectText $artRepo 'artifacts\лишний.log` — на артефакт не ссылается'
        Remove-Item -LiteralPath (Join-Path $artDir 'лишний.log') -Force
        return $problem
    }

    Check 'ссылка на артефакт, которого нет, — сверка называет; путь проекта — нет' {
        New-Item -ItemType Directory -Force -Path (Join-Path $artBase 'decisions') | Out-Null
        $decision = Join-Path $artBase 'decisions\build.md'
        Set-Content -LiteralPath $decision -Encoding utf8 -Value '# Сборка', 'когда: правка сборки', '',
            '## Выход', '- сборка кладёт пакет в build/artifacts/pkg.zip', '- схема сборки — artifacts/схема.svg'
        $problem = ExpectText $artRepo 'artifacts/схема.svg — такого файла в его репозитории нет' -Lacks 'artifacts/pkg.zip'
        Remove-Item -LiteralPath (Join-Path $artBase 'decisions') -Recurse -Force
        return $problem
    }

    # Артефакты у каждого репозитория свои: коллеги память не видят, и её ссылка файл базы не держит.
    Check 'артефакт общей базы, на который ссылается только память, — без ссылок' {
        $shared = Join-Path $artBase 'artifacts\общий.png'
        New-Item -ItemType Directory -Force -Path (Split-Path $shared -Parent) | Out-Null
        Set-Content -LiteralPath $shared -Value 'png'
        Add-Content -LiteralPath $artMem -Encoding utf8 -Value '- общий: artifacts/общий.png'
        $problem = ExpectText $artRepo 'artifacts\общий.png` — на артефакт не ссылается'
        Remove-Item -LiteralPath (Split-Path $shared -Parent) -Recurse -Force
        & git -C $artMe checkout -q -- $artMem 2>$null
        return $problem
    }

    Check 'подкаталог в artifacts/ — сверка называет' {
        New-Item -ItemType Directory -Force -Path (Join-Path $artDir 'shots') | Out-Null
        $problem = ExpectText $artRepo 'артефакты лежат плоско'
        Remove-Item -LiteralPath (Join-Path $artDir 'shots') -Recurse -Force
        return $problem
    }

    # Потолок читается из раскладки: число в тексте проверки — то же, что в справке.
    Check 'артефакт больше потолка — сверка и гейт называют' {
        $big = Join-Path $artDir 'дамп.bin'
        [System.IO.File]::WriteAllBytes($big, [byte[]]::new(6MB))
        Add-Content -LiteralPath $artMem -Encoding utf8 -Value '- дамп: artifacts/дамп.bin'
        $problem = ExpectText $artRepo 'при потолке 5 МБ'
        if (-not $problem) {
            $reason = Invoke-CommitGate $artRepo "git -C `"$artMe`" commit -m x -- `"$big`" `"$artMem`""
            if ($reason -notmatch 'при потолке 5 МБ') { $problem = "гейт не остановил: «$reason»" }
        }
        Remove-Item -LiteralPath $big -Force
        & git -C $artMe checkout -q -- $artMem 2>$null
        return $problem
    }

    Check 'закрытие задачи оставляет артефакт без ссылок — гейт останавливает' {
        & git -C $artMe rm -q -- $artMem
        $reason = Invoke-CommitGate $artRepo "git -C `"$artMe`" commit -m закрыта -- `"$artMem`""
        if ($reason -notmatch 'ORD-1-макет.png` — после коммита на артефакт не ссылается') { return "гейт не остановил: «$reason»" }
        return $null
    }

    Check 'закрытие задачи вместе с git rm артефакта — гейт пускает' {
        & git -C $artMe rm -q -- $artFile
        $reason = Invoke-CommitGate $artRepo "git -C `"$artMe`" commit -m закрыта -- `"$artMem`" `"$artFile`""
        & git -C $artMe reset -q HEAD -- $artMem $artFile 2>$null
        & git -C $artMe checkout -q -- $artMem $artFile 2>$null
        if ($reason -match 'после коммита на артефакт') { return "гейт остановил: $reason" }
        return $null
    }

    Check 'закрытие задачи, артефакт держит запись бэклога — гейт пускает' {
        Add-Content -LiteralPath $artBacklog -Encoding utf8 -Value '', '## ORD-1 сверить с макетом через месяц', '', 'Сравнить экран с макетом.', '',
            '### Артефакты', '- макет: artifacts/ORD-1-макет.png'
        & git -C $artMe rm -q -- $artMem
        $reason = Invoke-CommitGate $artRepo "git -C `"$artMe`" commit -m закрыта -- `"$artMem`" `"$artBacklog`""
        & git -C $artMe reset -q HEAD -- $artMem 2>$null
        & git -C $artMe checkout -q -- $artMem 2>$null
        Set-Content -LiteralPath $artBacklog -Encoding utf8 -Value $artBacklogSaved -NoNewline
        if ($reason -match 'после коммита на артефакт') { return "гейт остановил: $reason" }
        return $null
    }

    Copy-Item -LiteralPath $repo -Destination $copy -Recurse -Force
    Check 'копия каталога вместе с .git — остановка' { ExpectText $copy 'не числит эту копию' }
    Check 'копия каталога вместе с .git — отчёт link.ps1 красный' { ExpectLinkReport $copy 1 'связь односторонняя' }

    # Поле, которого в схеме нет, переживает добавление копии.
    Check 'добавление копии — прочие поля файла машины целы' {
        $listPath = Join-Path $base 'local\me.json'
        $m = Get-Content -LiteralPath $listPath -Raw | ConvertFrom-Json
        $m | Add-Member -NotePropertyName 'note' -NotePropertyValue 'поле будущей версии' -Force
        $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $listPath -Encoding utf8
        & pwsh -NoProfile -File $link -Path $copy -Base $base | Out-Null
        $after = Get-Content -LiteralPath $listPath -Raw | ConvertFrom-Json
        if ($after.note -ne 'поле будущей версии') { return 'поле note потеряно' }
        if ($after.operator -ne $script:op) { return 'имя оператора потеряно' }
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

    Check 'файл прямо в work/ — сверка называет, содержимое не подано' {
        $stray = Join-Path (Get-MeDir $base) 'work\stray.md'
        Set-KitMemory $stray $repo 'память вне каталога машины'
        $problem = ExpectText $repo 'вне каталога машины' -Lacks 'память вне каталога машины'
        Remove-Item -LiteralPath $stray -Force
        return $problem
    }

    # Вторая машина с тем же путём копии: стенд подменяет имя машины, а её пустой local\ —
    # отложив в сторону список копий первой.
    $listPath = Join-Path $base 'local\me.json'
    $listSaved = Get-Content -LiteralPath $listPath -Raw
    $firstMachineDir = 'work\' + (Split-Path (Split-Path $script:memRepo -Parent) -Leaf) + '\'
    $machineSaved = $env:COMPUTERNAME
    $env:COMPUTERNAME = 'second-machine'
    Remove-Item -LiteralPath $listPath -Force
    try {
        Check 'вторая машина — копию не числит, остановка' { ExpectText $repo 'на этой машине она не числит' }
        & pwsh -NoProfile -File $link -Path $repo -Base $base | Out-Null
        Check 'вторая машина — оператор не назван, остановка' { ExpectText $repo 'оператор на этой машине не назван' }
        Check 'вторая машина — оператор не назван, отчёт link.ps1 красный' { ExpectLinkReport $repo 1 'на этой машине не назван' }
        Invoke-BaseInit $base '' | Out-Null
        $second = Invoke-Hook $repo
        Check 'вторая машина, тот же путь копии — адрес памяти свой, память первой не подана' {
            $mem = Find-HookMemoryPath $second
            if (-not $mem) { return "хук не назвал адрес памяти: $($second.Split("`n")[0])" }
            if ($mem -ieq $script:memRepo) { return "адрес тот же, что у первой машины: $mem" }
            return Test-HookText $second -Lacks 'дочитать формат позиции'
        }
        Check 'вторая машина — копии и память первой сверка не называет' {
            Test-HookText $second 'проект под китом' -Lacks $firstMachineDir, $copy
        }
    }
    finally {
        $env:COMPUTERNAME = $machineSaved
        Set-Content -LiteralPath $listPath -Value $listSaved -Encoding utf8 -NoNewline
    }

    # Имя названо, а личного репозитория на машине нет — памяти и бэклогу негде жить.
    $meAway = Join-Path $root 'me-away'
    Move-Item -LiteralPath (Get-MeDir $base) -Destination $meAway
    try {
        Check 'личного репозитория нет — остановка' { ExpectText $repo 'нет личного репозитория' -Lacks 'Три слоя' }
        Check 'личного репозитория нет — отчёт link.ps1 красный' { ExpectLinkReport $repo 1 'личного репозитория на этой машине нет' }
    }
    finally { Move-Item -LiteralPath $meAway -Destination (Get-MeDir $base) }

    & git -C $repo worktree add -q $wt -b wt 2>$null
    $wtFresh = Invoke-Hook $wt
    Check 'worktree — работает как основная копия' { Test-HookText $wtFresh $repo }

    # У worktree база та же, а память своя.
    Check 'worktree — память своя, а не основной копии' {
        $script:memWt = Find-HookMemoryPath $wtFresh
        if (-not $script:memWt) { return 'хук не назвал адрес памяти' }
        if ($script:memWt -ieq $script:memRepo) { return 'адрес тот же, что у основной копии' }
        Set-KitMemory $script:memWt $wt 'работа отдельного worktree'
        return ExpectText $wt 'работа отдельного worktree' -Lacks 'дочитать формат позиции'
    }

    # Без ветки рабочее дерево на месте, значит и память на месте.
    Check 'отсоединённый HEAD — адрес прежний, память на месте' {
        & git -C $wt checkout -q --detach
        $got = Invoke-Hook $wt
        $after = Find-HookMemoryPath $got
        if ($after -ine $script:memWt) { return "адрес уехал: $after" }
        return Test-HookText $got 'работа отдельного worktree'
    }

    # Удаление копии проверяется отказами: каталог уходит с диска насовсем, и безвозвратно с ним
    # уходит только то, чего нет ни в базе, ни в ветке.
    & git -C $repo worktree add -q $gone -b gone 2>$null

    Check 'удаление — основная копия остаётся' {
        $r = Invoke-WorktreeRemove $repo
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'основная копия') { return "отказ не про основную копию: $($r.text)" }
        if (-not (Test-Path -LiteralPath $repo)) { return 'основная копия всё-таки удалена' }
        return $null
    }

    # Дочерний pwsh наследует каталог родителя — так проверяется отказ по месту запуска.
    Check 'удаление — запуск изнутри копии не удаляет её' {
        Push-Location -LiteralPath $gone
        try { $r = Invoke-WorktreeRemove $gone } finally { Pop-Location }
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'запущен внутри') { return "отказ не про место запуска: $($r.text)" }
        if (-not (Test-Path -LiteralPath $gone)) { return 'копия всё-таки удалена' }
        return $null
    }

    Check 'удаление — живая память держит копию' {
        $memory = Get-HookMemoryPath $gone
        if (-not $memory) { return 'хук не назвал адрес памяти' }
        Set-KitMemory $memory $gone 'работа удаляемой копии'
        $r = Invoke-WorktreeRemove $gone
        Remove-Item -LiteralPath $memory -Force
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch [regex]::Escape($memory)) { return "в отказе не назван файл памяти: $($r.text)" }
        if (-not (Test-Path -LiteralPath $gone)) { return 'копия всё-таки удалена' }
        return $null
    }

    Check 'удаление — незакоммиченное держит копию' {
        $draft = Join-Path $gone 'draft.txt'
        Set-Content -LiteralPath $draft -Value 'не закоммичено'
        $r = Invoke-WorktreeRemove $gone
        Remove-Item -LiteralPath $draft -Force
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'draft\.txt') { return "в отказе не назван файл: $($r.text)" }
        if (-not (Test-Path -LiteralPath $gone)) { return 'копия всё-таки удалена' }
        return $null
    }

    Check 'удаление — чистая копия уходит, ветка остаётся' {
        $r = Invoke-WorktreeRemove $gone
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if (Test-Path -LiteralPath $gone) { return 'каталог копии на месте' }
        & git -C $repo show-ref --verify --quiet 'refs/heads/gone' 2>$null
        if ($LASTEXITCODE -ne 0) { return 'ветка ушла вместе с копией' }
        return $null
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
        $m = Get-Content -LiteralPath (Join-Path $baseFoo 'local\me.json') -Raw | ConvertFrom-Json
        $ws = @($m.workspaces)
        if ($ws.Count -ne 1) { return "копий в списке $($ws.Count), ожидалась одна" }
        if ($ws[0] -ine $modFoo) { return "числится «$($ws[0])», ожидался «$modFoo»" }
        return $null
    }

    & pwsh -NoProfile -File $link -Path $modBar -Base $baseBar -Scope Directory | Out-Null
    Check 'два каталога одного репозитория — каждый со своей базой' {
        $problem = ExpectText $modFoo $baseFoo
        if ($problem) { return $problem }
        return ExpectText $modBar $baseBar -Lacks $baseFoo
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
    $wtFoo = Join-Path $monoWt 'packages\foo'
    $wtFooGot = Invoke-Hook $wtFoo
    Check 'связанный каталог в worktree — база та же, память своя' {
        $problem = Test-HookText $wtFooGot $baseFoo
        if ($problem) { return $problem }
        $memMain = Get-HookMemoryPath $modFoo
        $memWt = Find-HookMemoryPath $wtFooGot
        if (-not $memWt) { return 'хук не назвал адрес памяти' }
        if ($memWt -ieq $memMain) { return 'адрес тот же, что у основной копии' }
        return $null
    }

    Check 'связанный каталог в worktree — рабочая копия названа путём worktree, основная отдельно' {
        Test-HookText $wtFooGot "- Рабочая копия: ``$wtFoo``", "- Основная копия: ``$modFoo``", "рабочая копия: $wtFoo``"
    }

    Check 'отчёт link.ps1 в корне монорепы — называет связанные каталоги' {
        ExpectLinkReport $mono 0 'packages/foo'
    }

    # Субагенты оператора: гоняется настоящий скрипт раскладки. Проверяется то, чем раскладка
    # отличается от копирования файла, — git проекта её не видит, личный репозиторий верен, чужое не тронуто.
    $agentsDir = Join-Path (Get-OpDir $base) 'agents'
    $copyAgents = Join-Path (Join-Path $repo '.claude') 'agents'
    New-Item -ItemType Directory -Force -Path $agentsDir | Out-Null
    $scout = Join-Path $agentsDir 'scout.md'
    $scoutLines = @('---', 'name: scout', 'description: "разведчик"', '---', '', 'разведать')
    Set-Content -LiteralPath $scout -Encoding utf8 -Value $scoutLines
    # Выложенный в people\ субагент в копию не едет: агент работает по личному репозиторию.
    $alienAgents = Join-Path (Get-PeopleDir $base) 'agents'
    New-Item -ItemType Directory -Force -Path $alienAgents | Out-Null
    Set-Content -LiteralPath (Join-Path $alienAgents 'alien.md') -Encoding utf8 -Value '---', 'name: alien', '---', '', 'чужой'

    Check 'субагент оператора довезён в копию и спрятан от git проекта, выложенный в people\ — нет' {
        $r = Invoke-AgentsDeploy $repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if (Test-Path -LiteralPath (Join-Path $copyAgents 'alien.md')) { return 'довезён выложенный субагент' }
        $dst = Join-Path $copyAgents 'scout.md'
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { return 'файла в копии нет' }
        if ((Get-Content -LiteralPath $dst -Raw) -cne (Get-Content -LiteralPath $scout -Raw)) { return 'файл копии не совпал с личным репозиторием' }
        $dirty = @(& git -C $repo status --porcelain | Where-Object { $_ })
        if ($dirty.Count) { return "git копии видит разложенное: $($dirty -join '; ')" }
        return $null
    }

    # Копия — производная: правка в ней — расхождение, и верен личный репозиторий.
    Check 'правка в копии — находка сверки, прогон возвращает личный репозиторий' {
        Add-Content -LiteralPath (Join-Path $copyAgents 'scout.md') -Value 'правка мимо личного репозитория'
        $problem = ExpectText $repo 'в копии разошлись с личным репозиторием'
        if ($problem) { return $problem }
        $r = Invoke-AgentsDeploy $repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath (Join-Path $copyAgents 'scout.md') -Raw) -cne (Get-Content -LiteralPath $scout -Raw)) { return 'копия не возвращена к личному репозиторию' }
        return ExpectNoText $repo 'в копии разошлись с личным репозиторием'
    }

    Check 'имя занято отслеживаемым файлом проекта — файл проекта не тронут' {
        $own = Join-Path $copyAgents 'guard.md'
        Set-Content -LiteralPath $own -Encoding utf8 -Value '---', 'name: guard', '---', '', 'файл проекта'
        & git -C $repo add -f -- '.claude/agents/guard.md' 2>$null | Out-Null
        & git -C $repo commit -qm 'агент проекта' 2>$null | Out-Null
        Set-Content -LiteralPath (Join-Path $agentsDir 'guard.md') -Encoding utf8 -Value '---', 'name: guard', '---', '', 'файл личного репозитория'
        $r = Invoke-AgentsDeploy $repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath $own -Raw) -notmatch 'файл проекта') { return 'файл проекта перезаписан' }
        return ExpectText $repo 'имя занято отслеживаемым файлом проекта'
    }

    Check 'снятый из личного репозитория уходит из копии, файл проекта остаётся' {
        Remove-Item -LiteralPath (Join-Path $agentsDir 'guard.md') -Force
        $problem = ExpectNoText $repo 'остались в копии от прежней раскладки'
        if ($problem) { return $problem }
        Remove-Item -LiteralPath $scout -Force
        $r = Invoke-AgentsDeploy $repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if (Test-Path -LiteralPath (Join-Path $copyAgents 'scout.md')) { return 'снятый субагент остался в копии' }
        if (-not (Test-Path -LiteralPath (Join-Path $copyAgents 'guard.md') -PathType Leaf)) { return 'файл проекта удалён' }
        & git -C $repo rm -q --cached -- '.claude/agents/guard.md' 2>$null | Out-Null
        & git -C $repo commit -qm 'агент проекта снят' 2>$null | Out-Null
        Remove-Item -LiteralPath (Join-Path $copyAgents 'guard.md') -Force
        Set-Content -LiteralPath $scout -Encoding utf8 -Value $scoutLines
        return $null
    }

    # Новой копии субагенты нужны с первой секунды: без них этап зовёт того, кого в ней нет.
    Check 'заведённая рабочая копия получает субагентов оператора' {
        $out = (& pwsh -NoProfile -File $script:wtAdd -Path $repo -Name 'agents-copy' 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { return "код возврата $LASTEXITCODE : $out" }
        $fresh = Join-Path (Split-Path $repo -Parent) 'agents-copy'
        $dst = Join-Path (Join-Path (Join-Path $fresh '.claude') 'agents') 'scout.md'
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { return "субагента в новой копии нет: $out" }
        $dirty = @(& git -C $fresh status --porcelain | Where-Object { $_ })
        if ($dirty.Count) { return "git новой копии видит разложенное: $($dirty -join '; ')" }
        return $null
    }

    # Связывание копии — тот же момент раскладки: у второй копии проекта субагенты в личном репозитории уже есть.
    Check 'связанная копия получает субагентов оператора' {
        $late = Join-Path $root 'late'
        New-TestRepo $late
        $out = (& pwsh -NoProfile -File $link -Path $late -Base $base 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { return "код возврата $LASTEXITCODE : $out" }
        $dst = Join-Path (Join-Path (Join-Path $late '.claude') 'agents') 'scout.md'
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { return "субагента в связанной копии нет: $out" }
        $dirty = @(& git -C $late status --porcelain | Where-Object { $_ })
        if ($dirty.Count) { return "git связанной копии видит разложенное: $($dirty -join '; ')" }
        return $null
    }

    # Файл исключений у копий репозитория общий, а состав занятых имён у них разный: собирай кит
    # блок по составу той копии, где идёт, — прогон в одной снимал бы укрытие с соседней.
    Check 'прогон в соседней копии не снимает укрытия с этой' {
        $r = Invoke-AgentsDeploy $repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if (-not (Test-Path -LiteralPath (Join-Path $copyAgents 'scout.md') -PathType Leaf)) { return 'субагента в копии нет' }
        $own = Join-Path (Join-Path (Join-Path $wt '.claude') 'agents') 'scout.md'
        New-Item -ItemType Directory -Force -Path (Split-Path $own -Parent) | Out-Null
        Set-Content -LiteralPath $own -Encoding utf8 -Value '---', 'name: scout', '---', '', 'файл проекта'
        & git -C $wt add -f -- '.claude/agents/scout.md' 2>$null | Out-Null
        $r = Invoke-AgentsDeploy $wt
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        $dirty = @(& git -C $repo status --porcelain | Where-Object { $_ })
        if ($dirty.Count) { return "git копии видит разложенное после прогона в соседней: $($dirty -join '; ')" }
        & git -C $wt rm -q --cached -- '.claude/agents/scout.md' 2>$null | Out-Null
        Remove-Item -LiteralPath $own -Force
        return $null
    }

    # Укрытие слетает и мимо кита: файл исключений почистили руками, копия стоит на старом ките.
    # Файл при этом довезён и сверен с личным репозиторием — назвать пропажу больше нечему.
    Check 'укрытие слетело — сверка называет' {
        $exclude = Join-Path (Join-Path (Join-Path $repo '.git') 'info') 'exclude'
        Set-Content -LiteralPath $exclude -Encoding utf8 -Value ''
        $problem = ExpectText $repo 'видны git проекта'
        if ($problem) { return $problem }
        $r = Invoke-AgentsDeploy $repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        $problem = ExpectNoText $repo 'видны git проекта'
        if ($problem) { return $problem }
        $dirty = @(& git -C $repo status --porcelain | Where-Object { $_ })
        if ($dirty.Count) { return "укрытие не вернулось: $($dirty -join '; ')" }
        return $null
    }

    # Файл исключений у репозитория один на все копии и каталоги, а блоки в нём не общие.
    Check 'монорепа — у каждого связанного каталога свой блок исключений' {
        foreach ($pair in @(@($baseFoo, $modFoo, 'foo-scout'), @($baseBar, $modCase, 'case-scout'))) {
            $dir = Join-Path (Get-OpDir $pair[0]) 'agents'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir ($pair[2] + '.md')) -Encoding utf8 -Value '---', ('name: ' + $pair[2]), '---', '', 'разведать'
            $r = Invoke-AgentsDeploy $pair[1]
            if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        }
        foreach ($pair in @(@($modFoo, 'foo-scout'), @($modCase, 'case-scout'))) {
            $dst = Join-Path (Join-Path (Join-Path $pair[0] '.claude') 'agents') ($pair[1] + '.md')
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { return "нет $($pair[1]) в $($pair[0])" }
        }
        $exclude = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $mono '.git') 'info') 'exclude') -Raw
        foreach ($line in '/packages/foo/.claude/agents/foo-scout.md', '/mixed/case/.claude/agents/case-scout.md') {
            if ($exclude -notmatch [regex]::Escape($line)) { return "в исключениях нет строки $line" }
        }
        $dirty = @(& git -C $mono status --porcelain | Where-Object { $_ })
        if ($dirty.Count) { return "git монорепы видит разложенное: $($dirty -join '; ')" }
        return $null
    }

    Move-Item -LiteralPath $base -Destination $moved
    Check 'база переименована — указатель разорван' { ExpectText $repo 'указатель разорван' }
    Move-Item -LiteralPath $moved -Destination $base

    & git -C $repo config --local agents-kit.base $notbase
    Check 'каталог без agents-kit.json — не база' { ExpectText $repo 'ведёт не в базу' }

    # Сведение с remote: две машины одного оператора — две базы, склонированные с одного bare,
    # и личные репозитории с одним bare. Remote — каталог на диске: сеть стенду не нужна.
    New-TestRepo $syncRepoA
    Invoke-BaseInit $syncBaseA | Out-Null
    & pwsh -NoProfile -File $link -Path $syncRepoA -Base $syncBaseA | Out-Null
    $syncMeA = Get-MeDir $syncBaseA
    $syncMeB = Get-MeDir $syncBaseB

    Check 'сведение без origin — сводить не с чем, код 0' {
        $r = Invoke-Sync $syncRepoA 'Base' 'Push'
        if ($r.code -ne 0) { return "код $($r.code): $($r.text)" }
        if ($r.text -notmatch 'нет origin') { return "не сказано, что origin нет: $($r.text)" }
        return $null
    }

    & git clone -q --bare $syncBaseA $syncBare 2>$null
    & git -C $syncBaseA remote add origin $syncBare
    & git clone -q --bare $syncMeA $syncMe 2>$null
    & git -C $syncMeA remote add origin $syncMe
    & git clone -q $syncBare $syncBaseB 2>$null
    Invoke-BaseInit $syncBaseB 'ORD' $script:op $syncMe | Out-Null
    New-TestRepo $syncRepoB
    & pwsh -NoProfile -File $link -Path $syncRepoB -Base $syncBaseB | Out-Null

    Check 'отдать базу — коммит на remote, другая машина его забирает и видит пришедший файл' {
        Set-Content -LiteralPath (Join-Path $syncBaseA 'product.md') -Value '# Сведение — продукт', '', 'строка с машины A' -Encoding utf8
        & git -C $syncBaseA commit -qm 'A: product' -- product.md
        $r = Invoke-Sync $syncRepoA 'Base' 'Push'
        if ($r.code -ne 0) { return "отдание: код $($r.code): $($r.text)" }
        if ((Get-Head $syncBare) -ne (Get-Head $syncBaseA)) { return 'на remote не тот коммит' }
        $r = Invoke-Sync $syncRepoB 'Base' 'Pull'
        if ($r.code -ne 0) { return "забирание: код $($r.code): $($r.text)" }
        if ($r.text -notmatch 'product\.md') { return "не назван пришедший файл: $($r.text)" }
        if ((Get-Head $syncBaseB) -ne (Get-Head $syncBaseA)) { return 'вторая машина не забрала коммит' }
        return $null
    }

    Check 'забрать при незакоммиченной правке другого файла — перемотка, правка цела' {
        Set-Content -LiteralPath (Join-Path $syncBaseA 'team.md') -Value '# Правила команды', '', 'правило с машины A' -Encoding utf8
        & git -C $syncBaseA commit -qm 'A: team' -- team.md
        Invoke-Sync $syncRepoA 'Base' 'Push' | Out-Null
        $product = Join-Path $syncBaseB 'product.md'
        Add-Content -LiteralPath $product -Value 'незакоммиченная правка соседней сессии' -Encoding utf8
        try {
            $r = Invoke-Sync $syncRepoB 'Base' 'Pull'
            if ($r.code -ne 0) { return "код $($r.code): $($r.text)" }
            if ((Get-Head $syncBaseB) -ne (Get-Head $syncBaseA)) { return 'не перемотано' }
            if ((Get-Content -LiteralPath $product -Raw) -notmatch 'незакоммиченная правка') { return 'правка соседней сессии пропала' }
            return $null
        }
        finally { & git -C $syncBaseB checkout -q -- product.md }
    }

    Check 'отдание отклонено — забрано rebase и отдано, мержей нет' {
        Set-Content -LiteralPath (Join-Path $syncBaseA 'team.md') -Value '# Правила команды', '', 'второе правило с машины A' -Encoding utf8
        & git -C $syncBaseA commit -qm 'A: team 2' -- team.md
        Invoke-Sync $syncRepoA 'Base' 'Push' | Out-Null
        $decision = Join-Path $syncBaseB 'decisions\sync.md'
        New-Item -ItemType Directory -Force -Path (Split-Path $decision -Parent) | Out-Null
        Set-Content -LiteralPath $decision -Value '# Сведение', 'когда: правка сведения', '', '## Тема', '- решение с машины B' -Encoding utf8
        & git -C $syncBaseB add -- decisions/sync.md
        & git -C $syncBaseB commit -qm 'B: decision' -- decisions/sync.md
        $r = Invoke-Sync $syncRepoB 'Base' 'Push'
        if ($r.code -ne 0) { return "код $($r.code): $($r.text)" }
        if ((Get-Head $syncBare) -ne (Get-Head $syncBaseB)) { return 'на remote не коммит машины B' }
        $merges = @(& git -C $syncBaseB rev-list --merges HEAD | Where-Object { $_ })
        if ($merges.Count) { return 'в истории базы появился мерж' }
        return $null
    }

    # Конфликт держится недоделанным сведением: его видят хук, гейт и отчёт связи без сети.
    Invoke-Sync $syncRepoA 'Base' 'Pull' | Out-Null
    Set-Content -LiteralPath (Join-Path $syncBaseA 'product.md') -Value '# Сведение — продукт', '', 'редакция машины A' -Encoding utf8
    & git -C $syncBaseA commit -qm 'A: product 2' -- product.md
    Invoke-Sync $syncRepoA 'Base' 'Push' | Out-Null
    Set-Content -LiteralPath (Join-Path $syncBaseB 'product.md') -Value '# Сведение — продукт', '', 'редакция машины B' -Encoding utf8
    & git -C $syncBaseB commit -qm 'B: product 2' -- product.md
    $conflict = Invoke-Sync $syncRepoB 'Base' 'Push'

    Check 'конфликт — сведение стоит недоделанным, вывод называет файл и команду' {
        if ($conflict.code -ne 1) { return "код $($conflict.code): $($conflict.text)" }
        if (-not (Test-Path -LiteralPath (Join-Path $syncBaseB '.git\rebase-merge'))) { return 'rebase не идёт' }
        foreach ($needle in 'product.md', '-Action Continue') {
            if ($conflict.text -notmatch [regex]::Escape($needle)) { return "в выводе нет «$needle»: $($conflict.text)" }
        }
        return $null
    }

    Check 'конфликт — хук останавливает работу со знанием' {
        Test-HookText (Invoke-Hook $syncRepoB) @('сведение с remote не закончено', 'product.md') @('Три слоя', 'редакция машины')
    }

    Check 'конфликт — гейт отказывает коммиту в базу и в личный репозиторий, отчёт link.ps1 красный' {
        foreach ($target in $syncBaseB, $syncMeB) {
            $reason = Invoke-CommitGate $syncRepoB "git -C `"$target`" commit -m x -- x.md"
            if ($reason -notmatch 'не закончено сведение') { return "гейт пустил коммит в $target`: $reason" }
        }
        return ExpectLinkReport $syncRepoB 1 'не закончено сведение'
    }

    Check 'доделать с метками конфликта — отказ' {
        $r = Invoke-Sync $syncRepoB 'Base' 'Continue'
        if ($r.code -ne 1) { return "код $($r.code): $($r.text)" }
        if ($r.text -notmatch 'метки конфликта') { return "отказ не про метки: $($r.text)" }
        return $null
    }

    Check 'доделать после сведения файла — отдано, хук снова подаёт базу' {
        Set-Content -LiteralPath (Join-Path $syncBaseB 'product.md') -Value '# Сведение — продукт', '', 'редакция машины A', 'редакция машины B' -Encoding utf8
        $r = Invoke-Sync $syncRepoB 'Base' 'Continue'
        if ($r.code -ne 0) { return "код $($r.code): $($r.text)" }
        if (Test-Path -LiteralPath (Join-Path $syncBaseB '.git\rebase-merge')) { return 'rebase всё ещё идёт' }
        if ((Get-Head $syncBare) -ne (Get-Head $syncBaseB)) { return 'сведённое не отдано' }
        return Test-HookText (Invoke-Hook $syncRepoB) @('Три слоя', 'редакция машины B')
    }

    # Двоичный файл ответом текстом не свести — сторону называет -Keep.
    Check 'конфликт в двоичном артефакте — -Keep берёт сторону, сведено и отдано' {
        Invoke-Sync $syncRepoA 'Base' 'Pull' | Out-Null
        $artA = Join-Path $syncBaseA 'artifacts\scheme.bin'
        $artB = Join-Path $syncBaseB 'artifacts\scheme.bin'
        New-Item -ItemType Directory -Force -Path (Split-Path $artA -Parent), (Split-Path $artB -Parent) | Out-Null
        [System.IO.File]::WriteAllBytes($artA, [byte[]](0, 1, 2, 3))
        & git -C $syncBaseA add -- artifacts/scheme.bin
        & git -C $syncBaseA commit -qm 'A: artifact' -- artifacts/scheme.bin
        Invoke-Sync $syncRepoA 'Base' 'Push' | Out-Null
        [System.IO.File]::WriteAllBytes($artB, [byte[]](0, 9, 9, 9))
        & git -C $syncBaseB add -- artifacts/scheme.bin
        & git -C $syncBaseB commit -qm 'B: artifact' -- artifacts/scheme.bin
        $r = Invoke-Sync $syncRepoB 'Base' 'Push'
        if ($r.code -ne 1) { return "конфликта нет, код $($r.code): $($r.text)" }
        $out = & pwsh -NoProfile -File $script:sync -Path $syncRepoB -Repo Base -Action Continue -Keep 'artifacts/scheme.bin=Local' 2>&1
        if ($LASTEXITCODE -ne 0) { return "доделать: код $LASTEXITCODE`: $($out -join ' ')" }
        if ((Get-Head $syncBare) -ne (Get-Head $syncBaseB)) { return 'сведённое не отдано' }
        if (([System.IO.File]::ReadAllBytes($artB) -join ',') -ne '0,9,9,9') { return 'в файле не редакция этой машины' }
        return $null
    }

    Check 'remote недоступен — код 2, база не тронута' {
        $head = Get-Head $syncBaseB
        & git -C $syncBaseB remote set-url origin (Join-Path $root 'no-such-remote.git')
        try {
            $r = Invoke-Sync $syncRepoB 'Base' 'Pull'
            if ($r.code -ne 2) { return "код $($r.code): $($r.text)" }
            if ($r.text -notmatch 'недоступен') { return "не сказано, что remote недоступен: $($r.text)" }
            if ((Get-Head $syncBaseB) -ne $head) { return 'база сдвинулась' }
            return $null
        }
        finally { & git -C $syncBaseB remote set-url origin $syncBare }
    }

    Check 'личный репозиторий — отдан с одной машины, забран на другой' {
        Add-Content -LiteralPath (Join-Path $syncMeA 'backlog.md') -Value '', '## ORD-1 Запись с машины A', '', 'текст' -Encoding utf8
        & git -C $syncMeA commit -qm 'A: backlog' -- backlog.md
        $r = Invoke-Sync $syncRepoA 'Personal' 'Push'
        if ($r.code -ne 0) { return "отдание: код $($r.code): $($r.text)" }
        $r = Invoke-Sync $syncRepoB 'Personal' 'Pull'
        if ($r.code -ne 0) { return "забирание: код $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath (Join-Path $syncMeB 'backlog.md') -Raw) -notmatch 'Запись с машины A') { return 'запись не пришла' }
        return $null
    }

    # Формат базы. Своя база и копия: agents-kit.json правится проверками и уходит в коммит базы.
    New-TestRepo $migRepo
    Invoke-BaseInit $migBase | Out-Null
    & pwsh -NoProfile -File $link -Path $migRepo -Base $migBase | Out-Null
    $kitFormat = 1
    $steps = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'plugin\migrations') -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match '^(\d{3})-') { [int]$Matches[1] } } | Sort-Object)
    if ($steps.Count) { $kitFormat = $steps[-1] }

    Check 'новая база — в agents-kit.json формат, который ждёт кит' {
        $got = Get-MarkerFormat $migBase
        if ($got -ne $kitFormat) { return "формат $got, ожидался $kitFormat" }
        return $null
    }

    Check 'база новее кита — остановка, гейт отказывает, отчёт link.ps1 красный' {
        Set-MarkerFormat $migBase ($kitFormat + 1)
        try {
            $problem = ExpectText $migRepo 'база новее кита'
            if ($problem) { return $problem }
            $reason = Invoke-CommitGate $migRepo "git -C `"$migBase`" commit -m x -- product.md"
            if ($reason -notmatch 'кит новее этого') { return "гейт не отказал: $reason" }
            return ExpectLinkReport $migRepo 1 'формат не тот'
        }
        finally { & git -C $migBase checkout -q -- agents-kit.json }
    }

    Check 'agents-kit.json без формата или с нечисловым — не база' {
        try {
            foreach ($bad in @($null, 'abc', 0)) {
                Set-MarkerFormat $migBase $bad
                $problem = ExpectText $migRepo 'ведёт не в базу'
                if ($problem) { return "version = «$bad»: $problem" }
            }
            return $null
        }
        finally { & git -C $migBase checkout -q -- agents-kit.json }
    }

    # Порядок перевода проверяется на копии кита с поддельным шагом поверх настоящих: база стенда
    # уже того формата, что ждёт кит, и поддельный шаг переводит её на следующий.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'plugin') -Destination $kitCopy -Recurse
    $copyMigrations = Join-Path $kitCopy 'migrations'
    New-Item -ItemType Directory -Force -Path $copyMigrations | Out-Null
    $copyScripts = Join-Path $kitCopy 'scripts'
    $copyHook = Join-Path $copyScripts 'session-start.ps1'
    $copyGate = Join-Path $copyScripts 'commit-gate.ps1'
    $copyMigrate = Join-Path $copyScripts 'base-migrate.ps1'
    $fakeFormat = $kitFormat + 1
    $stepPath = Join-Path $copyMigrations ('{0:D3}-team-to-limits.ps1' -f $fakeFormat)
    Set-Content -LiteralPath $stepPath -Encoding utf8 -Value @(
        'param([string]$Base)',
        '$to = Join-Path $Base ''limits.md''',
        'if (Test-Path -LiteralPath $to) { return }',
        'Move-Item -LiteralPath (Join-Path $Base ''team.md'') -Destination $to')

    Check 'база в прежнем формате — остановка и команда перевода' {
        $got = Invoke-Hook $migRepo $copyHook
        if ($got -notmatch 'база в прежнем формате') { return "нет остановки: $($got.Split("`n")[0])" }
        if ($got -notmatch 'base-migrate\.ps1') { return 'не названа команда перевода' }
        if ($got -match 'Три слоя') { return 'поданы инварианты — работа со знанием не остановлена' }
        return $null
    }

    Check 'база в прежнем формате — гейт отказывает коммиту в базу' {
        $reason = Invoke-CommitGate $migRepo "git -C `"$migBase`" commit -m x -- product.md" $copyGate
        if ($reason -notmatch "кит ждёт формат $fakeFormat") { return "гейт не отказал: $reason" }
        return $null
    }

    Check 'перевод при незакоммиченном в базе — отказ, база не тронута' {
        $stray = Join-Path $migBase 'stray.md'
        Set-Content -LiteralPath $stray -Value 'соседняя работа' -Encoding utf8
        try {
            $r = Invoke-BaseMigrate $copyMigrate $migRepo
            if ($r.code -eq 0) { return 'скрипт не отказал' }
            if ($r.text -notmatch 'stray\.md') { return "не назван незакоммиченный файл: $($r.text)" }
            if ((Get-MarkerFormat $migBase) -ne $kitFormat) { return 'формат поднят' }
            if (-not (Test-Path -LiteralPath (Join-Path $migBase 'team.md'))) { return 'шаг всё-таки сделан' }
            return $null
        }
        finally { Remove-Item -LiteralPath $stray -Force }
    }

    Check 'перевод — шаг сделан, формат поднят, один коммит, дерево чистое, связь сошлась' {
        $before = Get-CommitCount $migBase
        $r = Invoke-BaseMigrate $copyMigrate $migRepo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-MarkerFormat $migBase) -ne $fakeFormat) { return "формат $(Get-MarkerFormat $migBase), ожидался $fakeFormat" }
        if (-not (Test-Path -LiteralPath (Join-Path $migBase 'limits.md')) -or (Test-Path -LiteralPath (Join-Path $migBase 'team.md'))) { return 'шаг не сделан' }
        if ((Get-CommitCount $migBase) -ne $before + 1) { return "коммитов прибавилось $((Get-CommitCount $migBase) - $before), ожидался 1" }
        $dirty = @(& git -C $migBase status --porcelain | Where-Object { $_ })
        if ($dirty.Count) { return "в базе осталось незакоммиченное: $($dirty -join '; ')" }
        $got = Invoke-Hook $migRepo $copyHook
        if ($got -notmatch 'проект под китом') { return "после перевода нет подачи: $($got.Split("`n")[0])" }
        return $null
    }

    Check 'повторный перевод — переводить нечего' {
        $r = Invoke-BaseMigrate $copyMigrate $migRepo
        if ($r.code -ne 0 -or $r.text -notmatch 'переводить нечего') { return "код $($r.code): $($r.text)" }
        return $null
    }

    Check 'новая база на ките с шагами — в agents-kit.json последний формат' {
        New-TestRepo $newRepo
        Invoke-BaseInit $newBase -Script (Join-Path $copyScripts 'base-init.ps1') | Out-Null
        & pwsh -NoProfile -File (Join-Path $copyScripts 'link.ps1') -Path $newRepo -Base $newBase | Out-Null
        $got = Get-MarkerFormat $newBase
        if ($got -ne $fakeFormat) { return "формат $got, ожидался $fakeFormat" }
        return $null
    }

    Check 'шаг перевода упал — его правки откачены, формат прежний, коммита нет' {
        & git -C $migBase reset -q --hard HEAD~1
        Set-Content -LiteralPath $stepPath -Encoding utf8 -Value @(
            'param([string]$Base)',
            'Set-Content -LiteralPath (Join-Path $Base ''half.md'') -Value ''полшага''',
            'Set-Content -LiteralPath (Join-Path $Base ''product.md'') -Value ''испорчено''',
            'throw ''team.md не опознан''')
        $before = Get-CommitCount $migBase
        $product = Get-Content -LiteralPath (Join-Path $migBase 'product.md') -Raw
        $r = Invoke-BaseMigrate $copyMigrate $migRepo
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'team\.md не опознан') { return "не названа причина: $($r.text)" }
        if ((Get-MarkerFormat $migBase) -ne $kitFormat) { return 'формат поднят' }
        if ((Get-CommitCount $migBase) -ne $before) { return 'коммит всё-таки сделан' }
        # Концы строк при откате ставит git по настройке машины, сравнивается текст.
        if ((Get-Content -LiteralPath (Join-Path $migBase 'product.md') -Raw).Replace("`r`n", "`n") -ne $product.Replace("`r`n", "`n")) { return 'product.md не откачен' }
        $dirty = @(& git -C $migBase status --porcelain --untracked-files=all | Where-Object { $_ })
        if ($dirty.Count) { return "в базе осталось: $($dirty -join '; ')" }
        return $null
    }

    # Настоящие шаги перевода — на базах прежних форматов, собранных руками так, как их вела
    # прежняя версия кита: бэклог, флоу и субагенты в корне базы, память в work/.
    function New-OldBase([string]$Dir, [string]$Repo, $Marker) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        & git -C $Dir init -q
        Set-Content -LiteralPath (Join-Path $Dir '.gitignore') -Value 'local/' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Dir 'product.md') -Value '# Старый проект — продукт' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Dir 'boundaries.md') -Value '# Старый проект — рамки' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Dir 'backlog.md') -Encoding utf8 -Value '# Старый проект — бэклог', 'следующий номер: ORD-3', '',
            '## ORD-2 сверить схему', '', 'Схема: artifacts/both.png.'
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'flow'), (Join-Path $Dir 'agents'), (Join-Path $Dir 'artifacts'), (Join-Path $Dir 'decisions') | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir 'flow\scenarios.md') -Value '# Старый проект — сценарии' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Dir 'agents\scout.md') -Encoding utf8 -Value '---', 'name: scout', '---', '', 'разведать'
        Set-Content -LiteralPath (Join-Path $Dir 'decisions\ui.md') -Encoding utf8 -Value '# Экран', 'когда: правка экрана', '', '- схема: artifacts/both.png'
        foreach ($name in 'memo.png', 'both.png') { Set-Content -LiteralPath (Join-Path $Dir "artifacts\$name") -Value 'png' }
        $Marker | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Dir 'agents-kit.json') -Encoding utf8
        & git -C $Repo config --local agents-kit.base $Dir
    }
    $v1Migrate = Join-Path $scripts 'base-migrate.ps1'

    # Формат 1: список копий в agents-kit.json, память плоско в work/. Запись о копии, которой
    # на диске нет, — копия другой машины.
    New-TestRepo $v1Repo
    New-OldBase $v1Base $v1Repo @{ kit = 'agents-kit'; version = 1; workspaces = @($v1Repo, 'D:\elsewhere\v1') }
    $v1Memory = Join-Path $v1Base 'work\v1-task.md'
    Set-KitMemory $v1Memory $v1Repo 'работа прежнего формата'
    Add-Content -LiteralPath $v1Memory -Encoding utf8 -Value '', '## Артефакты', '- заметка: artifacts/memo.png'
    $v1Foreign = Join-Path $v1Base 'work\elsewhere-task.md'
    Set-KitMemory $v1Foreign 'D:\elsewhere\v1' 'работа другой машины'
    Commit-All $v1Base 'формат 1'

    Check 'перевод без имени оператора — отказ до первого шага' {
        $r = Invoke-BaseMigrate $v1Migrate $v1Repo ''
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch '-Operator') { return "отказ не называет -Operator: $($r.text)" }
        if ((Get-MarkerFormat $v1Base) -ne 1) { return 'формат поднят' }
        return $null
    }

    Check 'перевод с формата 1 — память копии другой машины останавливает, база не тронута' {
        $r = Invoke-BaseMigrate $v1Migrate $v1Repo
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'elsewhere-task\.md') { return "не назван файл памяти: $($r.text)" }
        if ((Get-MarkerFormat $v1Base) -ne 1) { return 'формат поднят' }
        if (-not (Test-Path -LiteralPath $v1Memory)) { return 'своя память уехала' }
        $me = Join-Path $v1Base 'local\me.json'
        if ((Test-Path -LiteralPath $me) -and @((Get-Content -LiteralPath $me -Raw | ConvertFrom-Json).workspaces).Count) { return 'список копий всё-таки записан' }
        return $null
    }

    & git -C $v1Base rm -q -- $v1Foreign
    & git -C $v1Base commit -qm 'задача другой машины закрыта' | Out-Null

    Check 'перевод с формата 1 — бэклог, память, рамки, флоу и субагенты в личном репозитории, флоу выложен' {
        $before = Get-CommitCount $v1Base
        $r = Invoke-BaseMigrate $v1Migrate $v1Repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-MarkerFormat $v1Base) -ne $kitFormat) { return "формат $(Get-MarkerFormat $v1Base), ожидался $kitFormat" }
        $marker = Get-Content -LiteralPath (Join-Path $v1Base 'agents-kit.json') -Raw | ConvertFrom-Json
        if ($marker.PSObject.Properties.Name -contains 'workspaces') { return 'в agents-kit.json остался список копий' }
        if ($marker.prefix -cne 'ORD') { return "в agents-kit.json буквы «$($marker.prefix)», ожидались ORD" }
        $me = Get-Content -LiteralPath (Join-Path $v1Base 'local\me.json') -Raw | ConvertFrom-Json
        $list = @($me.workspaces)
        if ($list.Count -ne 1 -or $list[0] -ine $v1Repo) { return "в списке копий «$($list -join ', ')», ожидалась одна «$v1Repo»" }
        foreach ($gone in 'backlog.md', 'work', 'flow', 'agents', 'artifacts\memo.png', 'boundaries.md') {
            if (Test-Path -LiteralPath (Join-Path $v1Base $gone)) { return "в корне базы остался $gone" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $v1Base 'team.md') -PathType Leaf)) { return 'в корне базы нет team.md' }
        $autonomy = Join-Path (Get-OpDir $v1Base) 'autonomy.md'
        if (-not (Test-Path -LiteralPath $autonomy) -or (Get-Content -LiteralPath $autonomy -Raw) -notmatch 'Старый проект — рамки') { return 'рамки не переехали в личный репозиторий' }
        $meDir = Get-MeDir $v1Base
        foreach ($f in 'backlog.md', 'artifacts\memo.png', 'artifacts\both.png') {
            if (-not (Test-Path -LiteralPath (Join-Path $meDir $f) -PathType Leaf)) { return "в личном репозитории нет $f" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $v1Base 'artifacts\both.png') -PathType Leaf)) { return 'артефакт, на который ссылается знание, ушёл из базы' }
        foreach ($f in 'flow\scenarios.md', 'agents\scout.md') {
            if (-not (Test-Path -LiteralPath (Join-Path (Get-OpDir $v1Base) $f) -PathType Leaf)) { return "в личном репозитории нет $f" }
            if (-not (Test-Path -LiteralPath (Join-Path (Get-PeopleDir $v1Base) $f) -PathType Leaf)) { return "в папке оператора не выложен $f" }
        }
        if (Test-Path -LiteralPath (Join-Path (Get-PeopleDir $v1Base) 'autonomy.md')) { return 'рамки остались в папке оператора' }
        if ((Get-CommitCount $v1Base) -ne $before + $kitFormat - 1) { return "коммитов прибавилось $((Get-CommitCount $v1Base) - $before), ожидалось $($kitFormat - 1)" }
        foreach ($r2 in $v1Base, $meDir) {
            $dirty = @(& git -C $r2 status --porcelain --untracked-files=all | Where-Object { $_ })
            if ($dirty.Count) { return "в $r2 осталось незакоммиченное: $($dirty -join '; ')" }
        }
        $got = Invoke-Hook $v1Repo
        $address = Find-HookMemoryPath $got
        if (-not $address -or -not (Test-Path -LiteralPath $address)) { return "хук назвал адрес «$address», а памяти там нет: $($got.Split("`n")[0])" }
        # Красное о памяти стенда законно: в ней нет сценария. Остальное красное — перевод
        # оставил базу не в том формате, что ждёт кит.
        $fails = @($got -split "`n" | Where-Object { $_ -match '^- \*\*FAIL\*\*' -and $_ -notmatch '\\work\\' })
        if ($fails.Count) { return "сверка после перевода красная: $($fails -join ' | ')" }
        return Test-HookText $got 'работа прежнего формата'
    }

    # Формат 2: список копий в local\workspaces.json, память в каталоге машины. Адрес памяти
    # прежнего формата хук уже не назовёт — он собирается здесь по правилу того формата.
    $v2Repo = Join-Path $root 'v2'
    $v2Base = Join-Path $root 'base-v2'
    New-TestRepo $v2Repo
    New-OldBase $v2Base $v2Repo @{ kit = 'agents-kit'; version = 2 }
    New-Item -ItemType Directory -Force -Path (Join-Path $v2Base 'local') | Out-Null
    @{ workspaces = @($v2Repo) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $v2Base 'local\workspaces.json') -Encoding utf8
    $slug = { param($s) [regex]::Replace($s.ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-').Trim('-') }
    $v2Memory = Join-Path $v2Base ('work\' + (& $slug $env:COMPUTERNAME) + '\' + (& $slug $v2Repo) + '.md')
    Set-KitMemory $v2Memory $v2Repo 'работа формата 2'
    Commit-All $v2Base 'формат 2'

    Check 'перевод с формата 2 — список копий в local\me.json, память в личном репозитории' {
        $r = Invoke-BaseMigrate $v1Migrate $v2Repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if (Test-Path -LiteralPath (Join-Path $v2Base 'local\workspaces.json')) { return 'local\workspaces.json остался' }
        $me = Get-Content -LiteralPath (Join-Path $v2Base 'local\me.json') -Raw | ConvertFrom-Json
        if (@($me.workspaces).Count -ne 1 -or $me.operator -ne $script:op) { return "в local\me.json: $($me | ConvertTo-Json -Compress)" }
        $got = Invoke-Hook $v2Repo
        return Test-HookText $got 'работа формата 2', 'проект под китом'
    }

    # Формат 3: рамки одни на команду — <база>\boundaries.md, операторов в people\ уже двое, флоу
    # в папке оператора. Собирается из свежей базы, отведённой к раскладке того формата.
    $v3Repo = Join-Path $root 'v3'
    $v3Base = Join-Path $root 'base-v3'
    New-TestRepo $v3Repo
    Invoke-BaseInit $v3Base | Out-Null
    & pwsh -NoProfile -File $link -Path $v3Repo -Base $v3Base | Out-Null
    Set-MarkerFormat $v3Base 3
    & git -C (Get-MeDir $v3Base) rm -rq -- autonomy.md flow
    & git -C (Get-MeDir $v3Base) commit -qm 'формат 3' | Out-Null
    Remove-Item -LiteralPath (Join-Path $v3Base 'team.md') -Force
    Set-Content -LiteralPath (Join-Path $v3Base 'boundaries.md') -Encoding utf8 -Value '# Проект — рамки', '', 'общая рамка формата 3'
    $v3Other = Join-Path $v3Base 'people\other'
    New-Item -ItemType Directory -Force -Path (Join-Path $v3Other 'flow') | Out-Null
    Set-Content -LiteralPath (Join-Path $v3Other 'flow\scenarios.md') -Value '# Сценарии коллеги' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $v3Other 'autonomy.md') -Value '# Свои рамки коллеги' -Encoding utf8
    Commit-All $v3Base 'формат 3'

    Check 'перевод с формата 3 — у коллеги уже другие рамки: отказ, база не тронута' {
        $r = Invoke-BaseMigrate $v1Migrate $v3Repo
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'people\\other\\autonomy\.md') { return "не назван файл коллеги: $($r.text)" }
        if ((Get-MarkerFormat $v3Base) -ne 3) { return 'формат поднят' }
        if (-not (Test-Path -LiteralPath (Join-Path $v3Base 'boundaries.md'))) { return 'boundaries.md всё-таки убран' }
        $dirty = @(& git -C $v3Base status --porcelain --untracked-files=all | Where-Object { $_ })
        if ($dirty.Count) { return "в базе осталось: $($dirty -join '; ')" }
        return $null
    }

    & git -C $v3Base rm -q -- people/other/autonomy.md
    & git -C $v3Base commit -qm 'рамки коллеги убраны' | Out-Null

    # Шаг 4 даёт рамки каждому оператору, шаг 6 переносит в личный репозиторий только свою папку:
    # рамки и флоу коллеги уехали бы к переводящему.
    Check 'перевод с формата 3 — рамки у каждого оператора, на папке коллеги перевод встаёт' {
        $r = Invoke-BaseMigrate $v1Migrate $v3Repo
        if ($r.code -eq 0) { return 'скрипт не отказал на папке коллеги' }
        if ($r.text -notmatch 'people\\other') { return "не названа папка коллеги: $($r.text)" }
        if ((Get-MarkerFormat $v3Base) -ne 5) { return "формат $(Get-MarkerFormat $v3Base), ожидался 5 — шаг 6 откачен, прежние сделаны" }
        if (Test-Path -LiteralPath (Join-Path $v3Base 'boundaries.md')) { return 'в корне базы остался boundaries.md' }
        if (-not (Test-Path -LiteralPath (Join-Path $v3Base 'team.md') -PathType Leaf)) { return 'в корне базы нет team.md' }
        foreach ($dir in (Get-PeopleDir $v3Base), $v3Other) {
            $autonomy = Join-Path $dir 'autonomy.md'
            if (-not (Test-Path -LiteralPath $autonomy) -or (Get-Content -LiteralPath $autonomy -Raw) -notmatch 'общая рамка формата 3') { return "нет прежних рамок в $autonomy" }
        }
        foreach ($r2 in $v3Base, (Get-MeDir $v3Base)) {
            $dirty = @(& git -C $r2 status --porcelain --untracked-files=all | Where-Object { $_ })
            if ($dirty.Count) { return "в $r2 осталось незакоммиченное: $($dirty -join '; ')" }
        }
        return $null
    }

    & git -C $v3Base rm -rq -- people/other
    & git -C $v3Base commit -qm 'папка коллеги убрана' | Out-Null

    Check 'перевод с формата 3 — без папки коллеги рамки и флоу в личном репозитории, флоу выложен' {
        $r = Invoke-BaseMigrate $v1Migrate $v3Repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-MarkerFormat $v3Base) -ne $kitFormat) { return "формат $(Get-MarkerFormat $v3Base), ожидался $kitFormat" }
        $autonomy = Join-Path (Get-OpDir $v3Base) 'autonomy.md'
        if (-not (Test-Path -LiteralPath $autonomy) -or (Get-Content -LiteralPath $autonomy -Raw) -notmatch 'общая рамка формата 3') { return "нет прежних рамок в $autonomy" }
        if (Test-Path -LiteralPath (Join-Path (Get-PeopleDir $v3Base) 'autonomy.md')) { return 'рамки остались в папке оператора' }
        foreach ($dir in (Get-OpDir $v3Base), (Get-PeopleDir $v3Base)) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir 'flow\scenarios.md') -PathType Leaf)) { return "нет флоу в $dir" }
        }
        foreach ($r2 in $v3Base, (Get-MeDir $v3Base)) {
            $dirty = @(& git -C $r2 status --porcelain --untracked-files=all | Where-Object { $_ })
            if ($dirty.Count) { return "в $r2 осталось незакоммиченное: $($dirty -join '; ')" }
        }
        $got = Invoke-Hook $v3Repo
        $fails = @($got -split "`n" | Where-Object { $_ -match '^- \*\*FAIL\*\*' })
        if ($fails.Count) { return "сверка после перевода красная: $($fails -join ' | ')" }
        return Test-HookText $got 'общая рамка формата 3', 'local/me/autonomy.md'
    }

    # Формат 4: tracker.md свободным текстом. Собирается из свежей базы.
    $v4Repo = Join-Path $root 'v4'
    $v4Base = Join-Path $root 'base-v4'
    New-TestRepo $v4Repo
    Invoke-BaseInit $v4Base | Out-Null
    & pwsh -NoProfile -File $link -Path $v4Repo -Base $v4Base | Out-Null
    Set-MarkerFormat $v4Base 4
    Set-Content -LiteralPath (Join-Path $v4Base 'tracker.md') -Encoding utf8 -Value '# Проект — трекер', '', 'Задачи в GitHub, ходим gh.'
    Commit-All $v4Base 'формат 4'

    Check 'перевод с формата 4 — прежний tracker.md удалён, вывод зовёт /tracker' {
        $before = Get-CommitCount $v4Base
        $r = Invoke-BaseMigrate $v1Migrate $v4Repo
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-MarkerFormat $v4Base) -ne $kitFormat) { return "формат $(Get-MarkerFormat $v4Base), ожидался $kitFormat" }
        if (Test-Path -LiteralPath (Join-Path $v4Base 'tracker.md')) { return 'tracker.md остался' }
        if ($r.text -notmatch '/tracker') { return "вывод не называет /tracker: $($r.text)" }
        if ((Get-CommitCount $v4Base) -ne $before + $kitFormat - 4) { return "коммитов прибавилось $((Get-CommitCount $v4Base) - $before), ожидалось $($kitFormat - 4)" }
        $dirty = @(& git -C $v4Base status --porcelain --untracked-files=all | Where-Object { $_ })
        if ($dirty.Count) { return "в базе осталось незакоммиченное: $($dirty -join '; ')" }
        $got = Invoke-Hook $v4Repo
        $fails = @($got -split "`n" | Where-Object { $_ -match '^- \*\*FAIL\*\*' })
        if ($fails.Count) { return "сверка после перевода красная: $($fails -join ' | ')" }
        return Test-HookText $got 'проект под китом'
    }

    # Флоу выкладывают и берут скриптом: агент работает по личному репозиторию, а папку в базе
    # может поправить любой, у кого есть push. Своя база — стенд коммитит в неё сам.
    $shareScript = Join-Path $scripts 'flow-share.ps1'
    $shareRepo = Join-Path $root 'share'
    $shareBase = Join-Path $root 'base-share'
    New-TestRepo $shareRepo
    Invoke-BaseInit $shareBase | Out-Null
    & pwsh -NoProfile -File $link -Path $shareRepo -Base $shareBase | Out-Null
    $shareMe = Get-MeDir $shareBase
    $sharePeople = Get-PeopleDir $shareBase
    New-Item -ItemType Directory -Force -Path (Join-Path $shareMe 'flow\stages'), (Join-Path $shareMe 'agents') | Out-Null
    Set-Content -LiteralPath (Join-Path $shareMe 'flow\scenarios.md') -Encoding utf8 -Value '# Проект — сценарии', '', '## свой', 'когда: разведка', '1. [Разведка](stages/scout.md)'
    Set-Content -LiteralPath (Join-Path $shareMe 'flow\stages\scout.md') -Encoding utf8 -Value '# Разведка', '', 'исполнитель: scout', 'выход: отчёт в памяти'
    Set-Content -LiteralPath (Join-Path $shareMe 'agents\scout.md') -Encoding utf8 -Value '---', 'name: scout', '---', '', 'разведать'
    Set-Content -LiteralPath (Join-Path $shareMe 'agents\private.md') -Encoding utf8 -Value '---', 'name: private', '---', '', 'личный'
    Set-Content -LiteralPath (Join-Path $shareMe 'autonomy.md') -Encoding utf8 -Value '# Рамки', '', 'своя рамка оператора'
    Commit-All $shareMe 'свой флоу'
    function Invoke-FlowShare([string[]]$ShareArgs) {
        $out = & pwsh -NoProfile -File $shareScript -Path $shareRepo @ShareArgs 2>&1
        return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
    }

    Check 'выложить флоу — сценарии, этапы и субагенты этапов в папке оператора, рамок нет, закоммичено' {
        $r = Invoke-FlowShare @('-Action', 'Publish')
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath (Join-Path $sharePeople 'flow\scenarios.md') -Raw) -notmatch '## свой') { return 'сценарий не выложен' }
        foreach ($f in 'flow\stages\scout.md', 'agents\scout.md') {
            if (-not (Test-Path -LiteralPath (Join-Path $sharePeople $f) -PathType Leaf)) { return "не выложен $f" }
        }
        foreach ($f in 'agents\private.md', 'autonomy.md') {
            if (Test-Path -LiteralPath (Join-Path $sharePeople $f)) { return "выложен $f — его не зовёт ни один этап или это рамки" }
        }
        $dirty = @(& git -C $shareBase status --porcelain --untracked-files=all | Where-Object { $_ })
        if ($dirty.Count) { return "в базе осталось незакоммиченное: $($dirty -join '; ')" }
        return $null
    }

    Check 'чужая правка папки оператора — подача и флоу оператора прежние, новое выкладывание её заменяет' {
        Set-Content -LiteralPath (Join-Path $sharePeople 'flow\scenarios.md') -Encoding utf8 -Value '# Проект — сценарии', '', '## подменённый', '1. [Разведка](stages/scout.md)'
        Set-Content -LiteralPath (Join-Path $sharePeople 'autonomy.md') -Encoding utf8 -Value '# Рамки', '', 'чужая рамка'
        Commit-All $shareBase 'чужая правка'
        $problem = ExpectText $shareRepo 'своя рамка оператора' -Lacks 'чужая рамка'
        if ($problem) { return $problem }
        if ((Get-Content -LiteralPath (Join-Path $shareMe 'flow\scenarios.md') -Raw) -notmatch '## свой') { return 'флоу оператора изменился' }
        $r = Invoke-FlowShare @('-Action', 'Publish')
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath (Join-Path $sharePeople 'flow\scenarios.md') -Raw) -notmatch '## свой') { return 'выложенное не вернулось к флоу оператора' }
        if (Test-Path -LiteralPath (Join-Path $sharePeople 'autonomy.md')) { return 'подложенные рамки остались в папке оператора' }
        return $null
    }

    # Коллега выложил своё: папка другого оператора в базе.
    $shareOther = Get-PeopleDir $shareBase 'x'
    New-Item -ItemType Directory -Force -Path (Join-Path $shareOther 'flow\stages'), (Join-Path $shareOther 'agents') | Out-Null
    Set-Content -LiteralPath (Join-Path $shareOther 'flow\scenarios.md') -Encoding utf8 -Value '# Проект — сценарии', '', 'Общий текст коллеги.', '', '## чужой', 'когда: проверка', '1. [Проверка](stages/check.md)'
    Set-Content -LiteralPath (Join-Path $shareOther 'flow\stages\check.md') -Encoding utf8 -Value '# Проверка', '', 'исполнитель: checker', 'выход: вердикт в памяти'
    Set-Content -LiteralPath (Join-Path $shareOther 'agents\checker.md') -Encoding utf8 -Value '---', 'name: checker', '---', '', 'проверить'
    Commit-All $shareBase 'коллега выложил флоу'

    Check 'взять флоу коллеги — его сценарий с этапами и субагентами в личном репозитории, свой сценарий цел' {
        $r = Invoke-FlowShare @('-Action', 'Take', '-From', 'x')
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        $text = Get-Content -LiteralPath (Join-Path $shareMe 'flow\scenarios.md') -Raw
        if ($text -notmatch '## свой' -or $text -notmatch '## чужой') { return "в сценариях не оба: $text" }
        if ($text -match 'Общий текст коллеги') { return 'общий текст коллеги лёг поверх своего флоу' }
        foreach ($f in 'flow\stages\check.md', 'agents\checker.md') {
            if (-not (Test-Path -LiteralPath (Join-Path $shareMe $f) -PathType Leaf)) { return "не взят $f" }
        }
        $dirty = @(& git -C $shareMe status --porcelain --untracked-files=all | Where-Object { $_ })
        if ($dirty.Count) { return "в личном репозитории осталось незакоммиченное: $($dirty -join '; ')" }
        return $null
    }

    Check 'взять снова, а у коллеги этап другой — без -Replace отказ и флоу не тронут, с -Replace заменён' {
        Set-Content -LiteralPath (Join-Path $shareOther 'flow\stages\check.md') -Encoding utf8 -Value '# Проверка', '', 'исполнитель: checker', 'выход: вердикт и sha в памяти'
        Commit-All $shareBase 'коллега поправил этап'
        $stage = Join-Path $shareMe 'flow\stages\check.md'
        $r = Invoke-FlowShare @('-Action', 'Take', '-From', 'x')
        if ($r.code -eq 0) { return 'скрипт не отказал' }
        if ($r.text -notmatch 'stages/check\.md' -or $r.text -notmatch 'заменится') { return "не названо, что заменится: $($r.text)" }
        if ((Get-Content -LiteralPath $stage -Raw) -match 'sha') { return 'этап заменён без -Replace' }
        $r = Invoke-FlowShare @('-Action', 'Take', '-From', 'x', '-Replace')
        if ($r.code -ne 0) { return "код возврата $($r.code): $($r.text)" }
        if ((Get-Content -LiteralPath $stage -Raw) -notmatch 'sha') { return 'этап не заменён с -Replace' }
        return $null
    }

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

    # Формат, который ждёт кит, — номер последнего шага: пропуск или повтор номера оставил бы
    # базу без перевода на этот формат.
    Check 'шаги перевода базы пронумерованы подряд с 002' {
        $names = @($kitFiles | Where-Object { $_ -like 'plugin/migrations/*' } | ForEach-Object { $_.Substring('plugin/migrations/'.Length) })
        $bad = @($names | Where-Object { $_ -notmatch '^\d{3}-[a-z0-9]+(-[a-z0-9]+)*\.ps1$' })
        if ($bad.Count) { return "не по форме NNN-<слаг>.ps1: $($bad -join ', ')" }
        $numbers = @($names | ForEach-Object { [int]$_.Substring(0, 3) } | Sort-Object)
        for ($i = 0; $i -lt $numbers.Count; $i++) {
            if ($numbers[$i] -ne $i + 2) { return "номера шагов $($numbers -join ', ') — ожидались подряд с 2" }
        }
        return $null
    }

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
        # Файл базы, которого нет в каркасе, назван в таблице «Куда именно» раскладки.
        $layout = Get-Content -LiteralPath (Join-Path $kit 'plugin\reference\base-layout.md') -Raw -Encoding utf8
        foreach ($m in [regex]::Matches($layout, '(?m)^\|\s*`([\p{L}\p{Nd}_.-]+\.md)`\s*\|')) { $names[$m.Groups[1].Value] = $true }
        $found = foreach ($entry in $kitText) {
            # Путь от корня репозитория, а в тексте внутри plugin — от plugin: так его видит
            # пользователь кита. .claude в plugin не лежит — его путь всегда от корня.
            # Файл или каталог должен найтись среди файлов кита.
            $from = if ($entry.file -like 'plugin/*') { 'plugin/' } else { '' }
            foreach ($m in [regex]::Matches($entry.text, '(?<![\p{L}\p{Nd}_./\\-])((?:plugin[/\\])?(?:\.claude[/\\](?:skills|agents)|hooks|reference|scripts|skills|template[/\\](?:base|operator|me))[/\\][\p{L}\p{Nd}_./\\-]*)')) {
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
