# agents-kit: что в базе знаний не так. Дот-сорсится хуками. Здесь же чтение файла базы,
# каким его видит сессия, список подаваемых, оглавление решений и разбор вопросов оператору:
# иначе подача и потолок считали бы разный текст. Потолки и перечни ключей читаются
# из справок reference\.
#
# Находка — { severity; file; message; kind }: FAIL — база разошлась с правилами,
# WARN — перечитать и решить, kind = secret — подозрение на секрет для оператора.
#
#   Get-KitBaseFindings    база целиком — то, что расходится само, без коммита
#   Get-KitCommitFindings  файлы коммита, local/ и бэклог — то, что уедет в историю

. (Join-Path $PSScriptRoot 'link-state.ps1')

# Подаваемые содержимым файлы; только у них потолок цены подачи. Названы поимённо, а не корень
# базы: подача корня везла бы в каждую сессию любой положенный туда .md.
$script:KitServedFiles = @('product.md', 'boundaries.md')
$script:KitDecisionsDir = 'decisions'

function New-KitFinding([string]$Severity, [string]$File, [string]$Message, [string]$Kind = '') {
    return [pscustomobject]@{ severity = $Severity; file = $File; message = $Message; kind = $Kind }
}

# Файл базы, как его видит сессия: этот текст берут и подача, и потолок. Комментарии
# вырезаются — пример из шаблона иначе приехал бы фактом проекта. Читается он и с диска,
# и из истории базы, поэтому разбор отделён от чтения: иначе прошлая версия памяти
# сверялась бы не с тем текстом, который видела сессия. Нечитаемый файл — пустая строка,
# а не исключение: иначе хук оставил бы сессию без всей базы.
function ConvertTo-KitMarkdown([string]$Text) {
    if (-not $Text) { return '' }
    $Text = [regex]::Replace($Text, '(?s)<!--.*?-->', '')
    return ([regex]::Replace($Text, '(\r?\n[ \t]*){3,}', "`n`n")).Trim()
}

function Read-KitMarkdown([string]$Path) {
    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return '' }
    return ConvertTo-KitMarkdown $text
}

# Имя проекта для шапки подачи; где оно живёт — reference\base-layout.md. Хвост
# « — продукт» из каркаса именем не считается. Заголовка нет — имени нет, а не имя папки.
function Get-KitProjectName([string]$Base) {
    $text = Read-KitMarkdown (Join-Path $Base 'product.md')
    $m = [regex]::Match($text, '(?m)^#\s+(.+?)(?:\s+—\s+продукт)?\s*$')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Get-KitServedLines([string]$Path) {
    return @((Read-KitMarkdown $Path) -split '\r?\n' | Where-Object { $_.Trim() })
}

# Строка «когда:» файла решений — то, по чему сессия выбирает его, не открыв.
function Get-KitDecisionReadWhen([string]$Text) {
    $m = [regex]::Match($Text, '(?im)^\s*когда\s*:\s*(.+?)\s*$')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

# Оглавление решений: и подача хука, и сверка берут его отсюда. Строка «когда:» живёт в самом
# файле, а не в индексе: второй список разошёлся бы с каталогом. Файл без неё в оглавление
# не попадает — его называет сверка.
function Get-KitDecisionIndex([string]$Base) {
    $dir = Join-Path $Base $script:KitDecisionsDir
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $when = Get-KitDecisionReadWhen (Read-KitMarkdown $file.FullName)
        if (-not $when) { continue }
        [pscustomobject]@{ file = "$($script:KitDecisionsDir)/$($file.Name)"; when = $when }
    }
}

# Рабочая копия, которую объявляет файл памяти; опознание — по ней, не по имени файла.
function Get-KitDeclaredWorktree([string]$Text) {
    $m = [regex]::Match($Text, '(?im)^\s*рабочая\s+копия\s*:\s*(.+?)\s*$')
    if (-not $m.Success) { return $null }
    return ConvertTo-KitPath $m.Groups[1].Value
}

# Раздел справки кита — от заголовка до следующего заголовка того же уровня или выше.
# Заголовок внутри блока кода разделом не считается: пример стадии флоу начинается с «##».
function Get-KitLayoutSection([string]$Text, [string]$Heading) {
    $level = $Heading.IndexOf(' ')
    $lines = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    $fence = $false
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^```') { $fence = -not $fence }
        if (-not $fence -and $line -match '^(#+)\s') {
            if ($line.TrimEnd() -eq $Heading) { $inside = $true; continue }
            if ($inside -and $Matches[1].Length -le $level) { break }
        }
        if ($inside) { $lines.Add($line) }
    }
    return ($lines -join "`n")
}

function Get-KitKeyRows([string]$Text) {
    return [regex]::Matches($Text, '(?m)^\|\s*`([^`]+)`\s*\|\s*(.*?)\s*\|\s*(да|нет)\s*\|\s*$')
}

# Вопросы оператору: подразделы «###» раздела «## Оператору». Проза до первой строки ключа —
# контекст; строка ключа — «- ключ: значение» или «ответ: значение». Отвеченным вопрос
# считается по непустому ответу где угодно в блоке: форму называет сверка, а ожидание
# отпускает сессию и на вопросе не по форме.
#
# Вопрос — { text; context; lines — { key; value; raw }, key пуст у прозы; answered }.
function Get-KitOperatorQuestions([string]$Text) {
    $questions = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $inside = $false
    foreach ($line in ($Text -split '\r?\n')) {
        $section = [regex]::Match($line, '^##\s+(.+?)\s*$')
        if ($section.Success) { $inside = ($section.Groups[1].Value -eq 'Оператору'); $current = $null; continue }
        if (-not $inside) { continue }
        $question = [regex]::Match($line, '^###\s+(.*?)\s*$')
        if ($question.Success) {
            $current = [pscustomobject]@{
                text = $question.Groups[1].Value; answered = $false
                context = [System.Collections.Generic.List[string]]::new()
                lines = [System.Collections.Generic.List[object]]::new()
            }
            $questions.Add($current)
            continue
        }
        if (-not $current -or -not $line.Trim()) { continue }
        $pair = [regex]::Match($line, '^\s*-\s*([^:]+?)\s*:\s*(.*?)\s*$')
        if (-not $pair.Success) { $pair = [regex]::Match($line, '^\s*(ответ)\s*:\s*(.*?)\s*$') }
        if (-not $pair.Success -and -not $current.lines.Count) { $current.context.Add($line.Trim()); continue }
        $key = if ($pair.Success) { $pair.Groups[1].Value } else { '' }
        $value = if ($pair.Success) { $pair.Groups[2].Value } else { $line.Trim() }
        $current.lines.Add([pscustomobject]@{ key = $key; value = $value; raw = $line })
        if ($key -eq 'ответ' -and $value) { $current.answered = $true }
    }
    return $questions
}

function Read-KitReference([string]$Name) {
    $path = Join-Path $PSScriptRoot "..\reference\$Name"
    try { return Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { return '' }
}

# Потолки и ключи из справок кита. Несошедшийся разбор не молчит: файл без разобранного
# правила даёт FAIL, а не проходит непроверенным.
function Get-KitLayoutRules {
    $result = @{ files = @{}; memory = $null; decision = $null; flowKeys = [ordered]@{}; executors = @(); questionKeys = [ordered]@{}; backlogFields = [ordered]@{} }

    # Таблица ключей — единственная в своём разделе с колонкой «да/нет».
    $memoryText = Read-KitReference 'task-memory.md'
    foreach ($row in Get-KitKeyRows (Get-KitLayoutSection $memoryText '## Вопрос оператору и ответ')) {
        $result.questionKeys[$row.Groups[1].Value] = ($row.Groups[3].Value -eq 'да')
    }
    $memory = [regex]::Match($memoryText, '(?m)^Потолок файла — (\d+) строк\.')
    if ($memory.Success) { $result.memory = [int]$memory.Groups[1].Value }

    $backlogText = Get-KitLayoutSection (Read-KitReference 'backlog-record.md') '## Поля'
    foreach ($row in [regex]::Matches($backlogText, '(?m)^\|\s*`([^`]+)`\s*\|\s*(.*?)\s*\|\s*$')) {
        $result.backlogFields[$row.Groups[1].Value] = @([regex]::Matches($row.Groups[2].Value, '`([^`<>]+)`') | ForEach-Object { $_.Groups[1].Value })
    }

    $text = Read-KitReference 'base-layout.md'
    $flowText = Get-KitLayoutSection $text '## Флоу проекта'
    foreach ($row in Get-KitKeyRows $flowText) {
        $key = $row.Groups[1].Value
        $result.flowKeys[$key] = ($row.Groups[3].Value -eq 'да')
        if ($key -eq 'исполнитель') {
            $result.executors = @([regex]::Matches($row.Groups[2].Value, '`([^`<>]+)`') | ForEach-Object { $_.Groups[1].Value })
        }
    }

    foreach ($row in [regex]::Matches($text, '(?m)^\|\s*`([^`]+\.md)`\s*\|.*\|\s*([^|]*?)\s*\|\s*$')) {
        $cell = [regex]::Match($row.Groups[2].Value, '^(\d+) строк$')
        if (-not $cell.Success) { continue }
        $result.files[$row.Groups[1].Value.ToLowerInvariant()] = [int]$cell.Groups[1].Value
    }

    $decision = [regex]::Match($text, '(?m)^Потолок файла решений — (\d+) строк\.')
    if ($decision.Success) { $result.decision = [int]$decision.Groups[1].Value }
    return $result
}

# Известные файлы корня берутся из каркаса, а не перечисляются здесь: новый файл
# шаблона становится известным сверке без её правки.
function Get-KitTemplateNames {
    $template = Join-Path $PSScriptRoot '..\template\base'
    try { return @(Get-ChildItem -LiteralPath $template -File -Force -ErrorAction Stop | ForEach-Object { $_.Name }) }
    catch { return @() }
}

function Get-KitRelativePath([string]$Base, [string]$Path) {
    return $Path.Substring($Base.Length).TrimStart('\')
}

# Секрет, попавший в историю базы, переживает удаление файла, поэтому ищется и по
# содержимому. Это догадка, а не факт, — отсюда WARN. Значение в находку не попадает:
# иначе сверка сама разнесла бы секрет по контексту сессии.
$script:KitSecretPatterns = @(
    '(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|token)\s*[:=]\s*["'']?[A-Za-z0-9+/_.!@#$%^&*\-]{6,}'
    '(?i)\b[a-z][a-z0-9+.\-]*://[^\s/:@]+:[^\s/@]+@'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}'
    '\bgithub_pat_[A-Za-z0-9_]{30,}'
    '\bsk-[A-Za-z0-9_\-]{20,}'
    '\bAKIA[0-9A-Z]{16}\b'
    '\bxox[abprs]-[A-Za-z0-9\-]{10,}'
    '\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}'
    '(?i)AccountKey=[A-Za-z0-9+/=]{20,}'
)

function Find-KitSecrets([string]$Path, [string]$Label) {
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { return }
    $lines = [System.Text.Encoding]::UTF8.GetString($bytes) -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($pattern in $script:KitSecretPatterns) {
            if ($lines[$i] -match $pattern) {
                New-KitFinding 'WARN' "${Label}:$($i + 1)" 'похоже на секрет — инвариант «Секреты не попадают в git базы»' 'secret'
                break
            }
        }
    }
}

# Сторона базы у связи. Хук проверяет связь от копии; висящую запись в списке оттуда
# не видно — копии, от которой смотреть, больше нет.
function Get-KitLinkFindings([string]$Base) {
    $marker = Get-KitMarker $Base
    if (-not $marker) {
        New-KitFinding 'FAIL' 'agents-kit.json' 'списка копий нет или он не читается — это не база кита'
        return
    }
    $list = @($marker.workspaces | Where-Object { $_ } | ForEach-Object { ConvertTo-KitPath $_ })
    if (-not $list.Count) {
        New-KitFinding 'FAIL' 'agents-kit.json' 'база не числит ни одной основной копии — связывает link.ps1'
        return
    }

    $seen = @{}
    foreach ($ws in $list) {
        $key = $ws.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { New-KitFinding 'FAIL' 'agents-kit.json' "копия «$ws» числится дважды"; continue }
        $seen[$key] = $true

        if (-not (Test-Path -LiteralPath $ws -PathType Container)) {
            New-KitFinding 'FAIL' 'agents-kit.json' "копии «$ws» нет на диске — запись висит: вернуть копию или убрать запись"
            continue
        }
        if ($Base -ieq $ws -or $Base.StartsWith($ws + '\', [StringComparison]::OrdinalIgnoreCase)) {
            New-KitFinding 'FAIL' '.' "база лежит внутри основной копии «$ws» — знание в репозиторий проекта не пишется"
        }

        $state = Get-KitLinkState $ws
        if ($state.status -eq 'NotGit') {
            New-KitFinding 'FAIL' 'agents-kit.json' "«$ws» не git-репозиторий — запись висит"
        }
        elseif ($state.workspace -ine $ws) {
            New-KitFinding 'FAIL' 'agents-kit.json' "«$ws» — не основная копия, а часть «$($state.workspace)»: в список идёт каталог, для которого записан указатель, и worktree в него не пишется"
        }
        elseif ($state.status -eq 'NoPointer') {
            New-KitFinding 'FAIL' 'agents-kit.json' "у копии «$ws» указатель снят — запись висит: связать заново link.ps1 или убрать запись"
        }
        elseif ($state.base -ine $Base) {
            New-KitFinding 'FAIL' 'agents-kit.json' "копия «$ws» указывает на другую базу «$($state.base)» — запись висит"
        }
    }
}

function Get-KitGitFindings([string]$Base) {
    $top = Invoke-KitGit $Base @('rev-parse', '--show-toplevel')
    if (-not $top) {
        New-KitFinding 'FAIL' '.' 'база не под git'
        return
    }
    if ((ConvertTo-KitPath $top) -ine $Base) {
        New-KitFinding 'FAIL' '.' "база лежит внутри репозитория «$(ConvertTo-KitPath $top)»"
        return
    }

    & git -C $Base check-ignore -q 'local/' 2>$null
    if ($LASTEXITCODE -ne 0) {
        New-KitFinding 'FAIL' '.gitignore' 'local/ не игнорируется — нужна строка «local/» в .gitignore'
    }
    $tracked = @(& git -C $Base ls-files -- 'local' 2>$null | Where-Object { $_ })
    if ($tracked.Count) {
        New-KitFinding 'FAIL' $tracked[0] "файлов из local/ под версией: $($tracked.Count) — секрет уже в истории: ротировать утёкшее"
    }
}

function Get-KitKnowledgeCeilingFindings([string]$Path, [string]$Label, $Ceilings) {
    $ceiling = $Ceilings.files[$Label.ToLowerInvariant()]
    if (-not $ceiling) {
        New-KitFinding 'FAIL' $Label 'потолок не разобран — в таблице «Куда именно» раскладки нет ячейки вида «N строк» для этого файла'
        return
    }

    $count = (Get-KitServedLines $Path).Count
    if ($count -gt $ceiling) {
        New-KitFinding 'FAIL' $Label "$count строк при потолке $ceiling — перечитать по тесту входа, а не поднимать потолок"
    }
}

# Поля записи объявлены строкой «поля:» шапки; без неё запись их не несёт. Ключом считается
# только имя из перечня справки: текст оператору тоже начинается со слова и двоеточия, и всякая
# пара «слово: слово» ушла бы в находки. Своё имя в «поля:», пустое значение и значение вне
# перечня — FAIL; нехватку объявленного поля проставит показ бэклога, невключённое поле решает
# оператор — WARN.
function Get-KitBacklogFieldFindings([string]$Label, [string]$Head, $Entries, $Rules) {
    $declared = [regex]::Match($Head, '(?im)^\s*поля\s*:\s*(.+?)\s*$')
    if ($declared.Success -and -not $Rules.backlogFields.Count) {
        New-KitFinding 'FAIL' $Label 'перечень полей записи не разобран — таблица в разделе «Поля» правил записи бэклога'
        return
    }

    $fields = @()
    if ($declared.Success) {
        foreach ($name in ($declared.Groups[1].Value -split ',')) {
            $name = $name.Trim()
            if (-not $name) { continue }
            if ($Rules.backlogFields.Contains($name)) { $fields += $name; continue }
            New-KitFinding 'FAIL' $Label "«поля:» называет «$name» — такого поля нет, своих не заводят"
        }
    }

    foreach ($entry in $Entries) {
        foreach ($name in $fields) {
            if (-not $entry.keys.Contains($name)) {
                New-KitFinding 'WARN' $Label "$($entry.label): нет поля «$name» — проставит /backlog"
                continue
            }
            $value = $entry.keys[$name]
            if (-not $value) {
                New-KitFinding 'FAIL' $Label "$($entry.label): поле «$name» пусто"
                continue
            }
            if ($Rules.backlogFields[$name] -notcontains $value) {
                New-KitFinding 'FAIL' $Label "$($entry.label): «$name : $value» вне перечня — $($Rules.backlogFields[$name] -join ' · ')"
            }
        }
        foreach ($key in $entry.keys.Keys) {
            if ($fields -notcontains $key) {
                New-KitFinding 'WARN' $Label "$($entry.label): поле «$key» не объявлено строкой «поля:» шапки"
            }
        }
    }
}

# Номер записи бэклога выдаёт счётчик в шапке файла: из оставшихся записей номер не вычислить,
# по истории git тоже — она не видит незакоммиченных записей соседней копии. Запись — заголовок
# «##», под ним подряд пары «ключ: значение». Повтор номера и счётчик не выше наибольшего — FAIL;
# запись без номера и файл без счётчика чинит /backlog — WARN.
function Get-KitBacklogFindings([string]$Path, [string]$Label, $Rules) {
    $text = Read-KitMarkdown $Path
    $numbers = @{}
    $unnumbered = 0
    $entries = @()
    $head = [System.Collections.Generic.List[string]]::new()
    $current = $null
    $inKeys = $false
    foreach ($line in ($text -split '\r?\n')) {
        if ($line -match '^##\s') {
            $m = [regex]::Match($line, '^##\s+B-(\d+)\b')
            if ($m.Success) {
                $n = [int]$m.Groups[1].Value
                $numbers[$n] = 1 + [int]$numbers[$n]
                $current = @{ label = "B-$n"; keys = [ordered]@{} }
            }
            else {
                $unnumbered++
                $current = @{ label = ($line -replace '^#+\s*', ''); keys = [ordered]@{} }
            }
            $entries += $current
            $inKeys = $true
            continue
        }
        if (-not $current) { $head.Add($line); continue }
        if (-not $inKeys) { continue }
        if (-not $line.Trim()) {
            if ($current.keys.Count) { $inKeys = $false }
            continue
        }
        $pair = [regex]::Match($line, '^([^\s:][^:]*?)\s*:\s*(.*?)\s*$')
        if ($pair.Success -and $Rules.backlogFields.Contains($pair.Groups[1].Value)) {
            $current.keys[$pair.Groups[1].Value] = $pair.Groups[2].Value
            continue
        }
        $inKeys = $false
    }

    foreach ($n in @($numbers.Keys | Where-Object { $numbers[$_] -gt 1 } | Sort-Object)) {
        New-KitFinding 'FAIL' $Label "номер B-$n у $($numbers[$n]) записей — одной из записей выдать новый через счётчик"
    }
    if ($unnumbered) {
        New-KitFinding 'WARN' $Label "$unnumbered записей без номера — пронумерует /backlog"
    }

    $counter = [regex]::Match($text, '(?im)^\s*следующий\s+номер\s*:\s*B-(\d+)\s*$')
    if (-not $counter.Success) {
        New-KitFinding 'WARN' $Label 'нет строки «следующий номер: B-N» — поставит /backlog'
    }
    else {
        $next = [int]$counter.Groups[1].Value
        $max = @($numbers.Keys | Sort-Object -Descending | Select-Object -First 1)
        if ($max.Count -and $next -le $max[0]) {
            New-KitFinding 'FAIL' $Label "следующий номер B-$next не выше наибольшего B-$($max[0]) — поднять счётчик за наибольший"
        }
    }

    Get-KitBacklogFieldFindings $Label ($head -join "`n") $entries $Rules
}

# Файлы корня: каркас на месте, подаваемые в потолке, бэклог сходится со счётчиком и перечнем полей.
# О файлах сверх каркаса сверка молчит.
function Get-KitRootFindings([string]$Base, $Ceilings) {
    foreach ($name in Get-KitTemplateNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $Base $name) -PathType Leaf)) {
            New-KitFinding 'WARN' $name 'файла из каркаса нет — довезёт повторный base-init.ps1'
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Base -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.md' })) {
        if ($script:KitServedFiles -contains $file.Name) {
            Get-KitKnowledgeCeilingFindings $file.FullName $file.Name $Ceilings
        }
        elseif ($file.Name -ieq 'backlog.md') { Get-KitBacklogFindings $file.FullName $file.Name $Ceilings }
    }
}

function Get-KitDecisionFileFindings([string]$Path, [string]$Label, $Rules) {
    $text = Read-KitMarkdown $Path
    if (-not (Get-KitDecisionReadWhen $text)) {
        New-KitFinding 'FAIL' $Label 'нет строки «когда:»'
    }
    if (-not $Rules.decision) {
        New-KitFinding 'FAIL' $Label 'потолок не разобран — в раскладке нет строки «Потолок файла решений — N строк.»'
        return
    }
    $count = (Get-KitServedLines $Path).Count
    if ($count -gt $Rules.decision) {
        New-KitFinding 'FAIL' $Label "$count строк при потолке $($Rules.decision) — в файле две области, резать на два"
    }
}

function Get-KitDecisionFindings([string]$Base, $Rules) {
    $dir = Join-Path $Base $script:KitDecisionsDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        $label = Get-KitRelativePath $Base (ConvertTo-KitPath $item.FullName)
        if ($item.PSIsContainer) { New-KitFinding 'WARN' $label "подкаталог в $($script:KitDecisionsDir)/ — решения лежат плоско, файлом на область"; continue }
        if ($item.Extension -ine '.md') { New-KitFinding 'WARN' $label "не .md в $($script:KitDecisionsDir)/ — каталог держит только файлы решений"; continue }
        Get-KitDecisionFileFindings (ConvertTo-KitPath $item.FullName) $label $Rules
    }
}

# Форма вопроса оператору — FAIL: отвечают часто без спросившей
# сессии, и ответ по вопросу не по форме не на что опереть. Перечень в заголовке и ссылки на
# соседние строки ловятся только по словам — WARN.
function Get-KitQuestionFindings([string]$Text, [string]$Label, $Rules) {
    $questions = @(Get-KitOperatorQuestions $Text)
    if (-not $questions.Count) { return }
    if (-not $Rules.questionKeys.Count) {
        New-KitFinding 'FAIL' $Label 'перечень ключей вопроса не разобран — таблица в разделе «Вопрос оператору и ответ» task-memory.md кита'
        return
    }

    # Контекст — абзацы под заголовком, из перечня он берёт только обязательность.
    $contextKey = 'контекст'
    foreach ($q in $questions) {
        $head = $q.text
        $short = if ($head.Length -gt 60) { $head.Substring(0, 60) + '…' } else { $head }
        $at = "вопрос «$short»"
        if ($Rules.questionKeys[$contextKey] -and -not $q.context.Count) {
            New-KitFinding 'FAIL' $Label "${at}: нет контекста — абзацы сразу под заголовком"
        }
        foreach ($l in $q.lines) {
            if (-not $l.key) { New-KitFinding 'FAIL' $Label "${at}: строка «$($l.value)» после строк ключей — контекст пишется абзацами сразу под заголовком" }
            elseif ($l.key -eq $contextKey) { New-KitFinding 'FAIL' $Label "${at}: «${contextKey}:» не ключ — контекст пишется абзацами сразу под заголовком" }
            elseif (-not $Rules.questionKeys.Contains($l.key)) { New-KitFinding 'FAIL' $Label "${at}: ключ «$($l.key)» вне перечня — своих ключей не заводят" }
        }
        foreach ($key in $Rules.questionKeys.Keys) {
            if ($key -eq $contextKey -or -not $Rules.questionKeys[$key]) { continue }
            if (-not @($q.lines | Where-Object { $_.key -eq $key }).Count) {
                $hint = if ($key -eq 'ответ') { 'сессия пишет её сразу, пустой, последней строкой блока' } else { 'она обязательна в блоке вопроса' }
                New-KitFinding 'FAIL' $Label "${at}: нет строки «${key}:» — $hint"
            }
        }
        $options = @($q.lines | Where-Object { $_.key -eq 'вариант' } | ForEach-Object { $_.value })
        if ($options.Count -eq 1) {
            New-KitFinding 'FAIL' $Label "${at}: один «вариант:» — вариантов два и больше или ни одного"
        }
        if (@($options | Group-Object -CaseSensitive | Where-Object { $_.Count -gt 1 }).Count) {
            New-KitFinding 'FAIL' $Label "${at}: одинаковые «вариант:»"
        }
        # Рекомендация — точное совпадение с вариантом: варианты часто разнятся парой слов.
        $recommended = @($q.lines | Where-Object { $_.key -eq 'рекомендовано' })
        if ($recommended.Count -gt 1) { New-KitFinding 'FAIL' $Label "${at}: «рекомендовано:» больше одной" }
        elseif ($recommended.Count -and -not $options.Count) { New-KitFinding 'FAIL' $Label "${at}: «рекомендовано:» без вариантов" }
        elseif ($recommended.Count -and -not ($options -ccontains $recommended[0].value)) {
            New-KitFinding 'FAIL' $Label "${at}: «рекомендовано:» не вариант слово в слово — скопировать строку варианта целиком"
        }
        $answers = @($q.lines | Where-Object { $_.key -eq 'ответ' })
        if ($answers.Count -gt 1) { New-KitFinding 'FAIL' $Label "${at}: ответов больше одного" }
        elseif ($answers.Count -and $q.lines[$q.lines.Count - 1].key -ne 'ответ') {
            New-KitFinding 'FAIL' $Label "${at}: «ответ:» не последней строкой блока"
        }
        if ($head -match '\([а-яa-z0-9]\)|(^|\s)\d\)') {
            New-KitFinding 'WARN' $Label "${at}: похоже на перечень в заголовке — одно решение на вопрос, остальные — своими подразделами"
        }
        $body = (@($head) + @($q.context) + @($q.lines | Where-Object { $_.key -ne 'ответ' } | ForEach-Object { $_.value })) -join ' '
        if ($body -match '(?i)(?<![\p{L}])(выше|ниже)(?![\p{L}])') {
            New-KitFinding 'WARN' $Label "${at}: ссылка «выше» или «ниже» — нужное переписать в контекст"
        }
    }
}

# Разделы памяти и связь двух её частей. Строка агенту без своего критерия или вопроса —
# не ошибка формы, а повод перечитать: WARN.
function Get-KitMemoryLayoutFindings([string]$Text, [string]$Label) {
    foreach ($section in 'Критерии закрытия', 'Оператору', 'Агенту') {
        if ($Text -notmatch "(?m)^##\s+$([regex]::Escape($section))\s*$") {
            New-KitFinding 'WARN' $Label "нет раздела «## $section» из шаблона памяти"
        }
    }
    $agent = Get-KitLayoutSection $Text '## Агенту'
    foreach ($sub in 'Критерии', 'Вопросы', 'Факты', 'Флоу', 'Шаги') {
        if ($agent -notmatch "(?m)^###\s+$([regex]::Escape($sub))\s*$") {
            New-KitFinding 'WARN' $Label "нет подраздела «### $sub» в «Агенту» из шаблона памяти"
        }
    }

    $criteria = @([regex]::Matches((Get-KitLayoutSection $Text '## Критерии закрытия'), '(?m)^###\s+(\d+)\.') | ForEach-Object { $_.Groups[1].Value })
    foreach ($m in [regex]::Matches((Get-KitLayoutSection $agent '### Критерии'), '(?m)^\s*-\s+(\d+)\.')) {
        if ($criteria -notcontains $m.Groups[1].Value) {
            New-KitFinding 'WARN' $Label "«Агенту → Критерии»: строка $($m.Groups[1].Value). без критерия с этим номером — номер строки повторяет заголовок «### N.» критерия"
        }
    }
    $questions = @(Get-KitOperatorQuestions $Text | ForEach-Object { $_.text })
    foreach ($m in [regex]::Matches((Get-KitLayoutSection $agent '### Вопросы'), '(?m)^\s*-\s+«(.+?)»\s*:')) {
        if ($questions -cnotcontains $m.Groups[1].Value) {
            $short = $m.Groups[1].Value
            if ($short.Length -gt 60) { $short = $short.Substring(0, 60) + '…' }
            New-KitFinding 'WARN' $Label "«Агенту → Вопросы»: «$short» — такого вопроса в «Оператору» нет; заголовок вопроса повторяется слово в слово, отвеченный вопрос уходит вместе со строкой"
        }
    }
}

# Опознание своей памяти на старте называет подача session-start.ps1 (-SkipIdentity);
# в коммите его назвать больше некому.
function Get-KitOwnMemoryFindings([string]$Path, [string]$Label, [string]$Worktree, $Ceilings, [switch]$SkipIdentity) {
    $text = Read-KitMarkdown $Path
    $declared = Get-KitDeclaredWorktree $text
    if ($declared -and $declared -ine $Worktree) {
        if (-not $SkipIdentity) {
            New-KitFinding 'FAIL' $Label "объявляет рабочую копию «$declared», а лежит по адресу «$Worktree» — не своя, решает оператор"
        }
        return
    }
    if (-not $declared -and -not $SkipIdentity) {
        New-KitFinding 'FAIL' $Label "нет строки «рабочая копия: $Worktree»"
    }

    foreach ($field in 'ветка', 'Решения') {
        if ($text -notmatch "(?m)^$([regex]::Escape($field))\s*:") {
            New-KitFinding 'WARN' $Label "нет строки «${field}:» из шаблона памяти"
        }
    }
    Get-KitMemoryLayoutFindings $text $Label

    Get-KitQuestionFindings $text $Label $Ceilings

    if (-not $Ceilings.memory) {
        New-KitFinding 'FAIL' $Label 'потолок памяти не разобран — в task-memory.md кита нет строки «Потолок файла — N строк.»'
        return
    }
    $count = (Get-KitServedLines $Path).Count
    if ($count -gt $Ceilings.memory) {
        New-KitFinding 'FAIL' $Label "$count строк при потолке $($Ceilings.memory) — перечитать по task-memory.md"
    }
}

# О ходе живой соседней работы сверка молчит; называет только файл, который не подаст никто:
# копии нет, адрес не сходится или файл не опознаётся, — иначе work/ молча стал бы архивом
# брошенных задач. Содержимое не подаётся никогда.
function Get-KitForeignMemoryFindings([string]$Base, [string]$Path, [string]$Label) {
    $declared = Get-KitDeclaredWorktree (Read-KitMarkdown $Path)
    if (-not $declared) {
        New-KitFinding 'FAIL' $Label 'не опознаётся: нет строки «рабочая копия» — не своя, решает оператор'
        return
    }
    if (-not (Test-Path -LiteralPath $declared -PathType Container)) {
        New-KitFinding 'FAIL' $Label "копии «$declared» нет на диске — не своя, решает оператор"
        return
    }
    if ((Get-KitWorkMemoryPath $Base $declared) -ine $Path) {
        New-KitFinding 'FAIL' $Label 'лежит не по адресу объявленной копии — не своя, решает оператор'
    }
}

# Запись остаётся в бэклоге, когда при взятии пропущен порядок «сначала вырезать, потом завести
# память»: занятость отмечает только файл памяти, и из соседней копии взятая задача по-прежнему
# видна невзятой записью. Направление проверки одно — вырез идёт до памяти, поэтому живая память
# при живой записи всегда нарушение, а не гонка двух копий на середине взятия. Бэклог читается
# с диска: вырез уезжает и отдельным коммитом. Чинится расхождение в бэклоге — его находка
# и называет; у чужой памяти читается только номер в заголовке. Своя она или чужая — по
# объявленной копии, как и везде: по адресу лежит и файл, положенный руками.
function Get-KitTakenRecordFindings([string]$Base, [string]$Path, [string]$Label, [string]$Worktree) {
    $text = Read-KitMarkdown $Path
    $number = [regex]::Match($text, '(?m)^#\s+B-(\d+)\b')
    if (-not $number.Success) { return }
    $n = [int]$number.Groups[1].Value

    $backlog = Join-Path $Base 'backlog.md'
    if (-not (Test-Path -LiteralPath $backlog -PathType Leaf)) { return }
    if ((Read-KitMarkdown $backlog) -notmatch "(?m)^##\s+B-$n\b") { return }

    $declared = Get-KitDeclaredWorktree $text
    $fix = if ($declared -and $declared -ieq $Worktree) { 'вырезать запись' } else { 'не своя, решает оператор' }
    New-KitFinding 'FAIL' 'backlog.md' "запись B-$n взята — память «$Label» живёт, а запись осталась: $fix"
}

# Ответ оператора вбирается и удаляется вместе с вопросом тем же обновлением, поэтому в коммит
# заполненный «ответ:» не уезжает: уехал — обновление сделано наполовину. На диске он законен —
# оператор только что его дописал, а сессия ещё не проснулась, — и сверка на старте о нём молчит.
function Get-KitAnsweredQuestionFindings([string]$Path, [string]$Label) {
    foreach ($q in @(Get-KitOperatorQuestions (Read-KitMarkdown $Path) | Where-Object { $_.answered })) {
        $short = $q.text
        if ($short.Length -gt 60) { $short = $short.Substring(0, 60) + '…' }
        New-KitFinding 'FAIL' $Label "вопрос «$short» с заполненным «ответ:» — ответ не вобран: вобрать, удалить вопрос вместе со строкой в «Агенту → Вопросы» и повторить коммит"
    }
}

# Отметка стадии в «Флоу»: номер стадии — стоит ли отметка. Сравниваются отметки, а не строки:
# строка меняется и от дописанного выхода, а переход виден только сменой отметки.
function Get-KitFlowMarks([string]$Text) {
    $marks = @{}
    foreach ($m in [regex]::Matches((Get-KitLayoutSection $Text '### Флоу'), '(?m)^\s*-\s*\[([ xX])\]\s*(\d+)\.')) {
        $marks[$m.Groups[2].Value] = ($m.Groups[1].Value -ne ' ')
    }
    return $marks
}

function Get-KitStepLines([string]$Text) {
    return @([regex]::Matches((Get-KitLayoutSection $Text '### Шаги'), '(?m)^\s*-\s*\[[ xX]\]\s*(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
}

# Коммит, в котором сменились отметки «Флоу», несёт переход или возврат, а шаги покинутой стадии
# уходят тем же обновлением: уцелевшая строка значит либо что их не убрали, либо что память
# коммитится не сразу после пройденной стадии. Прошлая версия берётся из HEAD базы; нет её —
# это коммит взятия или база без истории, и сверять не с чем.
function Get-KitLeftoverStepFindings([string]$Base, [string]$Path, [string]$Label) {
    $previous = & git -C $Base show "HEAD:$($Label.Replace([char]92, [char]47))" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $previous) { return }

    $was = ConvertTo-KitMarkdown ($previous -join "`n")
    $now = Read-KitMarkdown $Path
    $wasMarks = Get-KitFlowMarks $was
    $nowMarks = Get-KitFlowMarks $now
    $moved = $false
    foreach ($number in @($wasMarks.Keys) + @($nowMarks.Keys)) {
        if ($wasMarks[$number] -ne $nowMarks[$number]) { $moved = $true; break }
    }
    if (-not $moved) { return }

    $before = @{}
    foreach ($line in Get-KitStepLines $was) { $before[$line] = $true }
    $left = @(Get-KitStepLines $now | Where-Object { $before.ContainsKey($_) })
    if (-not $left.Count) { return }

    $short = $left[0]
    if ($short.Length -gt 60) { $short = $short.Substring(0, 60) + '…' }
    New-KitFinding 'FAIL' $Label "в «Шагах» осталось строк прежней стадии: $($left.Count), первая — «$short» — отметки «Флоу» сменились, а шаги покинутой стадии уходят тем же обновлением"
}

function Get-KitWorkFindings([string]$Base, [string]$Worktree, $Ceilings) {
    $work = Join-Path $Base 'work'
    if (-not (Test-Path -LiteralPath $work -PathType Container)) { return }
    $own = Get-KitWorkMemoryPath $Base $Worktree

    foreach ($item in @(Get-ChildItem -LiteralPath $work -Force -ErrorAction SilentlyContinue)) {
        $label = Get-KitRelativePath $Base (ConvertTo-KitPath $item.FullName)
        if ($item.PSIsContainer) { New-KitFinding 'WARN' $label 'подкаталог в work/ — память лежит плоско, файлом на рабочее дерево'; continue }
        if ($item.Extension -ine '.md') { New-KitFinding 'WARN' $label 'не .md в work/ — work/ держит только память задач'; continue }

        $path = ConvertTo-KitPath $item.FullName
        if ($own -and $path -ieq $own) { Get-KitOwnMemoryFindings $path $label $Worktree $Ceilings -SkipIdentity }
        else { Get-KitForeignMemoryFindings $Base $path $label }
        Get-KitTakenRecordFindings $Base $path $label $Worktree
    }
}

# Субагенты рабочей копии и пользователя. Субагенты плагинов не видны, поэтому
# ненайденный исполнитель или помощник — WARN.
function Get-KitVisibleAgents([string]$Worktree) {
    $names = @{}
    $dirs = @((Join-Path $HOME '.claude\agents'))
    if ($Worktree) { $dirs += Join-Path $Worktree '.claude\agents' }
    foreach ($dir in $dirs) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            try { $head = Get-Content -LiteralPath $file.FullName -TotalCount 40 -ErrorAction Stop } catch { continue }
            foreach ($line in $head) {
                if ($line -match '^\s*name\s*:\s*["'']?([^"''#]+?)["'']?\s*$') { $names[$Matches[1]] = $true; break }
            }
        }
    }
    return $names
}

# Название стадии как адрес ссылки: пробелы и регистр адреса не меняют.
function ConvertTo-KitStepName([string]$Name) {
    return ([regex]::Replace($Name, '\s+', ' ')).Trim().ToLowerInvariant()
}

# Флоу: то, что не даст пройти стадию однозначно, — нет обязательного ключа, чужой ключ,
# невидимый исполнитель или помощник, помощники не у оркестратора, сбитый порядок, ссылка
# со стадии на стадию номером или на название, которого во флоу нет, две стадии с одним названием,
# возврат без условия, без названия стадии в кавычках, на стадию, которой нет, или не назад по флоу.
# Длину флоу сверка не проверяет; отсутствие файла назвала сверка каркаса.
function Get-KitFlowFindings([string]$Base, [string]$Worktree, $Rules) {
    $path = Join-Path $Base 'flow.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if (-not $Rules.flowKeys.Contains('исполнитель') -or -not $Rules.executors.Count) {
        New-KitFinding 'FAIL' 'flow.md' 'перечень ключей стадии не разобран — таблица в разделе «Флоу проекта» раскладки'
        return
    }

    $steps = @()
    $current = $null
    $inKeys = $false
    foreach ($line in ((Read-KitMarkdown $path) -split '\r?\n')) {
        $heading = [regex]::Match($line, '^##\s+(\d+)\.\s+(.+?)\s*$')
        if ($heading.Success) {
            $current = @{
                number = [int]$heading.Groups[1].Value
                name = $heading.Groups[2].Value
                index = $steps.Count
                keys = [ordered]@{}
                returns = [System.Collections.Generic.List[string]]::new()
                body = [System.Collections.Generic.List[string]]::new()
            }
            $steps += $current
            $inKeys = $true
            continue
        }
        if (-not $current) { continue }
        if (-not $line.Trim()) {
            if ($current.keys.Count) { $inKeys = $false }
            continue
        }
        if ($inKeys -and $line -notmatch '^\s*\d+(\.\d+)+\.\s') {
            $pair = [regex]::Match($line, '^([^\s:][^:]*?)\s*:\s*(.*?)\s*$')
            if ($pair.Success) {
                $pairKey = $pair.Groups[1].Value
                $pairValue = $pair.Groups[2].Value
                # Возврат пишется строкой на каждый возврат, и все они нужны разом;
                # прочие ключи идут по одной строке, и в $keys хватает последней.
                if ($pairKey -eq 'возврат') { $current.returns.Add($pairValue) }
                $current.keys[$pairKey] = $pairValue
                continue
            }
        }
        $inKeys = $false
        $current.body.Add($line)
    }

    if (-not $steps.Count) {
        New-KitFinding 'WARN' 'flow.md' 'флоу пуст — написать его с оператором'
        return
    }

    # Адрес стадии — название: номер съезжает вслед за перестановкой стадий, а описание
    # остаётся связным и ведёт в чужую стадию молча. Отсюда и запрет одинаковых названий.
    $names = @{}
    foreach ($step in $steps) {
        $key = ConvertTo-KitStepName $step.name
        if ($names.ContainsKey($key)) {
            New-KitFinding 'FAIL' 'flow.md' "стадия $($step.number): название «$($step.name)» уже у стадии $($names[$key].number) — ссылка на такую стадию неоднозначна"
            continue
        }
        $names[$key] = $step
    }

    $agents = $null
    $previous = 0
    foreach ($step in $steps) {
        $n = $step.number
        if ($n -ne $previous + 1) {
            New-KitFinding 'WARN' 'flow.md' "стадия $n после стадии $previous — порядок исполнения — порядок номеров"
        }
        $previous = $n

        foreach ($key in $step.keys.Keys) {
            if (-not $Rules.flowKeys.Contains($key)) {
                New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: ключ «$key» вне перечня — своих ключей не заводят"
            }
        }
        foreach ($key in $Rules.flowKeys.Keys) {
            if (-not $Rules.flowKeys[$key]) { continue }
            if (-not $step.keys.Contains($key)) { New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: нет ключа «$key»" }
            elseif (-not $step.keys[$key]) { New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: ключ «$key» пуст" }
        }

        foreach ($line in $step.body) {
            foreach ($ref in [regex]::Matches($line, '(?i)\bстади[а-яё]*\s+(\d+)')) {
                New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: ссылка «$($ref.Value)» — на стадию ссылаются названием в кавычках"
            }
            foreach ($ref in [regex]::Matches($line, '(?i)\bстади[а-яё]*\s+«([^»]+)»')) {
                $name = $ref.Groups[1].Value
                if (-not $names.ContainsKey((ConvertTo-KitStepName $name))) {
                    New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: ссылка на стадию «$name» — такой стадии во флоу нет"
                }
            }
        }

        # Возврат в описание стадии не попадает — он ключ, и правила ссылки его строку не
        # видят; направление проверяется по положению стадии, а не по номеру: номера бывают сбиты.
        foreach ($return in $step.returns) {
            $numbered = [regex]::Matches($return, '(?i)\bстади[а-яё]*\s+(\d+)')
            foreach ($ref in $numbered) {
                New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: возврат «$($ref.Value)» — на стадию ссылаются названием в кавычках"
            }
            $target = [regex]::Match($return, '(?i)\bстади[а-яё]*\s+«([^»]+)»')
            if (-not $target.Success) {
                if (-not $numbered.Count) {
                    New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: возврат «$return» — назад адресуются стадией и названием в кавычках"
                }
                continue
            }
            $targetName = $target.Groups[1].Value
            if (-not $return.Substring(0, $target.Index).Trim([char[]]' —-:,')) {
                New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: возврат к стадии «$targetName» без условия"
            }
            $targetKey = ConvertTo-KitStepName $targetName
            if (-not $names.ContainsKey($targetKey)) {
                New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: возврат к стадии «$targetName» — такой стадии во флоу нет"
            }
            elseif ($names[$targetKey].index -ge $step.index) {
                New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: возврат к стадии «$targetName» — она не раньше: флоу вперёд не прыгает"
            }
        }

        # Помощники — кусок работы оркестратора, отданный субагенту: стадия, чью работу делает
        # не он, звать помощников некому.
        $executor = $step.keys['исполнитель']
        $helpers = @(($step.keys['помощники'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($helpers.Count -and $executor -and $executor -ne 'оркестратор') {
            New-KitFinding 'FAIL' 'flow.md' "стадия ${n}: ключ «помощники» — зовёт их оркестратор, а работу стадии делает «$executor»"
        }
        foreach ($helper in $helpers) {
            if ($null -eq $agents) { $agents = Get-KitVisibleAgents $Worktree }
            if (-not $agents.ContainsKey($helper)) {
                New-KitFinding 'WARN' 'flow.md' "стадия ${n}: помощника «$helper» не видно — может прийти из плагина; нет его — вопрос оператору"
            }
        }

        if (-not $executor -or $Rules.executors -contains $executor) { continue }
        if ($null -eq $agents) { $agents = Get-KitVisibleAgents $Worktree }
        if (-not $agents.ContainsKey($executor)) {
            New-KitFinding 'WARN' 'flow.md' "стадия ${n}: субагента «$executor» не видно — может прийти из плагина; нет его — вопрос оператору"
        }
    }
}

function Get-KitBaseFindings([string]$Base, [string]$Worktree) {
    $Base = ConvertTo-KitPath $Base
    $rules = Get-KitLayoutRules

    Get-KitLinkFindings $Base
    Get-KitGitFindings $Base
    Get-KitRootFindings $Base $rules
    Get-KitDecisionFindings $Base $rules
    Get-KitFlowFindings $Base $Worktree $rules
    Get-KitWorkFindings $Base $Worktree $rules

    # Незакоммиченное входит: это то, что вот-вот уедет в историю.
    foreach ($rel in @(& git -C $Base ls-files --cached --others --exclude-standard 2>$null | Where-Object { $_ })) {
        $path = ConvertTo-KitPath (Join-Path $Base $rel)
        if (Test-Path -LiteralPath $path -PathType Leaf) { Find-KitSecrets $path (Get-KitRelativePath $Base $path) }
    }
}

# Files — абсолютные пути. Удалённый файл не проверяется: закрыть задачу удалением
# памяти можно всегда, и чинить в нём уже нечего.
function Get-KitCommitFindings([string]$Base, [string]$Worktree, [string[]]$Files) {
    $Base = ConvertTo-KitPath $Base
    $rules = Get-KitLayoutRules
    $own = Get-KitWorkMemoryPath $Base $Worktree

    Get-KitGitFindings $Base

    $seen = @{}
    foreach ($file in @($Files | Where-Object { $_ })) {
        $path = ConvertTo-KitPath $file
        if (-not $path.StartsWith($Base + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($seen.ContainsKey($path.ToLowerInvariant())) { continue }
        $seen[$path.ToLowerInvariant()] = $true
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $rel = Get-KitRelativePath $Base $path

        if ($rel -match '^local\\') {
            New-KitFinding 'FAIL' $rel 'файл из local/ в коммите — значения кредов в git базы не попадают'
            continue
        }
        if ($rel -notmatch '\\' -and $rel -match '\.md$') {
            if ($script:KitServedFiles -contains $rel) { Get-KitKnowledgeCeilingFindings $path $rel $rules }
            elseif ($rel -ieq 'flow.md') { Get-KitFlowFindings $Base $Worktree $rules }
            elseif ($rel -ieq 'backlog.md') { Get-KitBacklogFindings $path $rel $rules }
        }
        elseif ($rel -match "^$($script:KitDecisionsDir)\\[^\\]+\.md$") {
            Get-KitDecisionFileFindings $path $rel $rules
        }
        elseif ($rel -match '^work\\[^\\]+\.md$') {
            # Взятая запись ловится со стороны своей памяти: это коммит взятия. Со стороны
            # бэклога её не ищут — вырезать чужую запись коммит бэклога всё равно не может.
            if ($own -and $path -ieq $own) {
                Get-KitOwnMemoryFindings $path $rel $Worktree $rules
                Get-KitAnsweredQuestionFindings $path $rel
                Get-KitLeftoverStepFindings $Base $path $rel
                Get-KitTakenRecordFindings $Base $path $rel $Worktree
            }
            else { New-KitFinding 'FAIL' $rel 'память другой рабочей копии в коммите — не своя, решает оператор' }
        }
        Find-KitSecrets $path $rel
    }
}
