# agents-kit: что в базе знаний не так — единственный ответ на этот вопрос.
# Дот-сорсится хуками; сами они только переводят находки в свой вывод. Почему
# сверка не раздваивается — CLAUDE.md.
#
# Находка — { severity; file; message; kind }. FAIL — база разошлась с раскладкой,
# WARN — повод перечитать и решить; kind = secret отличает подозрение на секрет,
# которое гейт коммита несёт человеку. Правила раскладки, в том числе числа потолков,
# живут в reference\base-layout.md; здесь их нет ни одним числом.
#
# Две точки входа на два момента:
#   Get-KitBaseFindings    база целиком — то, что расходится само, без всякого коммита
#   Get-KitCommitFindings  файлы коммита и local/ — то, что уедет в историю этим коммитом

. (Join-Path $PSScriptRoot 'link-state.ps1')

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

# Рабочая копия, которую объявляет файл памяти. Опознание памяти держится на этой
# строке, а не на имени файла; почему — CLAUDE.md.
function Get-KitDeclaredWorktree([string]$Text) {
    $m = [regex]::Match($Text, '(?im)^\s*рабочая\s+копия\s*:\s*(.+?)\s*$')
    if (-not $m.Success) { return $null }
    return ConvertTo-KitPath $m.Groups[1].Value
}

# Потолки читаются из раскладки; почему — CLAUDE.md. Разбор, который не сошёлся,
# не молчит: файл без разобранного потолка даёт FAIL, а не проходит непроверенным.
function Get-KitCeilings {
    $result = @{ files = @{}; memory = $null }
    $path = Join-Path $PSScriptRoot '..\reference\base-layout.md'
    try { $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { return $result }

    foreach ($row in [regex]::Matches($text, '(?m)^\|\s*`([^`]+\.md)`\s*\|.*\|\s*([^|]*?)\s*\|\s*$')) {
        $cell = [regex]::Match($row.Groups[2].Value, '^(\d+) строк(?:, раздел — (\d+))?$')
        if (-not $cell.Success) { continue }
        $section = $null
        if ($cell.Groups[2].Success) { $section = [int]$cell.Groups[2].Value }
        $result.files[$row.Groups[1].Value.ToLowerInvariant()] = @{ lines = [int]$cell.Groups[1].Value; section = $section }
    }

    $memory = [regex]::Match($text, '(?m)^Потолок файла — (\d+) строк\.')
    if ($memory.Success) { $result.memory = [int]$memory.Groups[1].Value }
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

# Файлы корня: каркас на месте и не перерос потолки. О файлах сверх каркаса сверка молчит.
function Get-KitRootFindings([string]$Base, $Ceilings) {
    $template = Get-KitTemplateNames
    foreach ($name in $template) {
        if (-not (Test-Path -LiteralPath (Join-Path $Base $name) -PathType Leaf)) {
            New-KitFinding 'WARN' $name 'файла из каркаса нет — довезёт повторный base-init.ps1'
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Base -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.md' })) {
        if ($template -contains $file.Name) {
            Get-KitKnowledgeCeilingFindings $file.FullName $file.Name $Ceilings
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
            New-KitFinding 'FAIL' $Label "объявляет рабочую копию «$declared», а лежит по адресу «$Worktree» — не своя, решает человек"
        }
        return
    }
    if (-not $declared -and -not $SkipIdentity) {
        New-KitFinding 'FAIL' $Label "нет строки «рабочая копия: $Worktree» — без неё хук память не подаёт"
    }

    foreach ($field in 'ветка', 'Критерий закрытия', 'Следующий шаг', 'Человеку') {
        if ($text -notmatch "(?im)^\s*(-\s*)?$([regex]::Escape($field))\s*:") {
            New-KitFinding 'WARN' $Label "нет строки «${field}:» из шаблона памяти"
        }
    }

    if (-not $Ceilings.memory) {
        New-KitFinding 'FAIL' $Label 'потолок памяти не разобран — в раскладке нет строки «Потолок файла — N строк.»'
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
        New-KitFinding 'FAIL' $Label 'не опознаётся: нет строки «рабочая копия» — не своя, решает человек'
        return
    }
    if (-not (Test-Path -LiteralPath $declared -PathType Container)) {
        New-KitFinding 'FAIL' $Label "копии «$declared» нет на диске — задача не закрыта, а вести её некому; не своя, решает человек"
        return
    }
    if ((Get-KitWorkMemoryPath $Base $declared) -ine $Path) {
        New-KitFinding 'FAIL' $Label 'лежит не по адресу объявленной копии — хук её не подаст; не своя, решает человек'
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

function Get-KitBaseFindings([string]$Base, [string]$Worktree) {
    $Base = ConvertTo-KitPath $Base
    $ceilings = Get-KitCeilings

    Get-KitLinkFindings $Base
    Get-KitGitFindings $Base
    Get-KitRootFindings $Base $ceilings
    Get-KitWorkFindings $Base $Worktree $ceilings

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
    $ceilings = Get-KitCeilings
    $template = Get-KitTemplateNames
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
            if ($template -contains $rel) { Get-KitKnowledgeCeilingFindings $path $rel $ceilings }
        }
        elseif ($rel -match '^work\\[^\\]+\.md$') {
            if ($own -and $path -ieq $own) { Get-KitOwnMemoryFindings $path $rel $Worktree $ceilings }
            else { New-KitFinding 'FAIL' $rel 'память другой рабочей копии в коммите — её коммитит сессия той копии; не своя, решает человек' }
        }
        Find-KitSecrets $path $rel
    }
}
