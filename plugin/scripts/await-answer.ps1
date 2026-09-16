# agents-kit: пришёл ли ответ оператора в память этой рабочей копии.
#   pwsh -NoProfile -File scripts\await-answer.ps1 -Memory <файл памяти> [-Worktree <копия>]
#
# /drive запускает его в фоне, когда вся работа ждёт оператора: Claude Code будит сессию,
# когда фоновая команда выходит. Хук простаивающую сессию не будит. Печатает одну строку на
# любом конечном состоянии: промолчи скрипт на удалённом файле или ошибке, сломанное ожидание
# выглядело бы как «ответа пока нет». Разбор файла — тот же, что у подачи и сверки, из base-check.ps1.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Memory,
    [string]$Worktree,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

try {
    . (Join-Path $PSScriptRoot 'base-check.ps1')

    if (-not $Worktree) { $Worktree = Get-KitMemoryRoot (Get-Location).Path }
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
