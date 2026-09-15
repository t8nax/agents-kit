# agents-kit: что в базе знаний не так — единственный ответ на этот вопрос.
# Дот-сорсится хуками; сами они только переводят находки в свой вывод. Почему
# сверка не раздваивается — CLAUDE.md.
#
# Находка — { severity; file; message; kind }. FAIL — база разошлась с правилами кита,
# WARN — повод перечитать и решить; kind = secret отличает подозрение на секрет,
# которое гейт коммита несёт оператору. Сверяются и флоу — запись его шагов, — и файлы
# решений, и форма вопроса оператору в памяти; оглавление решений для подачи и разбор
# вопросов для ожидания ответа собираются здесь же. Правила файлов базы, в том числе
# потолки и ключи шага флоу, живут в reference\base-layout.md, а памяти задачи и вопроса
# оператору — в reference\task-memory.md; здесь нет ни чисел, ни перечня.
#
# Две точки входа на два момента:
#   Get-KitBaseFindings    база целиком — то, что расходится само, без всякого коммита
#   Get-KitCommitFindings  файлы коммита и local/ — то, что уедет в историю этим коммитом

. (Join-Path $PSScriptRoot 'link-state.ps1')

# Файлы базы, которые хук подаёт сессии содержимым, — два названных, а не корень базы;
# решения из decisions/ подаются оглавлением. Почему — CLAUDE.md. Потолок файла знания —
# цена подачи, поэтому среди файлов корня он проверяется у них и только у них; у файла
# решений и у памяти задачи потолки свои.
$script:KitServedFiles = @('product.md', 'boundaries.md')
$script:KitDecisionsDir = 'decisions'

function New-KitFinding([string]$Severity, [string]$File, [string]$Message, [string]$Kind = '') {
    return [pscustomobject]@{ severity = $Severity; file = $File; message = $Message; kind = $Kind }
}

# Файл базы, как его видит сессия: и подача хука, и потолок сверки берут этот текст.
#
# Комментарий до сессии не доходит — иначе закомментированный пример из шаблона приехал
# бы в контекст как факт проекта. Нечитаемый файл — пустая строка, а не исключение:
# уронив подачу целиком, хук оставил бы сессию без базы, а молчание в ветке Linked
# неотличимо от «репозиторий не под китом».
function Read-KitMarkdown([string]$Path) {
    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return '' }
    if (-not $text) { return '' }
    return ([regex]::Replace($text, '(?s)<!--.*?-->', '')).Trim()
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

# Оглавление решений: и подача хука, и сверка берут его отсюда. Файл без строки
# «когда:» в оглавление не попадает — его называет сверка.
function Get-KitDecisionIndex([string]$Base) {
    $dir = Join-Path $Base $script:KitDecisionsDir
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $when = Get-KitDecisionReadWhen (Read-KitMarkdown $file.FullName)
        if (-not $when) { continue }
        [pscustomobject]@{ file = "$($script:KitDecisionsDir)/$($file.Name)"; when = $when }
    }
}

# Рабочая копия, которую объявляет файл памяти. Опознание памяти держится на этой
# строке, а не на имени файла; почему — CLAUDE.md.
function Get-KitDeclaredWorktree([string]$Text) {
    $m = [regex]::Match($Text, '(?im)^\s*рабочая\s+копия\s*:\s*(.+?)\s*$')
    if (-not $m.Success) { return $null }
    return ConvertTo-KitPath $m.Groups[1].Value
}

# Раздел справки кита — от заголовка до следующего заголовка того же уровня или выше.
# Заголовок внутри блока кода разделом не считается: пример шага флоу начинается с «##».
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

# Вопросы оператору в памяти. Вопрос — подраздел «###» раздела «## Оператору», до следующего
# заголовка; вне этого раздела «###» вопросом не считается. Строки блока: проза до первой
# строки ключа — контекст; строка ключа — «- ключ: значение» или «ответ: значение» без
# маркера. Отвеченным вопрос считается по непустому ответу где угодно в блоке — форму блока
# называет сверка, а ожидание отпускает сессию и на вопросе, записанном не по форме.
#
# Вопрос — { text; context — строки контекста; lines — строки после контекста { key; value;
# raw }, key пуст у прозы; answered }.
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

# Потолки и ключи читаются из справок кита; почему — CLAUDE.md. Разбор, который не
# сошёлся, не молчит: файл без разобранного правила даёт FAIL, а не проходит непроверенным.
function Get-KitLayoutRules {
    $result = @{ files = @{}; memory = $null; decision = $null; flowKeys = [ordered]@{}; executors = @(); questionKeys = [ordered]@{} }

    # Таблица ключей — единственная в своём разделе с колонкой «да/нет»: у шага флоу —
    # в «Флоу проекта» раскладки, у вопроса оператору — в «Вопрос оператору и ответ» памяти.
    $memoryText = Read-KitReference 'task-memory.md'
    foreach ($row in Get-KitKeyRows (Get-KitLayoutSection $memoryText '## Вопрос оператору и ответ')) {
        $result.questionKeys[$row.Groups[1].Value] = ($row.Groups[3].Value -eq 'да')
    }
    $memory = [regex]::Match($memoryText, '(?m)^Потолок файла — (\d+) строк\.')
    if ($memory.Success) { $result.memory = [int]$memory.Groups[1].Value }

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
        $cell = [regex]::Match($row.Groups[2].Value, '^(\d+) строк(?:, раздел — (\d+))?$')
        if (-not $cell.Success) { continue }
        $section = $null
        if ($cell.Groups[2].Success) { $section = [int]$cell.Groups[2].Value }
        $result.files[$row.Groups[1].Value.ToLowerInvariant()] = @{ lines = [int]$cell.Groups[1].Value; section = $section }
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
                New-KitFinding 'WARN' "${Label}:$($i + 1)" 'похоже на секрет — значение живёт там, где его читает код, а в базе только в local/' 'secret'
                break
            }
        }
    }
}

# Сторона базы у связи. Хук сверяет связь от копии; висящую запись в списке оттуда
# не видно — копии, от которой смотреть, больше нет.
function Get-KitLinkFindings([string]$Base) {
    $marker = Get-KitMarker $Base
    if (-not $marker) {
        New-KitFinding 'FAIL' 'agents-kit.json' 'файла принадлежности нет или он не читается — это не база кита'
        return
    }
    $list = @($marker.workspaces | Where-Object { $_ } | ForEach-Object { ConvertTo-KitPath $_ })
    if (-not $list.Count) {
        New-KitFinding 'FAIL' 'agents-kit.json' 'база не числит ни одной рабочей копии — связывает link.ps1'
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
            New-KitFinding 'FAIL' '.' "база лежит внутри рабочей копии «$ws» — знание в рабочий репозиторий не пишется"
        }

        $state = Get-KitLinkState $ws
        if ($state.status -eq 'NotGit') {
            New-KitFinding 'FAIL' 'agents-kit.json' "«$ws» не git-репозиторий — запись висит"
        }
        elseif ($state.workspace -ine $ws) {
            New-KitFinding 'FAIL' 'agents-kit.json' "«$ws» — не основная копия, а часть «$($state.workspace)»: worktree и подкаталоги в список не пишутся"
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
        New-KitFinding 'FAIL' '.' 'база не под git — знанию некуда коммититься'
        return
    }
    if ((ConvertTo-KitPath $top) -ine $Base) {
        New-KitFinding 'FAIL' '.' "база лежит внутри репозитория «$(ConvertTo-KitPath $top)» — коммит знания уйдёт в него"
        return
    }

    & git -C $Base check-ignore -q 'local/' 2>$null
    if ($LASTEXITCODE -ne 0) {
        New-KitFinding 'FAIL' '.gitignore' 'local/ не игнорируется — значения кредов уедут в историю базы (строка «local/» в .gitignore)'
    }
    $tracked = @(& git -C $Base ls-files -- 'local' 2>$null | Where-Object { $_ })
    if ($tracked.Count) {
        New-KitFinding 'FAIL' $tracked[0] "файлов из local/ под версией: $($tracked.Count) — секрет уже в истории, удалением не лечится: ротировать утёкшее"
    }
}

function Get-KitKnowledgeCeilingFindings([string]$Path, [string]$Label, $Ceilings) {
    $ceiling = $Ceilings.files[$Label.ToLowerInvariant()]
    if (-not $ceiling) {
        New-KitFinding 'FAIL' $Label 'потолок не разобран — в таблице «Куда именно» раскладки нет ячейки вида «N строк» для этого файла'
        return
    }

    $lines = Get-KitServedLines $Path
    if ($lines.Count -gt $ceiling.lines) {
        New-KitFinding 'FAIL' $Label "$($lines.Count) строк при потолке $($ceiling.lines) — перечитать по тесту входа, а не поднимать потолок"
    }
    if (-not $ceiling.section) { return }

    $name = $null
    $count = 0
    foreach ($line in @($lines) + '## ') {
        if ($line -match '^##\s') {
            if ($name -and $count -gt $ceiling.section) {
                New-KitFinding 'FAIL' $Label "раздел «$name»: $count строк при потолке $($ceiling.section) — тема разрослась пересказом, оставить решения"
            }
            $name = ($line -replace '^##\s*', '').Trim()
            $count = 0
            continue
        }
        if ($name -and $line -notmatch '^#') { $count++ }
    }
}

# Файлы корня: каркас на месте, подаваемые не переросли потолки. О файлах сверх каркаса
# сверка молчит.
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
    }
    # Прежняя раскладка держала решения одним файлом. Он больше не подаётся, и молча
    # лежащий, он выглядел бы действующим знанием, которого сессия не видит.
    if (Test-Path -LiteralPath (Join-Path $Base 'decisions.md') -PathType Leaf) {
        New-KitFinding 'WARN' 'decisions.md' 'больше не подаётся — разложить решения по файлам decisions/ и удалить его'
    }
}

function Get-KitDecisionFileFindings([string]$Path, [string]$Label, $Rules) {
    $text = Read-KitMarkdown $Path
    if (-not (Get-KitDecisionReadWhen $text)) {
        New-KitFinding 'FAIL' $Label 'нет строки «когда:» — файла нет в оглавлении, и его не прочтёт никто'
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

# Вопрос оператор читает без сессии, которая его записала, поэтому форма подраздела — не
# пожелание: чего не хватает для ответа, сверка называет красным, и память с таким
# вопросом не коммитится. Перечень в заголовке и ссылки на соседние строки ловятся
# только по словам — это WARN.
function Get-KitQuestionFindings([string]$Text, [string]$Label, $Rules) {
    $questions = @(Get-KitOperatorQuestions $Text)
    if (-not $questions.Count) { return }
    if (-not $Rules.questionKeys.Count) {
        New-KitFinding 'FAIL' $Label 'перечень ключей вопроса не разобран — таблица в разделе «Вопрос оператору и ответ» task-memory.md кита'
        return
    }

    # Контекст — не строка ключа, а абзац под заголовком; из перечня task-memory.md он берёт
    # только обязательность.
    $contextKey = 'контекст'
    foreach ($q in $questions) {
        $head = $q.text
        $short = if ($head.Length -gt 60) { $head.Substring(0, 60) + '…' } else { $head }
        $at = "вопрос «$short»"
        if ($Rules.questionKeys[$contextKey] -and -not $q.context.Count) {
            New-KitFinding 'FAIL' $Label "${at}: нет контекста — абзац сразу под заголовком, без него оператору не на чем ответить"
        }
        foreach ($l in $q.lines) {
            if (-not $l.key) { New-KitFinding 'FAIL' $Label "${at}: строка «$($l.value)» после строк ключей — контекст пишется абзацем сразу под заголовком" }
            elseif ($l.key -eq $contextKey) { New-KitFinding 'FAIL' $Label "${at}: «${contextKey}:» не ключ — контекст пишется абзацем сразу под заголовком" }
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
            New-KitFinding 'FAIL' $Label "${at}: один «вариант:» — выбора нет; вариантов два и больше или ни одного"
        }
        if (@($options | Group-Object -CaseSensitive | Where-Object { $_.Count -gt 1 }).Count) {
            New-KitFinding 'FAIL' $Label "${at}: одинаковые «вариант:» — рекомендацию не к чему привязать"
        }
        # Рекомендованный вариант опознаётся точным совпадением строки, а не сходством:
        # варианты разнятся парой слов, и угаданным оказался бы не тот.
        $recommended = @($q.lines | Where-Object { $_.key -eq 'рекомендовано' })
        if ($recommended.Count -gt 1) { New-KitFinding 'FAIL' $Label "${at}: «рекомендовано:» больше одной" }
        elseif ($recommended.Count -and -not $options.Count) { New-KitFinding 'FAIL' $Label "${at}: «рекомендовано:» без вариантов — рекомендовать нечего" }
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
            New-KitFinding 'WARN' $Label "${at}: ссылка «выше» или «ниже» — оператор опирается только на вопрос и критерии; нужное переписать в контекст"
        }
    }
}

# Опознание своей памяти на старте сессии называет её подача в session-start.ps1,
# и сверка его там не повторяет (-SkipIdentity). В коммите его назвать больше некому.
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
        New-KitFinding 'FAIL' $Label "нет строки «рабочая копия: $Worktree» — без неё хук память не подаёт"
    }

    # Прежний формат держал критерий и вопросы строками списка в шапке. Разбор их больше не
    # видит, и промолчи сверка, вопрос выпал бы из ожидания, а память выглядела бы чистой.
    if ($text -match '(?im)^\s*-\s*(Оператору|Критерий закрытия)\s*:') {
        New-KitFinding 'FAIL' $Label 'память в прежнем формате — критерий и вопросы оператору стали разделами; переписать по шаблону task-memory.md'
    }
    foreach ($field in 'ветка', 'Решения') {
        if ($text -notmatch "(?m)^$([regex]::Escape($field))\s*:") {
            New-KitFinding 'WARN' $Label "нет строки «${field}:» из шаблона памяти"
        }
    }
    foreach ($section in 'Критерии закрытия', 'Условия', 'Оператору', 'Флоу', 'Шаги') {
        if ($text -notmatch "(?m)^##\s+$([regex]::Escape($section))\s*$") {
            New-KitFinding 'WARN' $Label "нет раздела «## $section» из шаблона памяти"
        }
    }

    Get-KitQuestionFindings $text $Label $Ceilings

    if (-not $Ceilings.memory) {
        New-KitFinding 'FAIL' $Label 'потолок памяти не разобран — в task-memory.md кита нет строки «Потолок файла — N строк.»'
        return
    }
    $count = (Get-KitServedLines $Path).Count
    if ($count -gt $Ceilings.memory) {
        New-KitFinding 'FAIL' $Label "$count строк при потолке $($Ceilings.memory) — в памяти лежит то, чему место в базе или в истории"
    }
}

# Память соседней линии сессии не принадлежит, и о живой соседней работе сверка
# молчит. Говорит она только о файле, который не подаст никто: копии больше нет,
# адрес не сходится или файл не опознаётся. Содержимое не подаётся никогда.
function Get-KitForeignMemoryFindings([string]$Base, [string]$Path, [string]$Label) {
    $declared = Get-KitDeclaredWorktree (Read-KitMarkdown $Path)
    if (-not $declared) {
        New-KitFinding 'FAIL' $Label 'не опознаётся: нет строки «рабочая копия» — не своя, решает оператор'
        return
    }
    if (-not (Test-Path -LiteralPath $declared -PathType Container)) {
        New-KitFinding 'FAIL' $Label "копии «$declared» нет на диске — задача не закрыта, а вести её некому; не своя, решает оператор"
        return
    }
    if ((Get-KitWorkMemoryPath $Base $declared) -ine $Path) {
        New-KitFinding 'FAIL' $Label 'лежит не по адресу объявленной копии — хук её не подаст; не своя, решает оператор'
    }
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
    }
}

# Субагенты, которых сверке видно: рабочая копия и пользователь. Субагенты плагинов
# сверке не видны, поэтому ненайденный исполнитель — WARN, а не FAIL.
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

# Описание шага — пункты N.1, N.2 с вложенностью; проза только с отступом под пунктом.
# Форма нужна глазу, а не проходу шага, поэтому нарушение — WARN.
function Get-KitFlowBodyFindings($Step) {
    $n = $Step.number
    $previous = $null
    $outside = $false
    foreach ($line in $Step.body) {
        $item = [regex]::Match($line, '^\s*(\d+(?:\.\d+)+)\.\s+\S')
        if (-not $item.Success) {
            if ($null -eq $previous -or $line -notmatch '^\s') { $outside = $true }
            continue
        }
        $label = $item.Groups[1].Value
        $segments = @($label.Split('.') | ForEach-Object { [int]$_ })
        if ($segments[0] -ne $n) {
            New-KitFinding 'WARN' 'flow.md' "шаг ${n}: пункт «$label» не начинается с номера шага"
            continue
        }
        $path = @($segments | Select-Object -Skip 1)

        $valid = $false
        if ($null -eq $previous) { $valid = ($path.Count -eq 1 -and $path[0] -eq 1) }
        elseif ($path.Count -eq $previous.Count + 1) {
            $valid = ($path[-1] -eq 1) -and ((($path | Select-Object -SkipLast 1) -join '.') -eq ($previous -join '.'))
        }
        elseif ($path.Count -le $previous.Count) {
            $d = $path.Count
            $prefix = if ($d -gt 1) { ($path[0..($d - 2)] -join '.') -eq ($previous[0..($d - 2)] -join '.') } else { $true }
            $valid = $prefix -and $path[$d - 1] -eq $previous[$d - 1] + 1
        }
        if (-not $valid) {
            $after = if ($null -eq $previous) { 'начала описания' } else { "«$n.$($previous -join '.')»" }
            New-KitFinding 'WARN' 'flow.md' "шаг ${n}: пункт «$label» после $after — номера подряд с 1, вложенный начинается с .1"
        }
        $previous = $path
    }
    if ($outside) {
        New-KitFinding 'WARN' 'flow.md' "шаг ${n}: строка вне пункта — описание пишется пунктами $n.1, $n.2; проза — с отступом под пунктом"
    }
}

# Флоу — шаги, которые /drive проходит по порядку. Сверка называет то, что не даст пройти
# шаг однозначно: нет обязательного ключа, чужой ключ, невидимый исполнитель, сбитый
# порядок. Описание шага она проверяет только на форму пунктов, длину флоу — нет. Файла
# нет — это уже назвала сверка каркаса.
function Get-KitFlowFindings([string]$Base, [string]$Worktree, $Rules) {
    $path = Join-Path $Base 'flow.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if (-not $Rules.flowKeys.Contains('исполнитель') -or -not $Rules.executors.Count) {
        New-KitFinding 'FAIL' 'flow.md' 'перечень ключей шага не разобран — таблица в разделе «Флоу проекта» раскладки'
        return
    }

    $steps = @()
    $current = $null
    $inKeys = $false
    foreach ($line in ((Read-KitMarkdown $path) -split '\r?\n')) {
        $heading = [regex]::Match($line, '^##\s+(\d+)\.\s+(.+?)\s*$')
        if ($heading.Success) {
            $current = @{ number = [int]$heading.Groups[1].Value; keys = [ordered]@{}; body = [System.Collections.Generic.List[string]]::new() }
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
            if ($pair.Success) { $current.keys[$pair.Groups[1].Value] = $pair.Groups[2].Value; continue }
        }
        $inKeys = $false
        $current.body.Add($line)
    }

    if (-not $steps.Count) {
        New-KitFinding 'WARN' 'flow.md' 'флоу пуст — /drive не начнёт работу, пока он не написан с оператором'
        return
    }

    $agents = $null
    $previous = 0
    foreach ($step in $steps) {
        $n = $step.number
        if ($n -ne $previous + 1) {
            New-KitFinding 'WARN' 'flow.md' "шаг $n после шага $previous — порядок исполнения — порядок номеров"
        }
        $previous = $n
        Get-KitFlowBodyFindings $step

        foreach ($key in $step.keys.Keys) {
            if (-not $Rules.flowKeys.Contains($key)) {
                New-KitFinding 'FAIL' 'flow.md' "шаг ${n}: ключ «$key» вне перечня — своих ключей не заводят"
            }
        }
        foreach ($key in $Rules.flowKeys.Keys) {
            if (-not $Rules.flowKeys[$key]) { continue }
            if (-not $step.keys.Contains($key)) { New-KitFinding 'FAIL' 'flow.md' "шаг ${n}: нет ключа «$key»" }
            elseif (-not $step.keys[$key]) { New-KitFinding 'FAIL' 'flow.md' "шаг ${n}: ключ «$key» пуст" }
        }

        $executor = $step.keys['исполнитель']
        if (-not $executor -or $Rules.executors -contains $executor) { continue }
        if ($null -eq $agents) { $agents = Get-KitVisibleAgents $Worktree }
        if (-not $agents.ContainsKey($executor)) {
            New-KitFinding 'WARN' 'flow.md' "шаг ${n}: субагента «$executor» не видно — может прийти из плагина; нет его — шаг встанет вопросом оператору"
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
        }
        elseif ($rel -match "^$($script:KitDecisionsDir)\\[^\\]+\.md$") {
            Get-KitDecisionFileFindings $path $rel $rules
        }
        elseif ($rel -match '^work\\[^\\]+\.md$') {
            if ($own -and $path -ieq $own) { Get-KitOwnMemoryFindings $path $rel $Worktree $rules }
            else { New-KitFinding 'FAIL' $rel 'память другой рабочей копии в коммите — её коммитит сессия той копии; не своя, решает оператор' }
        }
        Find-KitSecrets $path $rel
    }
}
