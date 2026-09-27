# agents-kit: завести базу знаний проекта и место оператора в ней на этой машине.
#   pwsh -NoProfile -File scripts\base-init.ps1 -Path <каталог базы> -Operator <имя оператора>
#        [-Name <имя проекта>] [-Prefix <буквы номеров бэклога>] [-Remote <адрес личного репозитория>]
#
# Общий каркас — template\base; папка оператора people\<имя>\ — template\operator; личный
# репозиторий local\me\ — template\me. Повторный прогон довозит недостающее и не трогает лежащее.
# Связывание основной копии с базой и список копий — link.ps1.
# Что лежит в базе и по каким правилам — reference\base-layout.md.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Operator,
    [string]$Name,
    [string]$Prefix,
    [string]$Remote
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# Путь приводится link-state.ps1, как и в link.ps1: напечатанный здесь путь копируют в него.
# Имя проекта для каркаса существующей базы — из её product.md, как его берёт хук.
. (Join-Path $PSScriptRoot 'base-check.ps1')

$templateRoot = ConvertTo-KitPath (Join-Path $PSScriptRoot '..\template')
foreach ($part in 'base', 'operator', 'me') {
    if (-not (Test-Path -LiteralPath (Join-Path $templateRoot $part) -PathType Container)) {
        throw "каталога шаблона «$templateRoot\$part» нет — клон кита неполон"
    }
}

$baseN = ConvertTo-KitPath $Path
if (Test-Path -LiteralPath $baseN -PathType Leaf) {
    throw "«$baseN» — файл, а не каталог"
}

# Без имени оператора база была бы без места для флоу, субагентов, памяти и бэклога: заводить
# полбазы, которую хук тут же остановит, незачем.
if (-not $Operator) { throw 'нужно имя оператора: -Operator <имя> — латиница в нижнем регистре, цифры и дефис между ними' }
if (-not (Test-KitOperatorName $Operator)) {
    throw "имя оператора «$Operator» не по форме — латиница в нижнем регистре, цифры и дефис между ними: b-ignatyev"
}

# Инвариант «В репозиторий проекта знание не пишется, и каталог знания в нём не создаётся»
# исполняется здесь, а не объясняется потом. Проверяется ближайший существующий
# родитель: самого каталога базы может ещё не быть.
#
# Собственный репозиторий базы под запрет не подпадает: его завёл прошлый прогон
# этого же скрипта, и повторный прогон обязан довозить файлы, а не отказывать.
$probe = $baseN
while ($probe -and -not (Test-Path -LiteralPath $probe -PathType Container)) {
    $probe = Split-Path $probe -Parent
}
if ($probe) {
    $inside = Invoke-KitGit $probe @('rev-parse', '--show-toplevel')
    if ($inside) {
        $insideN = ConvertTo-KitPath $inside
        if ($insideN -ine $baseN) {
            throw "«$baseN» лежит внутри репозитория «$insideN» — база знаний в репозиторий проекта не заводится"
        }
    }
}

# Имя одно на машину: другое поверх названного отказывает до первой записи.
$named = Get-KitOperatorName $baseN
if ($named -and $named -cne $Operator) {
    throw "на этой машине оператор базы уже назван «$named» — другое имя поверх него не пишется"
}

if (-not $Name) { $Name = Get-KitProjectName $baseN }
if (-not $Name) { $Name = Split-Path $baseN -Leaf }

$markerPath = Get-KitMarkerPath $baseN
$marker = Get-KitMarker $baseN
if (-not $marker -and (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "«$markerPath» существует, но не разбирается как agents-kit.json базы — разобраться должен оператор"
}
# Базу другого формата каркас текущего не довозит: перевод раскладывает её сам. Переводят
# из связанной копии — base-migrate.ps1 ищет базу по её указателю.
if ($marker -and [int]$marker.version -lt (Get-KitFormat)) {
    throw "база «$baseN» формата $($marker.version), а кит ждёт формат $(Get-KitFormat) — связать с ней копию link.ps1 и перевести из копии: base-migrate.ps1 -Path <копия> -Operator $Operator"
}
if ($marker -and [int]$marker.version -gt (Get-KitFormat)) {
    throw "базу «$baseN» перевёл на формат $($marker.version) кит новее этого, а этот знает формат до $(Get-KitFormat) — обновить кит"
}

# Буквы номеров бэклога называет проект и держит agents-kit.json: с ними заводится бэклог
# каждого оператора. Выбрать их за проект значило бы дать каждой базе одни и те же. Вид букв —
# reference\backlog-record.md, «Номер».
if ($Prefix) {
    if ($Prefix -notmatch '^[A-Za-z][A-Za-z0-9]{0,9}$') {
        throw "«$Prefix» не годится в буквы номеров бэклога: латиница и цифры, первый знак — буква, не больше 10 знаков"
    }
    $Prefix = $Prefix.ToUpperInvariant()
    if ($marker -and $marker.prefix -and $marker.prefix -cne $Prefix) {
        throw "у базы уже есть буквы номеров бэклога «$($marker.prefix)» — буквы у базы одни на всё время"
    }
}
elseif ($marker -and $marker.prefix) { $Prefix = [string]$marker.prefix }

$personal = Get-KitPersonalDir $baseN
$people = Get-KitOperatorDir $baseN $Operator

# Файлы каркаса с путём от корня своего шаблона: каркас держит и подкаталоги.
function Get-KitTemplateFiles([string]$Part, [string]$Target) {
    $dir = Join-Path $templateRoot $Part
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Force -Recurse)) {
        $rel = (ConvertTo-KitPath $file.FullName).Substring($dir.Length).TrimStart('\')
        [pscustomobject]@{ source = $file.FullName; name = $rel; target = (Join-Path $Target $rel) }
    }
}

# Чужую папку скрипт не угадывает: есть папка с этим именем — она этого оператора, так решил
# тот, кто назвал имя, и в неё скрипт не пишет.
$peopleTaken = Test-Path -LiteralPath $people -PathType Container
$plan = @(Get-KitTemplateFiles 'base' $baseN)
if (-not $peopleTaken) { $plan += @(Get-KitTemplateFiles 'operator' $people) }
$personalFresh = -not (Test-Path -LiteralPath $personal)
if (-not $personalFresh -and -not (Test-KitPersonalRepo $baseN)) {
    throw "«$personal» есть, но это не git-репозиторий — личный репозиторий заводится с нуля; разобраться должен оператор"
}

# Нехватка букв ловится до первой записи: отказ не оставляет полубазы. Файлы личного репозитория,
# склонированного из -Remote, известны только после клона — буквы для них проверяются там же.
if (-not $Prefix) {
    $needs = @($plan | Where-Object { -not (Test-Path -LiteralPath $_.target -PathType Leaf) -and (Get-Content -LiteralPath $_.source -Raw).Contains('<PREFIX>') })
    if ($personalFresh -and -not $Remote) { $needs += @(Get-KitTemplateFiles 'me' $personal | Where-Object { (Get-Content -LiteralPath $_.source -Raw).Contains('<PREFIX>') }) }
    if ($needs.Count) { throw "файлу каркаса «$($needs[0].name)» нужны буквы номеров бэклога — передать -Prefix <буквы>" }
}

if (-not (Test-Path -LiteralPath $baseN -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($baseN, 'создать каталог базы')) {
        New-Item -ItemType Directory -Force -Path $baseN | Out-Null
    }
    Write-Host "Каталог базы создан: $baseN"
}
else {
    Write-Host "Каталог базы уже существует: $baseN"
}

# Отсутствующий файл заводится, существующий не трогается никогда. Так повторный
# прогон довозит файл, появившийся в шаблоне позже, и не может съесть заполненный.
$script:added = 0
$script:kept = 0
function Write-KitTemplateFiles($Files, [string]$Root) {
    foreach ($file in $Files) {
        $label = (ConvertTo-KitPath $file.target).Substring($Root.Length).TrimStart('\')
        if (Test-Path -LiteralPath $file.target -PathType Leaf) {
            Write-Host "  уже есть, не тронут: $label"
            $script:kept++
            continue
        }
        $text = (Get-Content -LiteralPath $file.source -Raw).Replace('<PREFIX>', $Prefix).Replace('<PROJECT>', $Name)
        if ($PSCmdlet.ShouldProcess($file.target, 'записать файл каркаса')) {
            New-Item -ItemType Directory -Force -Path (Split-Path $file.target -Parent) | Out-Null
            Set-Content -LiteralPath $file.target -Value $text -Encoding utf8 -NoNewline
        }
        Write-Host "  заведён: $label"
        $script:added++
    }
}

# Первый коммит делается только в репозитории без коммитов: в чужую историю
# скрипт не пишет. Нет идентичности git — каркас всё равно на диске, ронять нечего.
function Save-KitFirstCommit([string]$Repo, [string]$Message, [string]$What) {
    $head = Invoke-KitGit $Repo @('rev-parse', '--verify', 'HEAD')
    if ($head -or -not $PSCmdlet.ShouldProcess($Repo, "первый коммит: $What")) { return }
    & git -C $Repo add -A 2>$null | Out-Null
    & git -C $Repo commit -qm $Message 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "Закоммичен $What" }
    else { Write-Host "Не закоммичен $What — вероятно, не задан user.name или user.email; закоммитить руками" -ForegroundColor Yellow }
}

$freshPeople = @($plan | Where-Object { $_.target.StartsWith($people + '\', [StringComparison]::OrdinalIgnoreCase) -and -not (Test-Path -LiteralPath $_.target -PathType Leaf) } | ForEach-Object { $_.target })
Write-KitTemplateFiles $plan $baseN
if ($peopleTaken) { Write-Host "  папка оператора уже есть, взята как есть: people\$Operator" }

if (-not $marker) {
    $marker = [pscustomobject][ordered]@{ kit = 'agents-kit'; version = (Get-KitFormat) }
    if ($Prefix) { $marker | Add-Member -NotePropertyName 'prefix' -NotePropertyValue $Prefix }
    if ($PSCmdlet.ShouldProcess($markerPath, 'завести agents-kit.json')) {
        $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8
    }
    Write-Host "  заведён: agents-kit.json"
}
elseif ($Prefix -and -not $marker.prefix) {
    # Пишется прочитанный файл с добавленным полем: прочие поля переживают правку.
    $marker | Add-Member -NotePropertyName 'prefix' -NotePropertyValue $Prefix -Force
    if ($PSCmdlet.ShouldProcess($markerPath, 'записать буквы бэклога')) {
        $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8
    }
    Write-Host "  записаны буквы бэклога в agents-kit.json"
}

if (-not (Test-Path -LiteralPath (Join-Path $baseN '.git') -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($baseN, 'git init')) {
        & git -C $baseN init -q
        if ($LASTEXITCODE -ne 0) { throw "не удалось завести git-репозиторий в «$baseN»" }
    }
    Write-Host "Заведён git-репозиторий базы"
}
$hadHistory = [bool](Invoke-KitGit $baseN @('rev-parse', '--verify', 'HEAD'))
Save-KitFirstCommit $baseN 'agents-kit: каркас базы знаний' 'каркас базы'

# Папка нового оператора в базе с историей коммитится сразу и только своими файлами: имя занято
# тем, что папку видят коллеги, а незакоммиченная она для них пуста.
if ($hadHistory -and $freshPeople.Count -and $PSCmdlet.ShouldProcess($people, 'закоммитить папку оператора')) {
    & git -C $baseN add -- @freshPeople 2>$null | Out-Null
    & git -C $baseN commit -qm "agents-kit: папка оператора $Operator" -- @freshPeople 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "Закоммичена папка оператора: people\$Operator" }
    else { Write-Host "Папка оператора не закоммичена — закоммитить руками: people\$Operator" -ForegroundColor Yellow }
}

if ($PSCmdlet.ShouldProcess((Get-KitWorkspacesPath $baseN), "имя оператора $Operator")) {
    Set-KitOperatorName $baseN $Operator
}
Write-Host "Оператор этой машины: $Operator"

# Личный репозиторий: с приватным remote он ходит между машинами одного оператора, и тогда
# заводится клоном — иначе у двух машин были бы две несвязанные истории одной памяти и бэклога.
if ($personalFresh) {
    if ($Remote) {
        if ($PSCmdlet.ShouldProcess($personal, "git clone $Remote")) {
            New-Item -ItemType Directory -Force -Path (Split-Path $personal -Parent) | Out-Null
            & git clone -q -- $Remote $personal 2>$null
            if ($LASTEXITCODE -ne 0) { throw "не удалось склонировать личный репозиторий из «$Remote»" }
        }
        Write-Host "Личный репозиторий склонирован из $Remote"
    }
    else {
        if ($PSCmdlet.ShouldProcess($personal, 'git init')) {
            New-Item -ItemType Directory -Force -Path $personal | Out-Null
            & git -C $personal init -q
            if ($LASTEXITCODE -ne 0) { throw "не удалось завести личный репозиторий в «$personal»" }
        }
        Write-Host "Заведён личный репозиторий: $personal"
    }
}
elseif ($Remote) {
    Write-Host "Личный репозиторий уже есть — -Remote не применён: $personal" -ForegroundColor Yellow
}

$personalFiles = @(Get-KitTemplateFiles 'me' $personal)
if (-not $Prefix) {
    $needs = @($personalFiles | Where-Object { -not (Test-Path -LiteralPath $_.target -PathType Leaf) -and (Get-Content -LiteralPath $_.source -Raw).Contains('<PREFIX>') })
    if ($needs.Count) { throw "файлу личного репозитория «$($needs[0].name)» нужны буквы номеров бэклога — передать -Prefix <буквы>" }
}
Write-KitTemplateFiles $personalFiles $baseN
Save-KitFirstCommit $personal 'agents-kit: каркас личного репозитория' 'каркас личного репозитория'

Write-Host ''
Write-Host "Заведено файлов: $script:added, оставлено нетронутыми: $script:kept"
if ($Prefix) { Write-Host "Бэклог нумеруется буквами $Prefix" }
Write-Host "Дальше — связать основную копию, из её каталога:"
Write-Host "  pwsh -NoProfile -File `"$(Join-Path $PSScriptRoot 'link.ps1')`" -Base `"$baseN`""
