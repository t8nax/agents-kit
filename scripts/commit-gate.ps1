# agents-kit: хук PreToolUse — пускать ли этот коммит в базу знаний.
#
# Что в базе не так, определяет base-check.ps1; здесь только разбор команды и перевод
# находок в решение: FAIL — коммит не идёт, похожее на секрет — решает оператор,
# остальное — молчание. Что именно сверяется при коммите, почему гейт — хук Claude Code,
# а не git, и почему неразобранная команда пропускается — CLAUDE.md.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

function Emit([string]$Decision, [string]$Reason) {
    $payload = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $Decision
            permissionDecisionReason = $Reason
        }
    }
    $payload | ConvertTo-Json -Depth 5 -Compress
}

# Команда режется на звенья по && || ; | и переводу строки, звено — на слова.
# Кавычки снимаются; обратная косая черта не экранирует, иначе пути Windows в кавычках
# разваливались бы.
function Split-KitCommand([string]$Command) {
    $segments = @()
    $words = @()
    $word = ''
    $has = $false
    $quote = [char]0
    for ($i = 0; $i -lt $Command.Length; $i++) {
        $ch = $Command[$i]
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 } else { $word += $ch }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; $has = $true; continue }
        $separator = $ch -in @(';', '|', "`n", "`r") -or ($ch -eq '&' -and $i + 1 -lt $Command.Length -and $Command[$i + 1] -eq '&')
        if ($separator -or [char]::IsWhiteSpace($ch)) {
            if ($has) { $words += $word; $word = ''; $has = $false }
            if ($separator) {
                if ($words) { $segments += , $words }
                $words = @()
                if ($ch -eq '&') { $i++ }
            }
            continue
        }
        $word += $ch
        $has = $true
    }
    if ($has) { $words += $word }
    if ($words) { $segments += , $words }
    return , $segments
}

# Путь из команды: относительный — от текущего каталога звена; вид /d/… из Git Bash
# приводится к D:\….
function Resolve-KitCommandPath([string]$Path, [string]$Dir) {
    if ($Path -match '^/([a-zA-Z])(/|$)(.*)$') { $Path = "$($Matches[1]):\$($Matches[3])" }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Dir $Path }
    return ConvertTo-KitPath $Path
}

# Разбор git-вызова. Возвращает $null, если это не commit, иначе каталог и что коммитится.
function Get-KitCommitCall([string[]]$Words, [string]$Dir) {
    $i = 1
    while ($i -lt $Words.Count) {
        $w = $Words[$i]
        if ($w -eq '-C' -and $i + 1 -lt $Words.Count) { $Dir = Resolve-KitCommandPath $Words[$i + 1] $Dir; $i += 2; continue }
        if ($w -in @('-c', '--git-dir', '--work-tree', '--namespace')) { $i += 2; continue }
        if ($w.StartsWith('-')) { $i++; continue }
        break
    }
    if ($i -ge $Words.Count -or $Words[$i] -ne 'commit') { return $null }

    $call = [ordered]@{ dir = $Dir; all = $false; include = $false; specs = @() }
    $afterDashes = $false
    for ($j = $i + 1; $j -lt $Words.Count; $j++) {
        $w = $Words[$j]
        if ($afterDashes) { $call.specs += Resolve-KitCommandPath $w $Dir; continue }
        if ($w -eq '--') { $afterDashes = $true; continue }
        if ($w -eq '--all') { $call.all = $true; continue }
        if ($w -in @('--include', '-i')) { $call.include = $true; continue }
        # Склейка коротких флагов: -am — это -a и -m; буква после флага со значением
        # принадлежит уже значению.
        if ($w -match '^-[A-Za-z]+$') {
            $a = $w.IndexOf('a')
            $valued = $w.IndexOfAny([char[]]'mFCct')
            if ($a -gt 0 -and ($valued -lt 0 -or $a -lt $valued)) { $call.all = $true }
        }
    }
    return [pscustomobject]$call
}

function Get-KitGitNames([string]$Top, [string[]]$GitArgs) {
    return @(& git -C $Top @GitArgs 2>$null | Where-Object { $_ } | ForEach-Object { ConvertTo-KitPath (Join-Path $Top $_) })
}

# Что уйдёт в коммит. С путями после -- git коммитит только их, без --include
# проиндексированное сверх них не уходит; без путей — индекс, а с -a ещё и изменённое.
function Get-KitCommitFiles($Call, [string]$Top) {
    $files = @()
    foreach ($spec in $Call.specs) {
        if (Test-Path -LiteralPath $spec -PathType Container) {
            $files += Get-KitGitNames $Top @('ls-files', '--cached', '--others', '--exclude-standard', '--', $spec)
        }
        else { $files += $spec }
    }
    if (-not $Call.specs.Count -or $Call.include) {
        $files += Get-KitGitNames $Top @('diff', '--cached', '--name-only')
        if ($Call.all) { $files += Get-KitGitNames $Top @('diff', '--name-only') }
    }
    return $files
}

try {
    . (Join-Path $PSScriptRoot 'link-state.ps1')
    . (Join-Path $PSScriptRoot 'base-check.ps1')

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = ConvertFrom-Json $raw
    $command = [string]$payload.tool_input.command
    $cwd = [string]$payload.cwd
    if (-not $command -or $command -notmatch '\bcommit\b') { exit 0 }
    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }

    $state = Get-KitLinkState $cwd
    if ($state.status -ne 'Linked') { exit 0 }
    $worktree = Get-KitWorktree $cwd

    $findings = @()
    $dir = ConvertTo-KitPath $cwd
    foreach ($words in (Split-KitCommand $command)) {
        $words = @($words | Where-Object { $_ -ne '&' })
        if (-not $words.Count) { continue }
        $head = Split-Path $words[0] -Leaf

        if ($head -in @('cd', 'Set-Location', 'sl', 'pushd', 'Push-Location')) {
            $target = $words | Select-Object -Skip 1 | Where-Object { -not $_.StartsWith('-') } | Select-Object -First 1
            if ($target) { $dir = Resolve-KitCommandPath $target $dir }
            continue
        }
        if ($head -notin @('git', 'git.exe')) { continue }

        $call = Get-KitCommitCall $words $dir
        if (-not $call) { continue }
        $top = Invoke-KitGit $call.dir @('rev-parse', '--show-toplevel')
        if (-not $top -or (ConvertTo-KitPath $top) -ine $state.base) { continue }

        $files = Get-KitCommitFiles $call $state.base
        $findings += @(Get-KitCommitFindings $state.base $worktree $files)
    }

    # Прочие WARN коммит не останавливают и оператора не дёргают: их назовёт сверка на
    # старте. Оператору несётся только подозрение на секрет — его последствия необратимы.
    $fails = @($findings | Where-Object { $_.severity -eq 'FAIL' })
    $secrets = @($findings | Where-Object { $_.kind -eq 'secret' })
    if ($fails.Count) {
        $lines = @($fails) + @($secrets) | ForEach-Object { "- $($_.severity) ``$($_.file)`` — $($_.message)" }
        Emit 'deny' @"
agents-kit: коммит в базу знаний остановлен сверкой.

$($lines -join "`n")

Починить названное и повторить коммит. Помеченное «решает оператор» не трогать, а назвать вопросом оператору.
"@
    }
    elseif ($secrets.Count) {
        $lines = $secrets | ForEach-Object { "- ``$($_.file)`` — $($_.message)" }
        Emit 'ask' @"
agents-kit: в коммите базы знаний похожее на секрет.

$($lines -join "`n")

Секрет, попавший в историю базы, удалением файла не убрать. Пропустить коммит решает оператор.
"@
    }
}
catch {
    # Молчание безопаснее полуправды; почему ошибка гасится здесь — CLAUDE.md.
}
exit 0
