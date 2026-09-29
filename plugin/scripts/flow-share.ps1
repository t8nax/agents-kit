# agents-kit: как флоу переходит между личным репозиторием оператора и папками операторов в базе —
# выложить свой флоу для коллег или взять себе выложенный.
#   pwsh -NoProfile -File scripts\flow-share.ps1 -Action Publish [-Path <копия>]
#   pwsh -NoProfile -File scripts\flow-share.ps1 -Action Take -From <имя оператора>
#        [-Scenario <имя>[,<имя>…]] [-Replace] [-Path <копия>]
#
# Publish заменяет свою папку в базе закоммиченным флоу личного репозитория и субагентами,
# которых зовут его этапы, и коммитит базу; отдаёт её сессия. Take копирует выбранные сценарии
# из папки оператора в базе — с их этапами и выложенными субагентами — в личный репозиторий
# и коммитит его. Забрать базу перед Take и довезти субагентов после — дело сессии.
#
# Скрипт коммитит сам, поэтому сам и судит то, что коммитит: гейт видит только его запуск.
# Take без -Replace ничего чужого не перетирает — называет, что заменится, и отказывает.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Publish', 'Take')][string]$Action,
    [string]$From,
    [string[]]$Scenario,
    [switch]$Replace,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'base-check.ps1')

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path
switch ($state.status) {
    'NotGit'    { throw "«$Path» не под git — это не рабочая копия проекта под китом" }
    'NoPointer' { throw "каталог «$($state.workspace)» под китом не числится — сначала взять его под кит скиллом /onboard" }
    'Linked'    { }
    { $_ -in 'Outdated', 'Newer' } { throw (Get-KitFormatProblem $state) }
    'Unmerged'  { throw (Get-KitUnmergedProblem $state) }
    { $_ -in 'Unnamed', 'NoPersonal' } { throw "места оператора на этой машине нет — завести: $(Get-KitOperatorCommand $state.base $state.operator)" }
    default     { throw "связь копии «$($state.workspace)» с базой разорвана — link.ps1 без аргументов покажет, что именно" }
}
$base = $state.base
$personal = $state.personal
$rules = Get-KitLayoutRules
$flowDir = $script:KitFlowDir
$agentsDir = $script:KitAgentsDir

function Invoke-KitGitStrict([string]$Repo, [string[]]$GitArgs, [string]$What) {
    & git -C $Repo @GitArgs 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git не смог $What в «$Repo»" }
}

# Субагенты, которых зовут этапы флоу, лежащего в Root, и которые лежат в agents\ рядом.
function Get-KitCalledAgents([string]$Root, $Stages) {
    $names = [ordered]@{}
    foreach ($stage in $Stages) {
        foreach ($name in @(Get-KitStageAgents $stage $rules)) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $Root $agentsDir) "$name.md") -PathType Leaf) { $names[$name] = $true }
        }
    }
    return @($names.Keys)
}

if ($Action -eq 'Publish') {
    $people = $state.people
    $peopleRel = "people/$($state.operator)"
    Assert-KitCommitted $personal @($flowDir, $agentsDir) 'флоу и субагентах личного репозитория'
    Assert-KitCommitted $base @($peopleRel) "папке оператора $peopleRel"

    $fails = @(Get-KitFlowFindings $base $state.worktree $rules | Where-Object { $_.severity -eq 'FAIL' })
    if ($fails.Count) { throw "во флоу красные находки — выкладывается флоу без них, починить скиллом /flow:`n$(Get-KitFindingLines $fails)" }
    if (-not (Test-Path -LiteralPath (Join-Path $personal $script:KitScenariosFile) -PathType Leaf)) {
        throw "в личном репозитории нет $($script:KitScenariosFile) — выкладывать нечего"
    }

    $stages = Read-KitStages $personal 'local/me/flow'
    $agents = @(Get-KitCalledAgents $personal @($stages.Values))

    # Папка заменяется целиком: подложенное в неё кем-то другим тоже уходит.
    foreach ($item in @(Get-ChildItem -LiteralPath $people -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $people | Out-Null
    Copy-Item -LiteralPath (Join-Path $personal $flowDir) -Destination (Join-Path $people $flowDir) -Recurse -Force
    if ($agents.Count) {
        New-Item -ItemType Directory -Force -Path (Join-Path $people $agentsDir) | Out-Null
        foreach ($name in $agents) {
            Copy-Item -LiteralPath (Join-Path (Join-Path $personal $agentsDir) "$name.md") -Destination (Join-Path (Join-Path $people $agentsDir) "$name.md") -Force
        }
    }

    # Выложенное уходит в общий remote: похожее на секрет не коммитится, и откат возвращает
    # папку к закоммиченной.
    $secrets = @(Get-ChildItem -LiteralPath $people -File -Recurse -Force | ForEach-Object {
            $full = ConvertTo-KitPath $_.FullName
            Find-KitSecrets $full (Get-KitRelativePath $base $full)
        })
    if ($secrets.Count) {
        & git -C $base restore --source=HEAD --staged --worktree -- $peopleRel 2>$null | Out-Null
        & git -C $base clean -fdq -- $peopleRel 2>$null | Out-Null
        throw "в выкладываемом похожее на секрет — ничего не выложено; решает оператор:`n$(Get-KitFindingLines $secrets)"
    }

    Invoke-KitGitStrict $base @('add', '--', $peopleRel) 'добавить выложенное'
    & git -C $base diff --cached --quiet -- $peopleRel 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Выложенное в $peopleRel не изменилось — коммитить нечего."
        exit 0
    }
    Invoke-KitGitStrict $base @('commit', '-q', '-m', "agents-kit: флоу $($state.operator) выложен для коллег", '--', $peopleRel) 'закоммитить выложенное'

    $flows = @(Get-KitFlowList $base)
    Write-Host "Выложено в ${peopleRel}:"
    Write-Host "  сценарии: $(if ($flows.Count) { ($flows | ForEach-Object { "«$($_.name)»" }) -join ', ' } else { 'нет' })"
    Write-Host "  этапов: $($stages.Count)"
    Write-Host "  субагенты: $(if ($agents.Count) { $agents -join ', ' } else { 'нет' })"
    Write-Host "Отдать базу: $(Get-KitSyncCommand $state.worktree 'Base' 'Push')"
    exit 0
}

# Take.
if (-not (Test-KitOperatorName $From)) { throw "-From: имя оператора «$From» не по форме — латиница в нижнем регистре, цифры и дефис между ними" }
$source = Get-KitOperatorDir $base $From
$sourceLabel = "people/$From"
$sourceScenarios = Join-Path $source $script:KitScenariosFile
if (-not (Test-Path -LiteralPath $sourceScenarios -PathType Leaf)) { throw "у $From ничего не выложено: $sourceLabel/$($script:KitScenariosFile) нет — забрать базу или спросить $From" }
Assert-KitCommitted $personal @($flowDir, $agentsDir) 'флоу и субагентах личного репозитория'

$sourceFlows = @(Read-KitFlowList $sourceScenarios)
if (-not $sourceFlows.Count) { throw "в выложенном флоу $From сценариев нет" }
$chosen = @($sourceFlows)
if ($Scenario) {
    $chosen = @()
    foreach ($name in $Scenario) {
        $flow = @($sourceFlows | Where-Object { (ConvertTo-KitTitleKey $_.name) -eq (ConvertTo-KitTitleKey $name) })
        if (-not $flow.Count) { throw "сценария «$name» у $From нет; есть: $(($sourceFlows | ForEach-Object { "«$($_.name)»" }) -join ', ')" }
        $chosen += $flow[0]
    }
}

$sourceStages = Read-KitStages $source "$sourceLabel/flow"
$takenStages = [ordered]@{}
foreach ($flow in $chosen) {
    foreach ($item in $flow.items) {
        if (-not $item.file) { throw "сценарий «$($flow.name)» у ${From}: пункт $($item.number) — не ссылка на этап; брать нечего, пока $From не поправит" }
        $key = $item.file.ToLowerInvariant()
        if (-not $sourceStages.Contains($key)) { throw "сценарий «$($flow.name)» у ${From}: этапа stages/$($item.file) нет в выложенном" }
        $takenStages[$key] = $sourceStages[$key]
    }
}
$takenAgents = @(Get-KitCalledAgents $source @($takenStages.Values))
$missingAgents = @(@($takenStages.Values) | ForEach-Object { Get-KitStageAgents $_ $rules } | Select-Object -Unique | Where-Object { $takenAgents -notcontains $_ })

# Что заменится у оператора. Одинаковое заменой не считается.
$ownScenarios = Join-Path $personal $script:KitScenariosFile
$ownFlows = @(Get-KitFlowList $base)
$ownStages = Read-KitStages $personal 'local/me/flow'
$conflicts = [System.Collections.Generic.List[string]]::new()
$blockers = [System.Collections.Generic.List[string]]::new()
foreach ($flow in $chosen) {
    $same = @($ownFlows | Where-Object { (ConvertTo-KitTitleKey $_.name) -eq (ConvertTo-KitTitleKey $flow.name) })
    if ($same.Count -and (Join-KitSection $same[0].lines) -cne (Join-KitSection $flow.lines)) {
        $conflicts.Add("сценарий «$($flow.name)» уже есть и другой — заменится")
    }
}
foreach ($key in $takenStages.Keys) {
    $stage = $takenStages[$key]
    $own = Join-Path (Join-Path (Join-Path $personal $flowDir) $script:KitStagesDir) $stage.file
    if (Test-Path -LiteralPath $own -PathType Leaf) {
        if ((Get-KitAgentText $own) -cne (Get-KitAgentText (Join-Path (Join-Path (Join-Path $source $flowDir) $script:KitStagesDir) $stage.file))) {
            $users = @($ownFlows | Where-Object { @($_.items | Where-Object { $_.file -and $_.file.ToLowerInvariant() -eq $key }).Count } | ForEach-Object { "«$($_.name)»" })
            $in = ''
            if ($users.Count) { $in = " и сменится в ваших сценариях $($users -join ', ')" }
            $conflicts.Add("этап stages/$($stage.file) уже есть и другой — заменится$in")
        }
        continue
    }
    if (-not $stage.name) { continue }
    $twin = @($ownStages.Values | Where-Object { $_.name -and (ConvertTo-KitTitleKey $_.name) -eq (ConvertTo-KitTitleKey $stage.name) })
    if ($twin.Count) { $blockers.Add("этап «$($stage.name)»: у вас он в stages/$($twin[0].file), а берётся stages/$($stage.file) — развести названия скиллом /flow") }
}
foreach ($name in $takenAgents) {
    $own = Join-Path (Join-Path $personal $agentsDir) "$name.md"
    if ((Test-Path -LiteralPath $own -PathType Leaf) -and (Get-KitAgentText $own) -cne (Get-KitAgentText (Join-Path (Join-Path $source $agentsDir) "$name.md"))) {
        $conflicts.Add("субагент $name уже есть и другой — заменится")
    }
}
$ownPreamble = @(Get-KitFlowPreamble $ownScenarios | Where-Object { $_.Trim() -and $_ -notmatch '^#\s' })
$sourcePreamble = @(Get-KitFlowPreamble $sourceScenarios)
$takePreamble = -not $ownFlows.Count
if ($takePreamble -and $ownPreamble.Count -and (($ownPreamble -join "`n") -cne ((@($sourcePreamble | Where-Object { $_.Trim() -and $_ -notmatch '^#\s' })) -join "`n"))) {
    $conflicts.Add('общий текст scenarios.md — заменится общим текстом ' + $From)
}

if ($blockers.Count) { throw "взять нельзя:`n$(($blockers | ForEach-Object { "- $_" }) -join "`n")" }
if ($conflicts.Count -and -not $Replace) {
    throw "у вас уже есть то, что заменится; ничего не взято — спросить оператора и повторить с -Replace:`n$(($conflicts | ForEach-Object { "- $_" }) -join "`n")"
}

# Запись. Сценарии пишутся текстом, каким его видит сессия: комментарии scenarios.md до неё
# не доходят и при переписывании не сохраняются.
$parts = [System.Collections.Generic.List[string]]::new()
if ($takePreamble) {
    $head = @(Get-KitFlowPreamble $ownScenarios | Where-Object { $_ -match '^#\s' } | Select-Object -First 1)
    if (-not $head.Count) { $head = @($sourcePreamble | Where-Object { $_ -match '^#\s' } | Select-Object -First 1) }
    $body = @($sourcePreamble | Where-Object { $_ -notmatch '^#\s' })
    $parts.Add((Join-KitSection (@($head) + $body)).Trim())
    foreach ($flow in $chosen) { $parts.Add((Join-KitSection $flow.lines)) }
}
else {
    $parts.Add((Join-KitSection (Get-KitFlowPreamble $ownScenarios)).Trim())
    $placed = @{}
    foreach ($flow in $ownFlows) {
        $match = @($chosen | Where-Object { (ConvertTo-KitTitleKey $_.name) -eq (ConvertTo-KitTitleKey $flow.name) })
        if ($match.Count) { $parts.Add((Join-KitSection $match[0].lines)); $placed[(ConvertTo-KitTitleKey $flow.name)] = $true }
        else { $parts.Add((Join-KitSection $flow.lines)) }
    }
    foreach ($flow in $chosen) {
        if (-not $placed.ContainsKey((ConvertTo-KitTitleKey $flow.name))) { $parts.Add((Join-KitSection $flow.lines)) }
    }
}
New-Item -ItemType Directory -Force -Path (Split-Path $ownScenarios -Parent) | Out-Null
Set-Content -LiteralPath $ownScenarios -Value ((@($parts | Where-Object { $_ }) -join "`n`n") + "`n") -Encoding utf8 -NoNewline

$stagesTarget = Join-Path (Join-Path $personal $flowDir) $script:KitStagesDir
New-Item -ItemType Directory -Force -Path $stagesTarget | Out-Null
foreach ($stage in $takenStages.Values) {
    Copy-Item -LiteralPath (Join-Path (Join-Path (Join-Path $source $flowDir) $script:KitStagesDir) $stage.file) -Destination (Join-Path $stagesTarget $stage.file) -Force
}
if ($takenAgents.Count) {
    New-Item -ItemType Directory -Force -Path (Join-Path $personal $agentsDir) | Out-Null
    foreach ($name in $takenAgents) {
        Copy-Item -LiteralPath (Join-Path (Join-Path $source $agentsDir) "$name.md") -Destination (Join-Path (Join-Path $personal $agentsDir) "$name.md") -Force
    }
}

# Взятое судится как свой флоу: красное — откат к закоммиченному, флоу и субагенты до записи
# были закоммичены, и всё изменённое в них — скрипта.
$fails = @(Get-KitFlowFindings $base $state.worktree $rules | Where-Object { $_.severity -eq 'FAIL' })
if ($fails.Count) {
    & git -C $personal restore --source=HEAD --staged --worktree -- $flowDir $agentsDir 2>$null | Out-Null
    & git -C $personal clean -fdq -- $flowDir $agentsDir 2>$null | Out-Null
    throw "взятое дало во флоу красные находки — ничего не взято:`n$(Get-KitFindingLines $fails)"
}

Invoke-KitGitStrict $personal @('add', '--', $flowDir, $agentsDir) 'добавить взятое'
& git -C $personal diff --cached --quiet -- $flowDir $agentsDir 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Взятое у $From совпало с вашим — коммитить нечего."
    exit 0
}
Invoke-KitGitStrict $personal @('commit', '-q', '-m', "agents-kit: флоу взят у $From", '--', $flowDir, $agentsDir) 'закоммитить взятое'

Write-Host "Взято у $From в личный репозиторий:"
Write-Host "  сценарии: $(($chosen | ForEach-Object { "«$($_.name)»" }) -join ', ')"
Write-Host "  этапы: $((@($takenStages.Values) | ForEach-Object { "«$($_.name)»" }) -join ', ')"
Write-Host "  субагенты: $(if ($takenAgents.Count) { $takenAgents -join ', ' } else { 'нет' })"
if ($missingAgents.Count) { Write-Host "  не выложены $From — могут прийти из плагина или профиля: $($missingAgents -join ', ')" -ForegroundColor Yellow }
if (-not $takePreamble) { Write-Host "  общий текст scenarios.md — ваш, общий текст $From не взят" }
Write-Host "Довезти субагентов в копию: pwsh -NoProfile -File `"$(ConvertTo-KitPath (Join-Path $PSScriptRoot 'agents-deploy.ps1'))`" -Path `"$($state.worktree)`""
