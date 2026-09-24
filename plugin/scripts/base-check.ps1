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
$script:KitAgentsDir = 'agents'
# Флоу — каталог: scenarios.md со списками сценариев и stages/ с файлами этапов. Ссылка
# в списке ведёт в stages/ от scenarios.md.
$script:KitFlowDir = 'flow'
$script:KitScenariosFile = 'flow/scenarios.md'
$script:KitStagesDir = 'stages'

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
# Заголовок внутри блока кода разделом не считается: пример сценариев начинается с «##».
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

    foreach ($row in Get-KitKeyRows (Get-KitLayoutSection (Read-KitReference 'flow-stages.md') '## Этап')) {
        $key = $row.Groups[1].Value
        $result.flowKeys[$key] = ($row.Groups[3].Value -eq 'да')
        if ($key -eq 'исполнитель') {
            $result.executors = @([regex]::Matches($row.Groups[2].Value, '`([^`<>]+)`') | ForEach-Object { $_.Groups[1].Value })
        }
    }

    $text = Read-KitReference 'base-layout.md'

    foreach ($row in [regex]::Matches($text, '(?m)^\|\s*`([^`]+\.md)`\s*\|.*\|\s*([^|]*?)\s*\|\s*$')) {
        $cell = [regex]::Match($row.Groups[2].Value, '^(\d+) строк$')
        if (-not $cell.Success) { continue }
        $result.files[$row.Groups[1].Value.ToLowerInvariant()] = [int]$cell.Groups[1].Value
    }

    $decision = [regex]::Match($text, '(?m)^Потолок файла решений — (\d+) строк\.')
    if ($decision.Success) { $result.decision = [int]$decision.Groups[1].Value }
    return $result
}

# Файлы каркаса — путём от корня базы — берутся из шаблона, а не перечисляются здесь: новый
# файл шаблона становится известным сверке без её правки.
function Get-KitTemplateNames {
    $template = ConvertTo-KitPath (Join-Path $PSScriptRoot '..\template\base')
    try {
        return @(Get-ChildItem -LiteralPath $template -File -Force -Recurse -ErrorAction Stop |
                ForEach-Object { (ConvertTo-KitPath $_.FullName).Substring($template.Length).TrimStart('\') })
    }
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
        New-KitFinding 'FAIL' 'agents-kit.json' 'списка копий нет, он не читается или в нём нет формата базы — это не база кита'
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

# Одно расхождение у многих записей — одна находка: бэклог потолка не имеет, и строка на запись
# росла бы вместе с ним в подаче каждой сессии. Красная называет все записи: по ней чинят до
# коммита, и с неназванной записью отказ повторится. Предупреждение висит в подаче, пока оператор
# не дошёл до него сам, — сверх трёх записей оно идёт счётом.
function Add-KitGroupedFinding($Groups, [string]$Severity, [string]$Head, [string]$Tail, [string]$Label) {
    $key = "$Severity|$Head|$Tail"
    if (-not $Groups.Contains($key)) {
        $Groups[$key] = [pscustomobject]@{
            severity = $Severity; head = $Head; tail = $Tail
            labels = [System.Collections.Generic.List[string]]::new()
        }
    }
    $Groups[$key].labels.Add($Label)
}

function Get-KitGroupedFindings($Groups, [string]$File) {
    foreach ($group in $Groups.Values) {
        $named = ($group.labels -join ', ')
        if ($group.severity -ne 'FAIL' -and $group.labels.Count -gt 3) {
            $named = (@($group.labels | Select-Object -First 3) -join ', ') + " и ещё $($group.labels.Count - 3)"
        }
        $message = "$($group.head): $named"
        if ($group.tail) { $message += " — $($group.tail)" }
        New-KitFinding $group.severity $File $message
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

    $groups = [ordered]@{}
    foreach ($entry in $Entries) {
        foreach ($name in $fields) {
            if (-not $entry.keys.Contains($name)) {
                Add-KitGroupedFinding $groups 'WARN' "нет поля «$name»" 'проставит /backlog' $entry.label
                continue
            }
            $value = $entry.keys[$name]
            if (-not $value) {
                Add-KitGroupedFinding $groups 'FAIL' "поле «$name» пусто" '' $entry.label
                continue
            }
            if ($Rules.backlogFields[$name] -notcontains $value) {
                Add-KitGroupedFinding $groups 'FAIL' "«$name : $value» вне перечня" ($Rules.backlogFields[$name] -join ' · ') $entry.label
            }
        }
        foreach ($key in $entry.keys.Keys) {
            if ($fields -notcontains $key) {
                Add-KitGroupedFinding $groups 'WARN' "поле «$key» не объявлено строкой «поля:» шапки" '' $entry.label
            }
        }
    }
    Get-KitGroupedFindings $groups $Label
}

# Буквы номера задаёт база, и держит их строка счётчика — второго места у них нет. Счётчика нет
# (он сам находка) — буквы берутся из первой записи с номером: иначе до его появления перестал
# бы находиться повтор номера. Разбор один на бэклог и на память задачи: разойдись они, взятая
# запись перестала бы сходиться со своей памятью.
function Get-KitBacklogCounter([string]$Text) {
    return [regex]::Match($Text, '(?im)^\s*следующий\s+номер\s*:\s*([A-Za-z][A-Za-z0-9]*)-(\d+)\s*$')
}

function Get-KitBacklogPrefix([string]$Text) {
    $counter = Get-KitBacklogCounter $Text
    if ($counter.Success) { return $counter.Groups[1].Value }
    $first = [regex]::Match($Text, '(?m)^##\s+([A-Za-z][A-Za-z0-9]*)-\d+\b')
    if ($first.Success) { return $first.Groups[1].Value }
    return $null
}

# Номер записи бэклога выдаёт счётчик в шапке файла: из оставшихся записей номер не вычислить,
# по истории git тоже — она не видит незакоммиченных записей соседней копии. Запись — заголовок
# «##», под ним подряд пары «ключ: значение». Повтор номера, номер чужими буквами и счётчик не
# выше наибольшего — FAIL; запись без номера и файл без счётчика чинит /backlog — WARN.
function Get-KitBacklogFindings([string]$Path, [string]$Label, $Rules) {
    $text = Read-KitMarkdown $Path
    $prefix = Get-KitBacklogPrefix $text
    $numbers = @{}
    $foreign = [ordered]@{}
    $unnumbered = 0
    $entries = @()
    $head = [System.Collections.Generic.List[string]]::new()
    $current = $null
    $inKeys = $false
    foreach ($line in ($text -split '\r?\n')) {
        if ($line -match '^##\s') {
            $m = if ($prefix) { [regex]::Match($line, "(?i)^##\s+$prefix-(\d+)\b") } else { $null }
            if ($m -and $m.Success) {
                $n = [int]$m.Groups[1].Value
                $numbers[$n] = 1 + [int]$numbers[$n]
                $current = @{ label = "$prefix-$n"; keys = [ordered]@{} }
            }
            else {
                # Имя записи без номера — её заголовок, и в перечне записей он берётся в кавычки:
                # иначе границы между ним и соседним номером не видно.
                $title = $line -replace '^#+\s*', ''
                if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + '…' }
                # Запись чужими буквами не считается ненумерованной: выдай ей /backlog свой номер,
                # заголовок оператора переписался бы молча.
                if ($prefix -and $line -match '^##\s+[A-Za-z][A-Za-z0-9]*-\d+\b') {
                    Add-KitGroupedFinding $foreign 'FAIL' "нумерованы не буквами «$prefix-»" 'выдать номер счётчиком' "«$title»"
                }
                else { $unnumbered++ }
                $current = @{ label = "«$title»"; keys = [ordered]@{} }
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
        New-KitFinding 'FAIL' $Label "номер $prefix-$n у $($numbers[$n]) записей — одной из записей выдать новый через счётчик"
    }
    if ($unnumbered) {
        New-KitFinding 'WARN' $Label "$unnumbered записей без номера — пронумерует /backlog"
    }
    Get-KitGroupedFindings $foreign $Label

    $counter = Get-KitBacklogCounter $text
    if (-not $counter.Success) {
        New-KitFinding 'WARN' $Label 'нет строки «следующий номер: <буквы>-N» — поставит /backlog'
    }
    else {
        $next = [int]$counter.Groups[2].Value
        $max = @($numbers.Keys | Sort-Object -Descending | Select-Object -First 1)
        if ($max.Count -and $next -le $max[0]) {
            New-KitFinding 'FAIL' $Label "следующий номер $prefix-$next не выше наибольшего $prefix-$($max[0]) — поднять счётчик за наибольший"
        }
    }

    Get-KitBacklogFieldFindings $Label ($head -join "`n") $entries $Rules
}

# Каркас на месте, файлы корня: подаваемые в потолке, бэклог сходится со счётчиком и перечнем полей.
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

function Test-KitAgentSubsection([string]$Text, [string]$Sub) {
    return (Get-KitLayoutSection $Text '## Агенту') -match "(?m)^###\s+$([regex]::Escape($Sub))\s*$"
}

# Подраздел, где стоят строки этапов вне «Сценария». Без заголовка они уходят в предыдущий
# подраздел — по шаблону это «Факты». «Шаги» не смотрятся: шаг тоже может начинаться
# с цифры, а у строк остальных подразделов по шаблону галочки нет.
function Find-KitStrayStageSection([string]$Text) {
    $section = $null
    foreach ($line in ($Text -split '\r?\n')) {
        $heading = [regex]::Match($line, '^###\s+(.+?)\s*$')
        if ($heading.Success) { $section = $heading.Groups[1].Value; continue }
        if ($line -match '^##?\s') { $section = $null; continue }
        if (-not $section -or $section -in 'Сценарий', 'Шаги') { continue }
        if ($line -match '^\s*-\s*\[[ xX]\]\s*\d+\.\s') { return $section }
    }
    return $null
}

# Разделы памяти и связь двух её частей. Без «Сценария» и «Шагов» молча выключается сверка
# хода задачи — FAIL; строка агенту без своего критерия или вопроса — не ошибка формы,
# а повод перечитать: WARN.
function Get-KitMemoryLayoutFindings([string]$Text, [string]$Label) {
    foreach ($section in 'Критерии закрытия', 'Оператору', 'Агенту') {
        if ($Text -notmatch "(?m)^##\s+$([regex]::Escape($section))\s*$") {
            New-KitFinding 'WARN' $Label "нет раздела «## $section» из шаблона памяти"
        }
    }
    $agent = Get-KitLayoutSection $Text '## Агенту'
    foreach ($sub in 'Критерии', 'Вопросы', 'Факты', 'Сценарий', 'Шаги') {
        if (Test-KitAgentSubsection $Text $sub) { continue }
        if ($sub -notin 'Сценарий', 'Шаги') {
            New-KitFinding 'WARN' $Label "нет подраздела «### $sub» в «Агенту» из шаблона памяти"
            continue
        }
        $stray = if ($sub -eq 'Сценарий') { Find-KitStrayStageSection $Text } else { $null }
        if ($stray) { New-KitFinding 'FAIL' $Label "нет подраздела «### $sub» в «Агенту» — строки этапов стоят в «### $stray»: вернуть заголовок над ними" }
        else { New-KitFinding 'FAIL' $Label "нет подраздела «### $sub» в «Агенту» из шаблона памяти" }
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

# Строка «сценарий:» памяти — имя сценария задачи; пустая считается отсутствующей.
function Get-KitMemoryFlow([string]$Text) {
    $m = [regex]::Match($Text, '(?im)^\s*сценарий\s*:\s*(.*?)\s*$')
    if (-not $m.Success -or -not $m.Groups[1].Value) { return $null }
    return $m.Groups[1].Value
}

# Этапы «Агенту → Сценарий» как «n. название»: записанное после названия — круг, выход,
# причина пропуска — отрезается по первому тире.
function Get-KitMemoryFlowStages([string]$Text) {
    foreach ($m in [regex]::Matches((Get-KitLayoutSection $Text '### Сценарий'), '(?m)^\s*-\s*\[[ xX]\]\s*(\d+)\.\s+(.+?)\s*$')) {
        $name = [regex]::Split($m.Groups[2].Value, '\s—\s')[0]
        "$($m.Groups[1].Value). $(ConvertTo-KitTitleKey $name)"
    }
}

function Find-KitFlow($Flows, [string]$Name) {
    $key = ConvertTo-KitTitleKey $Name
    return @($Flows | Where-Object { (ConvertTo-KitTitleKey $_.name) -eq $key }) | Select-Object -First 1
}

# Те же ли этапы у сценария, что в «Агенту → Сценарий» памяти: те же названия в том же порядке.
function Test-KitFlowMatchesMemory($Flow, [string]$Text) {
    $want = @(for ($i = 0; $i -lt $Flow.items.Count; $i++) { "$($i + 1). $(ConvertTo-KitTitleKey $Flow.items[$i].title)" })
    $have = @(Get-KitMemoryFlowStages $Text)
    return ($want -join "`n") -eq ($have -join "`n")
}

# Сценарий задачи: строка есть и называет сценарий из scenarios.md. Разошедшийся со списком
# сценария перечень этапов — WARN: сценарий могли поправить посреди задачи, и решает это
# сессия с оператором. Этапов ноль — FAIL, и сравнения со списком нет: у пустого «Сценария»
# одна причина, а не правка сценария. Нет самого заголовка — причину уже назвала находка
# формы памяти.
# Имени нет — сценарий переименован или удалён; кандидата на новое имя сверка называет, но
# строку не правит: удалённый сценарий с теми же этапами неотличим от переименованного.
function Get-KitMemoryFlowFindings([string]$Base, [string]$Text, [string]$Label) {
    $name = Get-KitMemoryFlow $Text
    if (-not $name) {
        New-KitFinding 'FAIL' $Label 'нет строки «сценарий:» с именем сценария задачи — сценарий выбирается при взятии'
        return
    }
    $flows = @(Get-KitFlowList $Base)
    $flow = Find-KitFlow $flows $name
    if (-not $flow) {
        $same = @($flows | Where-Object { $_.items.Count -and (Test-KitFlowMatchesMemory $_ $Text) })
        if ($same.Count -eq 1) {
            New-KitFinding 'FAIL' $Label "«сценарий: $name» — такого сценария в $($script:KitScenariosFile) нет; похоже, он переименован в «$($same[0].name)»: этапы те же — поправить строку «сценарий:» на это имя; сценарий удалён — вопрос оператору"
        }
        else {
            New-KitFinding 'FAIL' $Label "«сценарий: $name» — такого сценария в $($script:KitScenariosFile) нет: переименован — поправить строку «сценарий:» на новое имя и перенести в «Сценарий» памяти его этапы; удалён — вопрос оператору"
        }
        return
    }
    if (-not (Test-KitAgentSubsection $Text 'Сценарий')) { return }
    if (-not @(Get-KitMemoryFlowStages $Text).Count) {
        $stray = Find-KitStrayStageSection $Text
        if ($stray) { New-KitFinding 'FAIL' $Label "в «Агенту → Сценарий» нет ни одного этапа — строки этапов стоят в «### $stray»: перенести их в «Сценарий»" }
        else { New-KitFinding 'FAIL' $Label "в «Агенту → Сценарий» нет ни одного этапа — переписать этапы сценария «$($flow.name)» из $($script:KitScenariosFile)" }
        return
    }
    if (-not (Test-KitFlowMatchesMemory $flow $Text)) {
        New-KitFinding 'WARN' $Label "«Агенту → Сценарий» разошлось со списком сценария «$($flow.name)» в $($script:KitScenariosFile) — сценарий могли поправить посреди задачи: перечитать и решить с оператором"
    }
}

# Опознание своей памяти на старте называет подача session-start.ps1 (-SkipIdentity);
# в коммите его назвать больше некому.
function Get-KitOwnMemoryFindings([string]$Base, [string]$Path, [string]$Label, [string]$Worktree, $Ceilings, [switch]$SkipIdentity) {
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
    Get-KitMemoryFlowFindings $Base $text $Label

    # Нарезка видна и без коммита: на старте эту проверку зовёт подача. Без заголовка «Шагов»
    # строки шагов не видны, и пропажу называет находка формы памяти.
    if ((Test-KitAgentSubsection $text 'Шаги') -and @((Get-KitFlowMarks $text).Values | Where-Object { -not $_ }).Count -and -not @(Get-KitStepLines $text).Count) {
        New-KitFinding 'FAIL' $Label 'в «Сценарии» есть неотмеченный этап, а «Шаги» пусты — работа открытого этапа режется строками до работы'
    }

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
    $backlog = Join-Path $Base 'backlog.md'
    if (-not (Test-Path -LiteralPath $backlog -PathType Leaf)) { return }
    $backlogText = Read-KitMarkdown $backlog
    $prefix = Get-KitBacklogPrefix $backlogText
    if (-not $prefix) { return }

    $text = Read-KitMarkdown $Path
    $number = [regex]::Match($text, "(?im)^#\s+$prefix-(\d+)\b")
    if (-not $number.Success) { return }
    $n = [int]$number.Groups[1].Value
    if ($backlogText -notmatch "(?im)^##\s+$prefix-$n\b") { return }

    $declared = Get-KitDeclaredWorktree $text
    $fix = if ($declared -and $declared -ieq $Worktree) { 'вырезать запись' } else { 'не своя, решает оператор' }
    New-KitFinding 'FAIL' 'backlog.md' "запись $prefix-$n взята — память «$Label» живёт, а запись осталась: $fix"
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

# Отметка этапа в «Сценарии»: номер этапа — стоит ли отметка. Сравниваются отметки, а не строки:
# строка меняется и от дописанного выхода, а переход виден только сменой отметки.
function Get-KitFlowMarks([string]$Text) {
    $marks = @{}
    foreach ($m in [regex]::Matches((Get-KitLayoutSection $Text '### Сценарий'), '(?m)^\s*-\s*\[([ xX])\]\s*(\d+)\.')) {
        $marks[$m.Groups[2].Value] = ($m.Groups[1].Value -ne ' ')
    }
    return $marks
}

# Строка «Шагов»: отметка, текст шага и то, чем он закрыт. Текст — ключ, по которому строка
# узнаётся в прошлой версии: закрытие её дописывает, и сравнение строк целиком приняло бы
# закрытую и незакрытую за разные шаги. Отрезает дописанное «— результат:» или «— пропущен:»,
# а не первое тире: тире стоит и в самом шаге.
function Get-KitStepLines([string]$Text) {
    $steps = @()
    foreach ($m in [regex]::Matches((Get-KitLayoutSection $Text '### Шаги'), '(?m)^\s*-\s*\[([ xX])\]\s*(.+?)\s*$')) {
        $body = $m.Groups[2].Value
        $closing = [regex]::Match($body, '\s—\s*(?=(результат|пропущен)\s*:)')
        $head = $body
        $tail = ''
        if ($closing.Success) {
            $head = $body.Substring(0, $closing.Index).TrimEnd()
            $tail = $body.Substring($closing.Index + $closing.Length).Trim()
        }
        $steps += [pscustomobject]@{ text = $head; tail = $tail; closed = ($m.Groups[1].Value -ne ' ') }
    }
    return $steps
}

function Test-KitStepClosed($Step) {
    if ($Step.tail -match '^пропущен\s*:\s*\S') { return $true }
    return ($Step.tail -match '^результат\s*:\s*\S') -and ($Step.tail -match '—\s*проверен\s*:\s*\S')
}

# Находку читают в подаче, где строка шага с результатом и проверкой съела бы экран.
function Get-KitStepQuote([string]$Text) {
    if ($Text.Length -gt 60) { return $Text.Substring(0, 60) + '…' }
    return $Text
}

# Шаги в коммите памяти: отмечались ли они по ходу и уходят ли закрытыми. Прошлая версия
# берётся из HEAD базы; нет её — это коммит взятия или база без истории, и сравнивать не с чем,
# а форму закрытых строк сверка называет и тогда. Правила — справка task-memory.md.
function Get-KitStepFindings([string]$Base, [string]$Path, [string]$Label) {
    $now = Read-KitMarkdown $Path
    $nowSteps = @(Get-KitStepLines $now)
    foreach ($step in $nowSteps) {
        if ($step.closed -and -not (Test-KitStepClosed $step)) {
            New-KitFinding 'FAIL' $Label "в «Шагах» закрытая строка «$(Get-KitStepQuote $step.text)» без «результат:» с «проверен:» и без «пропущен:»"
        }
    }

    $previous = & git -C $Base show "HEAD:$($Label.Replace([char]92, [char]47))" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $previous) { return }

    $was = ConvertTo-KitMarkdown ($previous -join "`n")

    # Смену сценария от переименования отличает то, что прежний сценарий исчез из scenarios.md,
    # а у сценария с новым именем те же этапы, что в памяти: правка этапов посреди задачи и так
    # разрешена, а при переименовании задача остаётся на своём сценарии. scenarios.md читается
    # с диска, а не из HEAD: переименование уезжает и тем же коммитом, что память, и раньше неё.
    $wasFlow = Get-KitMemoryFlow $was
    $nowFlow = Get-KitMemoryFlow $now
    $renamed = $false
    if ($wasFlow -and $nowFlow -and (ConvertTo-KitTitleKey $wasFlow) -ne (ConvertTo-KitTitleKey $nowFlow)) {
        $flows = @(Get-KitFlowList $Base)
        $target = Find-KitFlow $flows $nowFlow
        $renamed = -not (Find-KitFlow $flows $wasFlow) -and $target -and $target.items.Count -and (Test-KitFlowMatchesMemory $target $now)
    }
    if ($wasFlow -and -not $renamed -and (ConvertTo-KitTitleKey $wasFlow) -ne (ConvertTo-KitTitleKey $nowFlow)) {
        New-KitFinding 'FAIL' $Label "«сценарий:» сменилась с «$wasFlow» на «$nowFlow» — сценарий задачи не меняется: сценарий переименован — перенести в «Сценарий» памяти его этапы тем же коммитом; задача переросла сценарий — вопрос оператору о сужении критерия"
    }
    # Без заголовка «Шагов» в одной из версий шаги не сравнить: пропажу называет находка формы
    # памяти, а коммит, который возвращает заголовок, — починка, а не новые шаги.
    if (-not (Test-KitAgentSubsection $was 'Шаги') -or -not (Test-KitAgentSubsection $now 'Шаги')) { return }
    $wasSteps = @(Get-KitStepLines $was)
    $before = @{}
    foreach ($step in $wasSteps) { $before[$step.text] = $step }
    $after = @{}
    foreach ($step in $nowSteps) { $after[$step.text] = $step }

    $wasMarks = Get-KitFlowMarks $was
    $nowMarks = Get-KitFlowMarks $now
    $moved = $false
    $returned = $false
    # Пропажа или возврат раздела этапов — не переход: пропажу называет находка формы памяти.
    $marked = @($wasMarks.Keys) + @($nowMarks.Keys)
    if (-not $wasMarks.Count -or -not $nowMarks.Count) { $marked = @() }
    foreach ($number in $marked) {
        if ($wasMarks[$number] -eq $nowMarks[$number]) { continue }
        $moved = $true
        # Возврат снимает отметку, переход ставит: недоделанное покинутого этапа возврат
        # уносит вместе с кругом, а из пройденного этапа незакрытому шагу уйти некуда.
        if ($wasMarks[$number] -and -not $nowMarks[$number]) { $returned = $true }
    }

    $dropped = @($wasSteps | Where-Object { -not $returned -and -not $_.closed -and -not $after.ContainsKey($_.text) })
    if ($dropped.Count) {
        New-KitFinding 'FAIL' $Label "из «Шагов» ушло незакрытых строк: $($dropped.Count), первая — «$(Get-KitStepQuote $dropped[0].text)» — шаг уходит закрытым или с причиной пропуска"
    }
    $born = @($nowSteps | Where-Object { $_.closed -and -not $before.ContainsKey($_.text) })
    if ($born.Count) {
        New-KitFinding 'FAIL' $Label "в «Шагах» строка «$(Get-KitStepQuote $born[0].text)» появилась уже закрытой — сначала строка, потом работа"
    }
    # Закрылись две строки разом — отмечали не по ходу: отметка снимается со второй, первая
    # коммитится, вторая закрывается снова.
    $closed = @($nowSteps | Where-Object { $_.closed -and $before.ContainsKey($_.text) -and -not $before[$_.text].closed })
    if ($closed.Count -gt 1) {
        New-KitFinding 'FAIL' $Label "в «Шагах» закрыто строк одним коммитом: $($closed.Count) — шаг отмечается сразу после проверки и коммитится по одному"
    }

    # Коммит, в котором сменились отметки «Сценария», несёт переход или возврат, а шаги
    # покинутого этапа уходят тем же обновлением: уцелевшая строка значит либо что их не убрали,
    # либо что память коммитится не сразу после пройденного этапа.
    if (-not $moved) { return }

    $left = @($nowSteps | Where-Object { $before.ContainsKey($_.text) })
    if (-not $left.Count) { return }
    New-KitFinding 'FAIL' $Label "в «Шагах» осталось строк прежнего этапа: $($left.Count), первая — «$(Get-KitStepQuote $left[0].text)» — отметки «Сценария» сменились, а шаги покинутого этапа уходят тем же обновлением"
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
        if ($own -and $path -ieq $own) { Get-KitOwnMemoryFindings $Base $path $label $Worktree $Ceilings -SkipIdentity }
        else { Get-KitForeignMemoryFindings $Base $path $label }
        Get-KitTakenRecordFindings $Base $path $label $Worktree
    }
}

# Имя субагента — строка «name:» его заголовка: по ней его зовёт этап, и по ней же кит
# сводит файл базы с файлом копии.
function Get-KitAgentName([string]$Path) {
    try { $head = Get-Content -LiteralPath $Path -TotalCount 40 -ErrorAction Stop } catch { return $null }
    foreach ($line in $head) {
        if ($line -match '^\s*name\s*:\s*["'']?([^"''#]+?)["'']?\s*$') { return $Matches[1] }
    }
    return $null
}

# Субагенты базы и то, что из них довезено в эту копию. Красная — файл, по которому субагента
# не позвать: имя файла и строка «name:» адресуют его вместе. Расхождение раскладки — одна
# строка на вид: чинит его прогон скрипта, а не правка базы.
function Get-KitAgentFindings([string]$Base, [string]$Worktree) {
    $dir = Join-Path $Base $script:KitAgentsDir
    $sources = [ordered]@{}
    foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        $label = Get-KitRelativePath $Base (ConvertTo-KitPath $item.FullName)
        if ($item.PSIsContainer) { New-KitFinding 'WARN' $label "подкаталог в $($script:KitAgentsDir)/ — субагенты лежат плоско, файлом на субагента"; continue }
        if ($item.Extension -ine '.md') { New-KitFinding 'WARN' $label "не .md в $($script:KitAgentsDir)/ — каталог держит только субагентов"; continue }
        $name = Get-KitAgentName (ConvertTo-KitPath $item.FullName)
        if (-not $name) { New-KitFinding 'FAIL' $label 'нет строки «name:» — по ней субагента зовёт этап'; continue }
        if ($name -cne $item.BaseName) { New-KitFinding 'FAIL' $label "«name: $name» не совпадает с именем файла — зовут субагента по «name:», а кладут его файлом"; continue }
        $sources[$item.Name] = ConvertTo-KitPath $item.FullName
    }

    if (-not $Worktree) { return }
    $target = Get-KitAgentDir $Worktree
    if (-not $sources.Count -and -not (Test-Path -LiteralPath $target -PathType Container)) { return }

    $tracked = @(Get-KitTrackedAgents $Worktree)
    $unhidden = @(Get-KitUnhiddenAgents $Worktree)
    $groups = [ordered]@{}
    foreach ($name in @($sources.Keys)) {
        if ($tracked -contains $name) {
            Add-KitGroupedFinding $groups 'WARN' 'имя занято отслеживаемым файлом проекта' 'кит такой файл не трогает — развести имена' $name
            continue
        }
        $dst = Join-Path $target $name
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
            Add-KitGroupedFinding $groups 'WARN' 'в эту копию не довезены' 'agents-deploy.ps1' $name
            continue
        }
        if ($unhidden -contains $name) {
            Add-KitGroupedFinding $groups 'WARN' 'видны git проекта' 'вернёт укрытие agents-deploy.ps1' $name
        }
        if ((Get-KitAgentText $dst) -cne (Get-KitAgentText $sources[$name])) {
            Add-KitGroupedFinding $groups 'WARN' 'в копии разошлись с базой' 'верна база — agents-deploy.ps1' $name
        }
    }

    # Разложенное прежним прогоном, чего в базе уже нет: сессия позвала бы снятого субагента.
    foreach ($name in @(Get-KitDeployedAgents $Worktree)) {
        if ($sources.Contains($name)) { continue }
        if ($tracked -contains $name) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $target $name) -PathType Leaf)) { continue }
        Add-KitGroupedFinding $groups 'WARN' 'остались в копии от прежней раскладки' 'уберёт agents-deploy.ps1' $name
    }

    Get-KitGroupedFindings $groups $script:KitAgentsDir
}

# Субагенты рабочей копии и пользователя. Субагенты плагинов не видны, поэтому
# ненайденный исполнитель или помощник — WARN.
function Get-KitVisibleAgents([string]$Worktree) {
    $names = @{}
    $dirs = @((Join-Path $HOME '.claude\agents'))
    if ($Worktree) { $dirs += Get-KitAgentDir $Worktree }
    foreach ($dir in $dirs) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            $name = Get-KitAgentName $file.FullName
            if ($name) { $names[$name] = $true }
        }
    }
    return $names
}

# Название этапа или сценария как адрес: пробелы и регистр адреса не меняют.
function ConvertTo-KitTitleKey([string]$Name) {
    return ([regex]::Replace($Name, '\s+', ' ')).Trim().ToLowerInvariant()
}

# Сценарии из scenarios.md: раздел «##» — сценарий, строка «когда:» до его списка, пункты
# нумерованного списка — ссылки на файлы этапов, строки «- возврат:» с отступом под пунктом —
# его возвраты. Любая другая непустая строка под пунктом уходит в strays сценария: возврат
# с опечаткой, без дефиса или без отступа иначе пропал бы молча. Разбор без находок: его берут
# и сверка флоу, и сверка памяти задачи, которая сводит свою строку «сценарий:» со списком.
function Get-KitFlowList([string]$Base) {
    $flows = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in ((Read-KitMarkdown (Join-Path $Base $script:KitScenariosFile)) -split '\r?\n')) {
        $heading = [regex]::Match($line, '^##\s+(.+?)\s*$')
        if ($heading.Success) {
            $current = [pscustomobject]@{
                name = $heading.Groups[1].Value
                when = $null
                items = [System.Collections.Generic.List[object]]::new()
                strays = [System.Collections.Generic.List[object]]::new()
            }
            $flows.Add($current)
            continue
        }
        if (-not $current) { continue }
        $when = [regex]::Match($line, '^\s*когда\s*:\s*(.*?)\s*$')
        if ($when.Success -and -not $current.items.Count -and $null -eq $current.when) {
            $current.when = $when.Groups[1].Value
            continue
        }
        $item = [regex]::Match($line, '^\s*(\d+)\.\s+(.*?)\s*$')
        if (-not $item.Success) {
            if (-not $current.items.Count -or -not $line.Trim()) { continue }
            $owner = $current.items[$current.items.Count - 1]
            $return = [regex]::Match($line, '^\s+-\s+возврат\s*:\s*(.*?)\s*$')
            if ($return.Success) { $owner.returns.Add($return.Groups[1].Value) }
            else { $current.strays.Add([pscustomobject]@{ number = $owner.number; text = $line.Trim() }) }
            continue
        }
        $link = [regex]::Match($item.Groups[2].Value, "^\[([^\]]+)\]\(\s*$($script:KitStagesDir)/([^/\\)\s]+\.md)\s*\)$")
        $current.items.Add([pscustomobject]@{
            number = [int]$item.Groups[1].Value
            text = $item.Groups[2].Value
            title = $(if ($link.Success) { $link.Groups[1].Value } else { $null })
            file = $(if ($link.Success) { $link.Groups[2].Value } else { $null })
            returns = [System.Collections.Generic.List[string]]::new()
        })
    }
    return $flows
}

# Файл этапа: заголовок «#» — название, под ним подряд пары «ключ: значение», после пустой
# строки — описание. Нумерованный пункт описания ключом не считается, даже если в нём двоеточие.
function Read-KitStage([string]$Path, [string]$File) {
    $stage = [pscustomobject]@{
        file = $File
        label = "$($script:KitFlowDir)/$($script:KitStagesDir)/$File"
        name = $null
        keys = [ordered]@{}
        body = [System.Collections.Generic.List[string]]::new()
    }
    $inKeys = $false
    foreach ($line in ((Read-KitMarkdown $Path) -split '\r?\n')) {
        if (-not $stage.name) {
            $heading = [regex]::Match($line, '^#\s+(.+?)\s*$')
            if ($heading.Success) { $stage.name = $heading.Groups[1].Value; $inKeys = $true }
            continue
        }
        if (-not $line.Trim()) {
            if ($stage.keys.Count) { $inKeys = $false }
            continue
        }
        if ($inKeys -and $line -notmatch '^\s*\d+(\.\d+)*\.\s') {
            $pair = [regex]::Match($line, '^([^\s:][^:]*?)\s*:\s*(.*?)\s*$')
            if ($pair.Success) {
                $stage.keys[$pair.Groups[1].Value] = $pair.Groups[2].Value
                continue
            }
        }
        $inKeys = $false
        $stage.body.Add($line)
    }
    return $stage
}

# Флоу: то, что не даст пройти этап однозначно, — нет обязательного ключа, чужой ключ,
# невидимый исполнитель или помощник, помощники не у оркестратора, пункт сценария не ведёт
# в файл этапа или называет его не его заголовком, этап дважды в одном сценарии, ссылка
# номером или на название, которого нет, два этапа с одним названием, строка под пунктом
# сценария, которая не возврат, возврат без условия, без названия в кавычках, на этап, которого
# нет, и возврат, который в своём сценарии ведёт мимо или не назад. Длину сценария сверка
# не проверяет; отсутствие scenarios.md назвала сверка каркаса.
function Get-KitFlowFindings([string]$Base, [string]$Worktree, $Rules) {
    if (-not (Test-Path -LiteralPath (Join-Path $Base $script:KitScenariosFile) -PathType Leaf)) { return }
    if (-not $Rules.flowKeys.Contains('исполнитель') -or -not $Rules.executors.Count) {
        New-KitFinding 'FAIL' $script:KitScenariosFile 'перечень ключей этапа не разобран — таблица в разделе «Этап» flow-stages.md кита'
        return
    }

    # Адрес этапа — название: номер съезжает вслед за перестановкой этапов, а описание
    # остаётся связным и ведёт в чужой этап молча. Отсюда и запрет одинаковых названий.
    $stages = [ordered]@{}
    $names = @{}
    $dir = Join-Path (Join-Path $Base $script:KitFlowDir) $script:KitStagesDir
    foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $label = "$($script:KitFlowDir)/$($script:KitStagesDir)/$($item.Name)"
        if ($item.PSIsContainer) { New-KitFinding 'WARN' $label "подкаталог в $($script:KitStagesDir)/ — этапы лежат плоско, файлом на этап"; continue }
        if ($item.Extension -ine '.md') { New-KitFinding 'WARN' $label "не .md в $($script:KitStagesDir)/ — каталог держит только этапы"; continue }
        $stage = Read-KitStage $item.FullName $item.Name
        $stages[$item.Name.ToLowerInvariant()] = $stage
        if (-not $stage.name) { New-KitFinding 'FAIL' $label 'нет заголовка «# <название этапа>» — по нему этап называют сценарии, память и ссылки'; continue }
        $key = ConvertTo-KitTitleKey $stage.name
        if ($names.ContainsKey($key)) {
            New-KitFinding 'FAIL' $label "название «$($stage.name)» уже у $($names[$key].label) — ссылка на такой этап неоднозначна"
            continue
        }
        $names[$key] = $stage
    }

    # Место этапа в каждом сценарии: файл этапа — его индекс в списке.
    $flows = @(Get-KitFlowList $Base)
    if (-not $flows.Count) {
        New-KitFinding 'WARN' $script:KitScenariosFile 'сценариев нет — написать с оператором хотя бы один этап и один сценарий скиллом /flow'
    }
    $orders = @()
    $flowNames = @{}
    foreach ($flow in $flows) {
        $at = "сценарий «$($flow.name)»"
        $flowKey = ConvertTo-KitTitleKey $flow.name
        if ($flowNames.ContainsKey($flowKey)) { New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: имя уже у другого сценария — развести имена" }
        $flowNames[$flowKey] = $true
        if (-not $flow.items.Count) {
            New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: ни одного этапа — дописать список или убрать заголовок «##»"
        }
        if ($flows.Count -gt 1 -and -not $flow.when) {
            New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: нет строки «когда:» или она пуста — написать, каким задачам этот сценарий"
        }

        $order = [ordered]@{}
        $previous = 0
        foreach ($i in $flow.items) {
            if ($i.number -ne $previous + 1) {
                New-KitFinding 'WARN' $script:KitScenariosFile "${at}: пункт $($i.number) после пункта $previous — этапы нумеруются подряд с 1"
            }
            $previous = $i.number
            if (-not $i.file) {
                New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: пункт $($i.number) «$($i.text)» — не ссылка на $($script:KitStagesDir)/<файл>.md"
                continue
            }
            $fileKey = $i.file.ToLowerInvariant()
            if (-not $stages.Contains($fileKey)) {
                New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: пункт $($i.number) ведёт на $($script:KitStagesDir)/$($i.file) — такого файла нет"
                continue
            }
            $stage = $stages[$fileKey]
            if ($stage.name -and (ConvertTo-KitTitleKey $i.title) -ne (ConvertTo-KitTitleKey $stage.name)) {
                New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: пункт $($i.number) «$($i.title)», а заголовок $($stage.label) — «$($stage.name)»"
            }
            if ($order.Contains($fileKey)) {
                New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: этап $($stage.label) стоит дважды"
                continue
            }
            $order[$fileKey] = $order.Count
        }
        $orders += [pscustomobject]@{ name = $flow.name; order = $order }

        foreach ($stray in $flow.strays) {
            New-KitFinding 'FAIL' $script:KitScenariosFile "${at}: пункт $($stray.number) — строка «$($stray.text)» не возврат; под пунктом этапа стоят только строки «- возврат:»"
        }
        # Направление — по месту в этом сценарии: список собран целиком, и цель, стоящая ниже
        # пункта, уже в $order.
        foreach ($i in $flow.items) {
            foreach ($return in $i.returns) {
                $head = "${at}: пункт $($i.number)"
                $numbered = [regex]::Matches($return, '(?i)\bэтап[а-яё]*\s+(\d+)')
                foreach ($ref in $numbered) {
                    New-KitFinding 'FAIL' $script:KitScenariosFile "${head}: возврат «$($ref.Value)» — на этап ссылаются названием в кавычках"
                }
                $target = [regex]::Match($return, '(?i)\bэтап[а-яё]*\s+«([^»]+)»')
                if (-not $target.Success) {
                    if (-not $numbered.Count) {
                        New-KitFinding 'FAIL' $script:KitScenariosFile "${head}: возврат «$return» — назад адресуются словом «этап» и названием в кавычках"
                    }
                    continue
                }
                $targetName = $target.Groups[1].Value
                if (-not $return.Substring(0, $target.Index).Trim([char[]]' —-:,')) {
                    New-KitFinding 'FAIL' $script:KitScenariosFile "${head}: возврат к этапу «$targetName» без условия"
                }
                $targetStage = $names[(ConvertTo-KitTitleKey $targetName)]
                if (-not $targetStage) {
                    New-KitFinding 'FAIL' $script:KitScenariosFile "${head}: возврат к этапу «$targetName» — такого этапа нет"
                    continue
                }
                $targetKey = $targetStage.file.ToLowerInvariant()
                if (-not $order.Contains($targetKey)) {
                    New-KitFinding 'FAIL' $script:KitScenariosFile "${head}: возврат к этапу «$targetName» — в этом сценарии его нет"
                    continue
                }
                $fromKey = $(if ($i.file) { $i.file.ToLowerInvariant() } else { $null })
                if ($fromKey -and $order.Contains($fromKey) -and $order[$targetKey] -ge $order[$fromKey]) {
                    New-KitFinding 'FAIL' $script:KitScenariosFile "${head}: возврат к этапу «$targetName» — он стоит не раньше: сценарий вперёд не прыгает"
                }
            }
        }
    }

    $agents = $null
    foreach ($stage in $stages.Values) {
        if (-not $stage.name) { continue }
        $label = $stage.label
        $fileKey = $stage.file.ToLowerInvariant()
        $in = @($orders | Where-Object { $_.order.Contains($fileKey) })
        if ($flows.Count -and -not $in.Count) { New-KitFinding 'WARN' $label 'этап не входит ни в один сценарий' }

        foreach ($key in $stage.keys.Keys) {
            if (-not $Rules.flowKeys.Contains($key)) {
                New-KitFinding 'FAIL' $label "ключ «$key» вне перечня — своих ключей не заводят"
            }
        }
        foreach ($key in $Rules.flowKeys.Keys) {
            if (-not $Rules.flowKeys[$key]) { continue }
            if (-not $stage.keys.Contains($key)) { New-KitFinding 'FAIL' $label "нет ключа «$key»" }
            elseif (-not $stage.keys[$key]) { New-KitFinding 'FAIL' $label "ключ «$key» пуст" }
        }

        foreach ($line in $stage.body) {
            foreach ($ref in [regex]::Matches($line, '(?i)\bэтап[а-яё]*\s+(\d+)')) {
                New-KitFinding 'FAIL' $label "ссылка «$($ref.Value)» — на этап ссылаются названием в кавычках"
            }
            foreach ($ref in [regex]::Matches($line, '(?i)\bэтап[а-яё]*\s+«([^»]+)»')) {
                $name = $ref.Groups[1].Value
                $target = $names[(ConvertTo-KitTitleKey $name)]
                if (-not $target) {
                    New-KitFinding 'FAIL' $label "ссылка на этап «$name» — такого этапа нет"
                    continue
                }
                foreach ($flow in $in) {
                    if (-not $flow.order.Contains($target.file.ToLowerInvariant())) {
                        New-KitFinding 'WARN' $label "ссылка на этап «$name» — его нет в сценарии «$($flow.name)», где стоит этот этап"
                    }
                }
            }
        }

        # Помощники — кусок работы оркестратора, отданный субагенту: этапу, чью работу делает
        # не он, звать помощников некому.
        $executor = $stage.keys['исполнитель']
        $helpers = @(($stage.keys['помощники'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($helpers.Count -and $executor -and $executor -ne 'оркестратор') {
            New-KitFinding 'FAIL' $label "ключ «помощники» — зовёт их оркестратор, а работу этапа делает «$executor»"
        }
        foreach ($helper in $helpers) {
            if ($null -eq $agents) { $agents = Get-KitVisibleAgents $Worktree }
            if (-not $agents.ContainsKey($helper)) {
                New-KitFinding 'WARN' $label "помощника «$helper» не видно — может прийти из плагина; нет его — вопрос оператору"
            }
        }

        if (-not $executor -or $Rules.executors -contains $executor) { continue }
        if ($null -eq $agents) { $agents = Get-KitVisibleAgents $Worktree }
        if (-not $agents.ContainsKey($executor)) {
            New-KitFinding 'WARN' $label "субагента «$executor» не видно — может прийти из плагина; нет его — вопрос оператору"
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
    Get-KitAgentFindings $Base $Worktree
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
    $flowTouched = $false
    foreach ($file in @($Files | Where-Object { $_ })) {
        $path = ConvertTo-KitPath $file
        if (-not $path.StartsWith($Base + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($seen.ContainsKey($path.ToLowerInvariant())) { continue }
        $seen[$path.ToLowerInvariant()] = $true
        $rel = Get-KitRelativePath $Base $path
        # Удалённый этап ломает сценарий, который на него ссылается, поэтому сверку флоу
        # запускает и удаление.
        if ($rel -match "^$($script:KitFlowDir)\\") { $flowTouched = $true }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        if ($rel -match '^local\\') {
            New-KitFinding 'FAIL' $rel 'файл из local/ в коммите — значения кредов в git базы не попадают'
            continue
        }
        if ($rel -notmatch '\\' -and $rel -match '\.md$') {
            if ($script:KitServedFiles -contains $rel) { Get-KitKnowledgeCeilingFindings $path $rel $rules }
            elseif ($rel -ieq 'backlog.md') { Get-KitBacklogFindings $path $rel $rules }
        }
        elseif ($rel -match "^$($script:KitDecisionsDir)\\[^\\]+\.md$") {
            Get-KitDecisionFileFindings $path $rel $rules
        }
        elseif ($rel -match '^work\\[^\\]+\.md$') {
            # Взятая запись ловится со стороны своей памяти: это коммит взятия. Со стороны
            # бэклога её не ищут — вырезать чужую запись коммит бэклога всё равно не может.
            if ($own -and $path -ieq $own) {
                Get-KitOwnMemoryFindings $Base $path $rel $Worktree $rules
                Get-KitAnsweredQuestionFindings $path $rel
                Get-KitStepFindings $Base $path $rel
                Get-KitTakenRecordFindings $Base $path $rel $Worktree
            }
            else { New-KitFinding 'FAIL' $rel 'память другой рабочей копии в коммите — не своя, решает оператор' }
        }
        Find-KitSecrets $path $rel
    }
    if ($flowTouched) { Get-KitFlowFindings $Base $Worktree $rules }
}
