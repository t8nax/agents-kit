# agents-kit: пришёл ли ответ оператора в память этой рабочей копии.
#   pwsh -NoProfile -File scripts\await-answer.ps1 -Memory <файл памяти> [-Worktree <копия>]
#
# Сессия /drive, у которой вся оставшаяся работа ждёт оператора, запускает его в фоне
# последним действием хода: Claude Code будит сессию, когда фоновая команда выходит.
# Хук простаивающую сессию разбудить не может, поэтому ожидание — отдельный процесс.
#
# Выход — одна строка на любом конечном состоянии, и тишины как исхода нет: сломанное
# ожидание, промолчав, выглядело бы как «ответа пока нет». Разбор файла — тот же, что
# у подачи и сверки: Read-KitMarkdown и Get-KitDeclaredWorktree из base-check.ps1.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Memory,
    [string]$Worktree,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# Вопрос — строка «Оператору:» верхнего уровня, кроме «нечего»; ответ — строка
# «ответ:» с отступом под ним. Ответ под вопросом без отступа не ответ: так его пишет
# раскладка, и иначе новый вопрос сессии читался бы ответом на прежний.
function Get-KitOperatorQuestions([string]$Text) {
    $questions = @()
    $current = $null
    foreach ($line in ($Text -split '\r?\n')) {
        $question = [regex]::Match($line, '^-\s*Оператору\s*:\s*(.*?)\s*$')
        if ($question.Success) {
            $current = $null
            if ($question.Groups[1].Value -match '^«?нечего»?$') { continue }
            $current = [pscustomobject]@{ text = $question.Groups[1].Value; answered = $false }
            $questions += $current
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\s+-\s*ответ\s*:\s*\S') { $current.answered = $true; continue }
        if ($line -notmatch '^\s') { $current = $null }
    }
    return $questions
}

try {
    . (Join-Path $PSScriptRoot 'base-check.ps1')

    if (-not $Worktree) { $Worktree = Get-KitWorktree (Get-Location).Path }
    $Worktree = ConvertTo-KitPath $Worktree
    $Memory = ConvertTo-KitPath $Memory

    while ($true) {
        if (-not (Test-Path -LiteralPath $Memory -PathType Leaf)) {
            Write-Output "памяти $Memory нет — задача закрыта или файл удалён; ждать нечего, показать оператору"
            exit 0
        }

        $text = Read-KitMarkdown $Memory
        $declared = Get-KitDeclaredWorktree $text
        if ($declared -and $Worktree -and $declared -ine $Worktree) {
            Write-Output "память $Memory объявляет рабочую копию «$declared», а ждёт «$Worktree» — не своя, решает оператор"
            exit 0
        }

        $questions = @(Get-KitOperatorQuestions $text)
        $answered = @($questions | Where-Object { $_.answered })
        if ($answered.Count) {
            Write-Output "ответ оператора пришёл: $($answered.Count) из $($questions.Count) — перечитать память $Memory и вобрать"
            exit 0
        }
        if (-not $questions.Count) {
            Write-Output "в памяти $Memory нет вопросов оператору — ждать нечего; перечитать память"
            exit 0
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
catch {
    Write-Output "ожидание ответа сломалось: $($_.Exception.Message) — показать оператору"
    exit 1
}
