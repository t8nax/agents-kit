# agents-kit: довезти субагентов базы в рабочую копию — файлы каталога субагентов копии и
# строки, которыми они спрятаны от git проекта.
#   pwsh -NoProfile -File scripts\agents-deploy.ps1 [-Path <копия>]
#
# Файл кладётся один в один: субагент — формат Claude Code, и кит его не разбирает.
# Раскладка идёт только явным прогоном: набор субагентов сессия собирает при запуске,
# и разложенное ею самой этой сессии всё равно не видно.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'link-state.ps1')

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path
switch ($state.status) {
    'NotGit'    { throw "«$Path» не под git — это не рабочая копия проекта под китом" }
    'NoPointer' { throw "каталог «$($state.workspace)» под китом не числится — сначала взять его под кит скиллом /onboard" }
    'Linked'    { }
    default     { throw "связь копии «$($state.workspace)» с базой разорвана — link.ps1 без аргументов покажет, что именно" }
}

$excludePath = Get-KitAgentExcludePath $state.worktree
if (-not $excludePath) { throw "у копии «$($state.worktree)» не нашёлся каталог git — прятать разложенное негде" }

# Блок переписывается целиком, остальной файл не трогается: в нём живут исключения проекта.
function Set-KitAgentExcludeBlock([string]$ExcludePath, $Marks, [string[]]$Lines) {
    $raw = ''
    if (Test-Path -LiteralPath $ExcludePath -PathType Leaf) {
        try { $raw = Get-Content -LiteralPath $ExcludePath -Raw -ErrorAction Stop } catch { $raw = '' }
    }
    if ($null -eq $raw) { $raw = '' }
    $eol = "`n"
    if ($raw.Contains("`r`n")) { $eol = "`r`n" }
    $pattern = '(?ms)^' + [regex]::Escape($Marks.open) + "[ `t]*`r?`n.*?^" + [regex]::Escape($Marks.close) + "[ `t]*(`r?`n|`$)"
    $raw = [regex]::Replace($raw, $pattern, '')
    if ($Lines.Count) {
        if ($raw -and -not $raw.EndsWith("`n")) { $raw += $eol }
        $raw += ((@($Marks.open) + $Lines + @($Marks.close)) -join $eol) + $eol
    }
    $dir = Split-Path $ExcludePath -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($ExcludePath, $raw, [System.Text.UTF8Encoding]::new($false))
}

$target = Get-KitAgentDir $state.worktree
$sources = [ordered]@{}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $state.base 'agents') -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $sources[$file.Name] = $file.FullName
}

$tracked = @(Get-KitTrackedAgents $state.worktree)
$deployed = @(Get-KitDeployedAgents $state.worktree)

$placed = [System.Collections.Generic.List[string]]::new()
$updated = [System.Collections.Generic.List[string]]::new()
$removed = [System.Collections.Generic.List[string]]::new()
$taken = [System.Collections.Generic.List[string]]::new()
$kept = 0

foreach ($name in @($sources.Keys)) {
    if ($tracked -contains $name) { $taken.Add($name); continue }
    $dst = Join-Path $target $name
    if (Test-Path -LiteralPath $dst -PathType Leaf) {
        if ((Get-KitAgentText $dst) -ceq (Get-KitAgentText $sources[$name])) { $kept++; continue }
        if ($PSCmdlet.ShouldProcess($dst, 'обновить субагента по базе')) {
            Copy-Item -LiteralPath $sources[$name] -Destination $dst -Force
        }
        $updated.Add($name)
        continue
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($target, 'завести каталог субагентов копии')) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($dst, 'довезти субагента из базы')) {
        Copy-Item -LiteralPath $sources[$name] -Destination $dst -Force
    }
    $placed.Add($name)
}

# Ушедший из базы уходит и из копии: иначе им отработала бы сессия, у которой он давно снят.
foreach ($name in $deployed) {
    if ($sources.Contains($name)) { continue }
    if ($tracked -contains $name) { continue }
    $dst = Join-Path $target $name
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { continue }
    if ($PSCmdlet.ShouldProcess($dst, 'убрать субагента, которого в базе нет')) {
        Remove-Item -LiteralPath $dst -Force
    }
    $removed.Add($name)
}

$lines = @(foreach ($name in @($sources.Keys)) {
    if ($tracked -contains $name) { continue }
    Get-KitAgentExcludeLine $state.scope $name
})
if ($PSCmdlet.ShouldProcess($excludePath, 'переписать блок кита в исключениях копии')) {
    Set-KitAgentExcludeBlock $excludePath (Get-KitAgentExcludeMarks $state.scope) $lines
}

Write-Host "Рабочая копия: $($state.worktree)"
Write-Host "База:          $($state.base)"
foreach ($name in $placed)  { Write-Host "  довезён:  $name" }
foreach ($name in $updated) { Write-Host "  обновлён: $name" }
foreach ($name in $removed) { Write-Host "  убран:    $name" }
foreach ($name in $taken) {
    Write-Host "  не тронут: $name — имя занято отслеживаемым файлом проекта" -ForegroundColor Yellow
}
Write-Host ''
Write-Host "Довезено: $($placed.Count), обновлено: $($updated.Count), убрано: $($removed.Count), без изменений: $kept"
if ($placed.Count -or $updated.Count) {
    Write-Host 'Звать довезённых можно со следующей сессии: набор субагентов собирается при её запуске.'
}
